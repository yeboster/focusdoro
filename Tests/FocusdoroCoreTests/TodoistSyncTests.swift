import Foundation
import Testing
@testable import FocusdoroCore

/// `TodoistSync` is the in-memory cache and connection state machine the picker and
/// settings screens bind to. These tests exercise it directly, without `AppModel` in
/// the loop, so a regression here cannot hide behind orchestration-level coverage.
@Suite("Todoist sync")
@MainActor
struct TodoistSyncTests {
    private func makeSync(
        tasks: [TodoistTask] = [],
        token: String? = nil
    ) -> (TodoistSync, FakeTodoist, InMemoryTokenStore) {
        let todoist = FakeTodoist(tasks: tasks)
        let tokens = InMemoryTokenStore(token: token)
        let sync = TodoistSync(client: todoist, tokenStore: tokens, clock: MutableDateProvider(now: Fixture.date("2026-08-29 09:00:00")))
        return (sync, todoist, tokens)
    }

    // MARK: - Connection state

    @Test("With no stored token the sync starts disconnected")
    func startsDisconnectedWithNoToken() {
        let (sync, _, _) = makeSync()
        #expect(sync.connection == .disconnected)
        #expect(!sync.hasToken)
    }

    @Test("With a stored token the sync starts connected")
    func startsConnectedWithStoredToken() {
        let (sync, _, _) = makeSync(token: "existing-token")
        #expect(sync.connection == .connected)
        #expect(sync.hasToken)
    }

    // MARK: - Connect flow

    @Test("A valid token is saved only after the server confirms it, then a refresh follows")
    func connectValidatesBeforeSaving() async throws {
        let (sync, todoist, tokens) = makeSync(tasks: [Fixture.task("1", "Ship it")])

        let result = await sync.connect(token: "new-token")

        guard case .success = result else {
            Issue.record("Expected connect to succeed")
            return
        }
        #expect(sync.connection == .connected)
        #expect(try tokens.readToken() == "new-token")
        // connect() also triggers the first refresh, so the picker has data immediately.
        #expect(sync.allTasks.count == 1)
        #expect(sync.loadState == .loaded)
        _ = todoist
    }

    @Test("A rejected token is never saved and the connection stays disconnected")
    func connectRejectedTokenIsNotSaved() async throws {
        let (sync, todoist, tokens) = makeSync()
        await todoist.setValidateError(.unauthorized)

        let result = await sync.connect(token: "bad-token")

        guard case .failure(let error) = result else {
            Issue.record("Expected connect to fail")
            return
        }
        #expect(error as? TodoistError == .unauthorized)
        #expect(try tokens.readToken() == nil)
        #expect(sync.connection == .disconnected)
    }

    @Test("A blank token fails locally without validating or touching the token store")
    func connectBlankTokenFailsLocally() async throws {
        let (sync, _, tokens) = makeSync()

        let result = await sync.connect(token: "   ")

        guard case .failure(let error) = result else {
            Issue.record("Expected connect to fail")
            return
        }
        #expect(error as? TodoistError == .missingToken)
        #expect(try tokens.readToken() == nil)
        #expect(sync.connection == .disconnected)
    }

    @Test("Connect trims surrounding whitespace before saving")
    func connectTrimsWhitespace() async throws {
        let (sync, _, tokens) = makeSync()
        _ = await sync.connect(token: "  padded-token  ")
        #expect(try tokens.readToken() == "padded-token")
    }

    // MARK: - Disconnect flow

    @Test("Disconnect removes the token and clears every cached field")
    func disconnectClearsState() async throws {
        let (sync, _, tokens) = makeSync(tasks: [Fixture.task("1", "Ship it")], token: "existing-token")
        await sync.refresh()
        #expect(sync.allTasks.count == 1)

        sync.disconnect()

        #expect(try tokens.readToken() == nil)
        #expect(sync.allTasks.isEmpty)
        #expect(sync.projects.isEmpty)
        #expect(sync.groups.isEmpty)
        #expect(sync.loadState == .idle)
        #expect(sync.connection == .disconnected)
        #expect(sync.lastRefreshedAt == nil)
    }

