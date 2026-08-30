import Foundation
import Observation

public enum ConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    /// Token was rejected after having worked. Local history is untouched.
    case tokenRejected
}

public enum TaskLoadState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case failed(TodoistError)
}

/// In-memory cache of active Todoist tasks plus the grouping/search projections the
/// picker renders. Refreshes only on launch, popover open, manual retry, or a
/// completion conflict — never on a timer (spec §10, resource target).
@MainActor
@Observable
public final class TodoistSync {
    public private(set) var allTasks: [TodoistTask] = [] { didSet { revision &+= 1 } }
    public private(set) var projects: [TodoistProject] = [] { didSet { revision &+= 1 } }
    public private(set) var groups = TaskGroups()
    public private(set) var loadState: TaskLoadState = .idle
    public private(set) var connection: ConnectionState = .disconnected
    public private(set) var lastRefreshedAt: Date?

    public var searchQuery: String = ""
    /// Set by the picker's controls; persisted by `AppModel` so the choice survives a
    /// relaunch.
    public var dateScope: TaskDateScope = .all
    public var sortOrder: TaskSortOrder = .dueDate
    public var filter: TaskFilterCriteria = .none

    private let client: TodoistAPI
    private let tokenStore: TokenStoring
    private let clock: DateProviding
    private var calendar: Calendar
    private var inFlight: Task<Void, Never>?

    /// Grouping, sorting, and filtering run over every active task on every SwiftUI
    /// body evaluation, which is far more often than the inputs actually change.
    /// These caches are `@ObservationIgnored` so filling one during a body evaluation
    /// cannot invalidate the view that is mid-render.
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var sectionCache: (key: ProjectionKey, value: [TaskSection])?
    @ObservationIgnored private var searchCache: (key: ProjectionKey, value: [TodoistTask])?
    @ObservationIgnored private var projectIndex: (revision: Int, byID: [String: TodoistProject])?
    @ObservationIgnored private var projectsWithTasksCache: (revision: Int, value: [TodoistProject])?

    private struct ProjectionKey: Equatable {
        var revision: Int
        var scope: TaskDateScope
        var sort: TaskSortOrder
        var filter: TaskFilterCriteria
        var query: String
        /// Sections are relative to "today", so a day boundary must invalidate them.
        var day: Date
    }

    /// Reads the observed inputs (so a SwiftUI body still depends on them) and pairs
    /// them with the revision the caches are keyed by.
    private func projectionKey() -> ProjectionKey {
        _ = allTasks
        _ = projects
        return ProjectionKey(
            revision: revision,
            scope: dateScope,
            sort: sortOrder,
            filter: filter,
            query: searchQuery,
            day: calendar.startOfDay(for: clock.now)
        )
    }

    public init(
        client: TodoistAPI,
        tokenStore: TokenStoring,
        clock: DateProviding = SystemDateProvider(),
        calendar: Calendar = .current
    ) {
        self.client = client
        self.tokenStore = tokenStore
        self.clock = clock
        self.calendar = calendar
        self.connection = ((try? tokenStore.readToken()) ?? nil) == nil ? .disconnected : .connected
    }

    public var hasToken: Bool { ((try? tokenStore.readToken()) ?? nil) != nil }

    /// Search runs over every active task, then the picker's own filter narrows it, so
    /// a filtered view never hides a task the user explicitly searched for by name.
    public var searchResults: [TodoistTask] {
        let key = projectionKey()
        if let searchCache, searchCache.key == key { return searchCache.value }
        let matches = TaskFilter.search(searchQuery, in: allTasks)
        let scoped = TaskOrganizer.apply(dateScope, to: matches, now: clock.now, calendar: calendar)
        let value = TaskOrganizer.apply(filter, to: scoped, calendar: calendar)
        searchCache = (key, value)
        return value
    }

    /// The sections the picker renders when not searching.
    public var sections: [TaskSection] {
        let key = projectionKey()
        if let sectionCache, sectionCache.key == key { return sectionCache.value }
        let value = TaskOrganizer.sections(
            tasks: allTasks,
            projects: projects,
            scope: dateScope,
            criteria: filter,
            sort: sortOrder,
            now: clock.now,
            calendar: calendar
        )
        sectionCache = (key, value)
        return value
    }