    // MARK: - Refresh / load state

    @Test("Refreshing without a token routes to disconnected instead of calling the API")
    func refreshWithoutTokenSkipsTheNetwork() async {
        let (sync, todoist, _) = makeSync()
        await sync.refresh()
        #expect(sync.connection == .disconnected)
        #expect(sync.loadState == .idle)
        // Counted on the client double, not on `StubURLProtocol`, whose counter is
        // global state shared with the suites running alongside this one.
        #expect(await todoist.listTasksCount == 0)
    }

    @Test("A failed refresh reports the mapped error and rejects the token on unauthorized")
    func refreshFailureIsReported() async {
        let (sync, todoist, _) = makeSync(token: "t")
        await todoist.setTasks([])
        await todoist.setProjectsError(nil)
        // Force listTasks itself to fail by pairing it with a projects error is not enough;
        // TodoistAPI has no direct "fail listTasks" hook on the fake other than via a task
        // list error, so drive it through the real failure surface: an unauthorized token.
        let unauthorizedTodoist = FailingTodoist(error: .unauthorized)
        let tokens = InMemoryTokenStore(token: "t")
        let failingSync = TodoistSync(client: unauthorizedTodoist, tokenStore: tokens, clock: MutableDateProvider(now: Fixture.date("2026-08-29 09:00:00")))

        await failingSync.refresh()

        #expect(failingSync.loadState == .failed(.unauthorized))
        #expect(failingSync.connection == .tokenRejected)
        _ = sync
        _ = todoist
    }

    @Test("A non-auth failure reports the error without rejecting the connection")
    func refreshFailureOtherThanUnauthorizedKeepsConnection() async {
        let failingTodoist = FailingTodoist(error: .server(status: 500))
        let tokens = InMemoryTokenStore(token: "t")
        let sync = TodoistSync(client: failingTodoist, tokenStore: tokens)

        await sync.refresh()

        #expect(sync.loadState == .failed(.server(status: 500)))
        // A server hiccup is not proof the token itself is bad.
        #expect(sync.connection != .tokenRejected)
    }

    @Test("A project-listing failure still loads the task list")
    func projectFailureToleratedDuringRefresh() async {
        let (sync, todoist, _) = makeSync(tasks: [Fixture.task("1", "Ship it")], token: "t")
        await todoist.setProjectsError(.server(status: 500))

        await sync.refresh()

        #expect(sync.loadState == .loaded)
        #expect(sync.allTasks.count == 1)
        #expect(sync.projects.isEmpty)
    }

    @Test("A newer refresh supersedes one still in flight")
    func newerRefreshSupersedesInFlight() async {
        let todoist = FakeTodoist(tasks: [Fixture.task("old", "Old task")])
        await todoist.setListTasksDelay(seconds: 0.3)
        let tokens = InMemoryTokenStore(token: "t")
        let sync = TodoistSync(client: todoist, tokenStore: tokens)

        let first = Task { await sync.refresh() }
        // Give the first refresh time to start and suspend inside the delayed call.
        try? await Task.sleep(nanoseconds: 50_000_000)
        await todoist.setTasks([Fixture.task("new", "New task")])
        await todoist.setListTasksDelay(seconds: 0)

        await sync.refresh()
        await first.value

        // The stale first refresh must never win the race and overwrite the later result.
        #expect(sync.allTasks.map(\.id) == ["new"])
        #expect(sync.loadState == .loaded)
    }

    // MARK: - Search

    @Test("Searching an empty task list returns nothing, without throwing or crashing")
    func searchOverEmptyTaskListIsEmpty() {
        let (sync, _, _) = makeSync(tasks: [])
        sync.searchQuery = "anything"
        #expect(sync.searchResults.isEmpty)
        #expect(sync.isSearching)
    }

    @Test("A blank search query is not treated as searching and returns every task")
    func blankSearchQueryReturnsAllTasks() async {
        let (sync, _, _) = makeSync(tasks: [Fixture.task("1", "Ship it")], token: "t")
        await sync.refresh()
        sync.searchQuery = "   "
        #expect(!sync.isSearching)
        #expect(sync.searchResults.count == 1)
    }

    // MARK: - Local mutation

    @Test("Creating a task inserts it into cache and groups")
    func createTaskUpdatesCacheAndGroups() async throws {
        let (sync, todoist, _) = makeSync(token: "t")
        await todoist.setCreatedTask(Fixture.task("new", "Plan release", due: "2026-08-29"))

        let task = try await sync.createTask(content: "Plan release")

        #expect(task.id == "new")
        #expect(sync.allTasks.map(\.id) == ["new"])
        #expect(sync.groups.today.map(\.id) == ["new"])
        #expect(await todoist.createdContents == ["Plan release"])
    }

    @Test("Completing a task removes it only after API success")
    func completeTaskRemovesAfterAPISuccess() async throws {
        let (sync, todoist, _) = makeSync(tasks: [Fixture.task("1", "Ship it", due: "2026-08-29")], token: "t")
        await sync.refresh()

        try await sync.completeTask(id: "1")

        #expect(await todoist.closedTaskIDs == ["1"])
        #expect(sync.allTasks.isEmpty)
        #expect(sync.groups.today.isEmpty)
    }

    @Test("Failed create and complete preserve cache")
    func failedMutationsPreserveCache() async throws {
        let (sync, todoist, _) = makeSync(tasks: [Fixture.task("1", "Ship it", due: "2026-08-29")], token: "t")
        await sync.refresh()
        await todoist.setCreateError(.server(status: 500))

        await #expect(throws: TodoistError.server(status: 500)) {
            _ = try await sync.createTask(content: "Plan release")
        }
        #expect(sync.allTasks.map(\.id) == ["1"])
        #expect(sync.groups.today.map(\.id) == ["1"])