    /// Every picker row asks for its project name, so the linear scan is indexed once
    /// per refresh instead of once per row.
    public func projectName(id: String?) -> String? {
        guard let id else { return nil }
        _ = projects
        if projectIndex?.revision != revision {
            projectIndex = (revision, Dictionary(projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }))
        }
        return projectIndex?.byID[id]?.name
    }

    public var selectedProjectName: String? { projectName(id: filter.projectID) }

    /// Projects that actually hold an active task, Inbox first.
    public var projectsWithTasks: [TodoistProject] {
        _ = allTasks
        _ = projects
        if let projectsWithTasksCache, projectsWithTasksCache.revision == revision {
            return projectsWithTasksCache.value
        }
        let ids = Set(allTasks.compactMap(\.projectID))
        let value = projects
            .filter { ids.contains($0.id) }
            .sorted { left, right in
                if (left.isInboxProject ?? false) != (right.isInboxProject ?? false) {
                    return left.isInboxProject ?? false
                }
                return left.name.localizedStandardCompare(right.name) == .orderedAscending
            }
        projectsWithTasksCache = (revision, value)
        return value
    }

    public var isSearching: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Connection

    /// Validates before storing, so an invalid token never lands in the Keychain.
    public func connect(token: String) async -> Result<Void, Error> {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(TodoistError.missingToken) }
        connection = .connecting
        do {
            try tokenStore.saveToken(trimmed)
            try await client.validateToken()
            connection = .connected
            await refresh()
            return .success(())
        } catch {
            try? tokenStore.deleteToken()
            connection = .disconnected
            return .failure(error)
        }
    }

    /// Removes the token but keeps local history (spec §11 reset flow).
    public func disconnect() {
        try? tokenStore.deleteToken()
        allTasks = []
        projects = []
        groups = TaskGroups()
        loadState = .idle
        connection = .disconnected
        lastRefreshedAt = nil
    }

    // MARK: - Refresh

    public func refresh() async {
        inFlight?.cancel()
        guard hasToken else {
            connection = .disconnected
            loadState = .idle
            return
        }
        loadState = .loading
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                // Projects are needed for the picker's grouping and filter menu; a
                // project failure must not blank the task list, so it is tolerated.
                async let taskList = self.client.listTasks()
                async let projectList = try? await self.client.listProjects()
                let tasks = try await taskList
                let fetchedProjects = await projectList
                guard !Task.isCancelled else { return }
                self.apply(tasks: tasks, projects: fetchedProjects)
            } catch is CancellationError {
                return
            } catch let error as TodoistError {
                guard !Task.isCancelled else { return }
                self.apply(error: error)
            } catch {
                guard !Task.isCancelled else { return }
                self.apply(error: .transport(error.localizedDescription))
            }
        }
        inFlight = task
        await task.value
    }

    private func apply(tasks: [TodoistTask], projects fetched: [TodoistProject]? = nil) {
        allTasks = tasks
        if let fetched { projects = fetched }
        groups = TaskFilter.group(tasks: tasks, now: clock.now, calendar: calendar)
        loadState = .loaded
        connection = .connected
        lastRefreshedAt = clock.now
    }

    private func apply(error: TodoistError) {
        loadState = .failed(error)
        if error == .unauthorized { connection = .tokenRejected }
    }

    // MARK: - Conflict handling

    /// Refreshes and reports whether the task still exists, used before/after a close
    /// so the app never blindly duplicates a completion (spec §10).
    public func stillExists(taskID: String) async -> Bool {
        await refresh()
        return allTasks.contains { $0.id == taskID }
    }

    public func task(id: String) -> TodoistTask? {
        allTasks.first { $0.id == id }
    }

    /// Drops a task locally after it is closed so the picker does not offer it again
    /// before the next refresh.
    public func removeLocally(taskID: String) {
        allTasks.removeAll { $0.id == taskID }
        groups = TaskFilter.group(tasks: allTasks, now: clock.now, calendar: calendar)
    }
}

#if DEBUG
/// Preview seeding. Lives in this file because the published properties are
/// `private(set)`; nothing here is compiled into a release build.
extension TodoistSync {
    static func preview(
        tasks: [TodoistTask] = TodoistTask.previewTasks,
        projects: [TodoistProject] = TodoistProject.previewProjects,
        loadState: TaskLoadState = .loaded,
        connection: ConnectionState = .connected,
        now: Date = PreviewFixtures.now
    ) -> TodoistSync {
        let clock = MutableDateProvider(now: now)
        let sync = TodoistSync(client: PreviewTodoistAPI(), tokenStore: InMemoryTokenStore(), clock: clock)
        sync.allTasks = tasks
        sync.projects = projects
        sync.groups = TaskFilter.group(tasks: tasks, now: now, calendar: .current)
        sync.loadState = loadState
        sync.connection = connection
        sync.lastRefreshedAt = loadState == .loaded ? now : nil
        return sync
    }
}

/// Never called by previews; exists only so `TodoistSync` has a client to hold.
final class PreviewTodoistAPI: TodoistAPI {
    func listTasks() async throws -> [TodoistTask] { TodoistTask.previewTasks }
    func listProjects() async throws -> [TodoistProject] { TodoistProject.previewProjects }
    func closeTask(id: String) async throws {}
    func addComment(taskID: String, content: String) async throws -> TodoistComment {
        TodoistComment(id: "preview", taskID: taskID, content: content)
    }
    func validateToken() async throws {}
}
#endif