        await todoist.setCloseError(.server(status: 500))
        await #expect(throws: TodoistError.server(status: 500)) {
            try await sync.completeTask(id: "1")
        }
        #expect(sync.allTasks.map(\.id) == ["1"])
        #expect(sync.groups.today.map(\.id) == ["1"])
    }

    @Test("Removing a task locally drops it from both the flat list and its group")
    func removeLocallyUpdatesGroupsToo() async {
        let (sync, _, _) = makeSync(tasks: [Fixture.task("1", "Ship it", due: "2026-08-29")], token: "t")
        await sync.refresh()
        #expect(sync.groups.today.count == 1)

        sync.removeLocally(taskID: "1")

        #expect(sync.allTasks.isEmpty)
        #expect(sync.groups.today.isEmpty)
    }

    // MARK: - Cached projections

    /// `sections`, `searchResults`, `projectName`, and `projectsWithTasks` are memoized
    /// because a SwiftUI body reads them far more often than their inputs change. Every
    /// input that changes the answer must therefore invalidate the cache.
    @Test("Every input that changes a projection invalidates its cache")
    func projectionsInvalidate() async {
        let todoist = FakeTodoist(tasks: [
            Fixture.task("1", "Ship it", due: "2026-08-29", priority: 4, projectID: "p-work"),
            Fixture.task("2", "Water the plants", priority: 1, projectID: "p-home"),
            Fixture.task("3", "Ship later", due: "2026-09-04", priority: 3, projectID: "p-work"),
        ])
        await todoist.setProjects([
            TodoistProject(id: "p-work", name: "Work"),
            TodoistProject(id: "p-home", name: "Home"),
        ])
        let clock = MutableDateProvider(now: Fixture.date("2026-08-29 09:00:00"))
        let sync = TodoistSync(
            client: todoist, tokenStore: InMemoryTokenStore(token: "t"),
            clock: clock, calendar: Fixture.calendar()
        )
        await sync.refresh()

        let firstRead = sync.sections
        #expect(sync.sections == firstRead, "a repeated read with no change must be stable")
        #expect(sync.projectName(id: "p-work") == "Work")
        #expect(sync.projectsWithTasks.count == 2)

        // First-level date scope narrows sections and search before other controls.
        sync.dateScope = .today
        #expect(sync.sections.flatMap(\.tasks).map(\.id) == ["1"])
        sync.searchQuery = "ship"
        #expect(sync.searchResults.map(\.id) == ["1"])
        sync.searchQuery = ""
        sync.dateScope = .all

        // Sort order.
        sync.sortOrder = .priority
        let byPriority = sync.sections
        #expect(byPriority != firstRead)

        // Filter.
        sync.filter = TaskFilterCriteria(projectID: "p-home", minimumPriority: .p4, hidesUndated: false)
        #expect(sync.sections.flatMap(\.tasks).map(\.id) == ["2"])

        // Search query, which reads the other cached projection.
        sync.searchQuery = "plants"
        #expect(sync.searchResults.map(\.id) == ["2"])
        sync.searchQuery = "ship"
        // The project filter still applies on top of the search.
        #expect(sync.searchResults.isEmpty)

        // The task list itself.
        sync.filter = .none
        sync.searchQuery = ""
        sync.sortOrder = .dueDate
        sync.removeLocally(taskID: "1")
        #expect(sync.sections.flatMap(\.tasks).map(\.id) == ["3", "2"])
        #expect(sync.projectsWithTasks.map(\.id) == ["p-home", "p-work"])
    }

    @Test("Crossing midnight re-sections the same tasks")
    func projectionsFollowTheDay() async {
        let clock = MutableDateProvider(now: Fixture.date("2026-08-29 09:00:00"))
        let sync = TodoistSync(
            client: FakeTodoist(tasks: [Fixture.task("1", "Ship it", due: "2026-08-29")]),
            tokenStore: InMemoryTokenStore(token: "t"),
            clock: clock, calendar: Fixture.calendar()
        )
        await sync.refresh()
        #expect(sync.sections.first?.title == "Today")

        // Same task, next day: it is overdue now, so a stale cache would lie.
        clock.advance(by: 24 * 60 * 60)
        #expect(sync.sections.first?.title == "Overdue")
    }

    @Test("A refresh that renames a project is visible to the name lookup")
    func projectNamesFollowRefresh() async {
        let todoist = FakeTodoist(tasks: [Fixture.task("1", "Ship it", projectID: "p-work")])
        await todoist.setProjects([TodoistProject(id: "p-work", name: "Work")])
        let sync = TodoistSync(
            client: todoist, tokenStore: InMemoryTokenStore(token: "t"),
            clock: MutableDateProvider(now: Fixture.date("2026-08-29 09:00:00")),
            calendar: Fixture.calendar()
        )
        await sync.refresh()
        #expect(sync.projectName(id: "p-work") == "Work")

        await todoist.setProjects([TodoistProject(id: "p-work", name: "Work (renamed)")])
        await sync.refresh()
        #expect(sync.projectName(id: "p-work") == "Work (renamed)")
    }
}

/// Always fails `listTasks`/`listProjects` with a fixed error, for exercising
/// `TodoistSync`'s failure-mapping path independent of `FakeTodoist`'s success-shaped API.
private final class FailingTodoist: TodoistAPI, @unchecked Sendable {
    let error: TodoistError
    init(error: TodoistError) { self.error = error }
    func listTasks() async throws -> [TodoistTask] { throw error }
    func listProjects() async throws -> [TodoistProject] { throw error }
    func createTask(content: String, dueDatetime: Date?, durationMinutes: Int?) async throws -> TodoistTask { throw error }
    func closeTask(id: String) async throws { throw error }
    func addComment(taskID: String, content: String) async throws -> TodoistComment { throw error }
    func validateToken() async throws { throw error }
}
