import Foundation

/// How the picker orders tasks. Persisted, so the choice survives relaunch.
public enum TaskSortOrder: String, Codable, Sendable, CaseIterable, Identifiable {
    case dueDate
    case priority
    case project
    case name

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .dueDate: return "Due date"
        case .priority: return "Priority"
        case .project: return "Project"
        case .name: return "Name"
        }
    }
}

/// First-level date view. Sorting and detailed filters operate inside this scope.
public enum TaskDateScope: String, Codable, Sendable, CaseIterable, Identifiable {
    case today
    case upcoming
    case all

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .today: return "Today"
        case .upcoming: return "Upcoming"
        case .all: return "All"
        }
    }
}

/// What the picker hides. `nil` project means every project.
public struct TaskFilterCriteria: Codable, Equatable, Sendable {
    public var projectID: String?
    /// Lowest priority still shown. `.p4` (Todoist's default) shows everything.
    public var minimumPriority: TaskPriority
    public var hidesUndated: Bool

    public static let none = TaskFilterCriteria(projectID: nil, minimumPriority: .p4, hidesUndated: false)

    public init(projectID: String? = nil, minimumPriority: TaskPriority = .p4, hidesUndated: Bool = false) {
        self.projectID = projectID
        self.minimumPriority = minimumPriority
        self.hidesUndated = hidesUndated
    }

    public var isActive: Bool { self != .none }

    /// Short description for the filter button, e.g. "Work · P2+".
    public func summary(projectName: String?) -> String {
        var parts: [String] = []
        if let projectName { parts.append(projectName) }
        if minimumPriority != .p4 { parts.append("\(minimumPriority.label)+") }
        if hidesUndated { parts.append("Dated") }
        return parts.isEmpty ? "All tasks" : parts.joined(separator: " · ")
    }
}

public struct TaskSection: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let tasks: [TodoistTask]

    public init(id: String, title: String, tasks: [TodoistTask]) {
        self.id = id
        self.title = title
        self.tasks = tasks
    }
}

/// Turns the cached task list into the sections the picker renders. Pure, so every
/// ordering and filtering rule is testable without a network or a view.
public enum TaskOrganizer {
    public static func sections(
        tasks: [TodoistTask],
        projects: [TodoistProject],
        scope: TaskDateScope = .all,
        criteria: TaskFilterCriteria,
        sort: TaskSortOrder,
        now: Date,
        calendar: Calendar
    ) -> [TaskSection] {
        let scoped = apply(scope, to: tasks, now: now, calendar: calendar)
        let filtered = apply(criteria, to: scoped, calendar: calendar)

        switch sort {
        case .project:
            return projectSections(filtered, projects: projects)
        case .priority:
            return prioritySections(filtered, calendar: calendar)
        case .name:
            let sorted = filtered.sorted { compareNames($0, $1) }
            return sorted.isEmpty ? [] : [TaskSection(id: "all", title: "All tasks", tasks: sorted)]
        case .dueDate:
            return dueSections(filtered, now: now, calendar: calendar)
        }
    }

    public static func apply(
        _ scope: TaskDateScope,
        to tasks: [TodoistTask],
        now: Date,
        calendar: Calendar
    ) -> [TodoistTask] {
        guard scope != .all else { return tasks }
        let groups = TaskFilter.group(tasks: tasks, now: now, calendar: calendar)
        switch scope {
        case .today: return groups.overdue + groups.today
        case .upcoming: return groups.upcoming
        case .all: return tasks
        }
    }

    public static func apply(
        _ criteria: TaskFilterCriteria,
        to tasks: [TodoistTask],
        calendar: Calendar
    ) -> [TodoistTask] {
        tasks.filter { task in
            if let projectID = criteria.projectID, task.projectID != projectID { return false }
            if TaskPriority(wireValue: task.priority).rawValue < criteria.minimumPriority.rawValue { return false }
            if criteria.hidesUndated {
                guard let due = task.due, TaskFilter.startOfDueDay(due, calendar: calendar) != nil else { return false }
            }
            return true
        }
    }

    // MARK: - Section builders

    private static func dueSections(_ tasks: [TodoistTask], now: Date, calendar: Calendar) -> [TaskSection] {
        let groups = TaskFilter.group(tasks: tasks, now: now, calendar: calendar)
        return [
            TaskSection(id: "overdue", title: "Overdue", tasks: groups.overdue),
            TaskSection(id: "today", title: "Today", tasks: groups.today),
            TaskSection(id: "upcoming", title: "Upcoming", tasks: groups.upcoming),
            TaskSection(id: "undated", title: "No date", tasks: groups.undated),
        ].filter { !$0.tasks.isEmpty }
    }

    private static func prioritySections(_ tasks: [TodoistTask], calendar: Calendar) -> [TaskSection] {
        // Highest first: P1, P2, P3, then Todoist's unprioritized default.
        TaskPriority.allCases.reversed().compactMap { level in
            let matching = tasks
                .filter { TaskPriority(wireValue: $0.priority) == level }
                .sorted { compareDueThenName($0, $1, calendar: calendar) }
            guard !matching.isEmpty else { return nil }
            return TaskSection(
                id: "priority-\(level.rawValue)",
                title: level.isFlagged ? level.label : "No priority",
                tasks: matching
            )
        }
    }

    private static func projectSections(_ tasks: [TodoistTask], projects: [TodoistProject]) -> [TaskSection] {
        var byProject: [String: [TodoistTask]] = [:]
        for task in tasks { byProject[task.projectID ?? "", default: []].append(task) }

        let named = projects
            .filter { byProject[$0.id]?.isEmpty == false }
            // Inbox first, then alphabetical: it is where quick captures land.
            .sorted { left, right in
                if (left.isInboxProject ?? false) != (right.isInboxProject ?? false) {
                    return left.isInboxProject ?? false
                }
                return left.name.localizedStandardCompare(right.name) == .orderedAscending
            }
            .map { project in
                TaskSection(
                    id: "project-\(project.id)",
                    title: project.name,
                    tasks: (byProject[project.id] ?? []).sorted { comparePriorityThenDue($0, $1) }
                )
            }

        // Tasks whose project is unknown (not yet fetched, or deleted) still show.
        let knownIDs = Set(projects.map(\.id))
        let orphans = byProject
            .filter { !knownIDs.contains($0.key) }
            .flatMap(\.value)
            .sorted { comparePriorityThenDue($0, $1) }

        return named + (orphans.isEmpty ? [] : [TaskSection(id: "project-other", title: "Other", tasks: orphans)])
    }

    // MARK: - Comparators

    private static func comparePriorityThenDue(_ lhs: TodoistTask, _ rhs: TodoistTask) -> Bool {
        let left = TaskPriority(wireValue: lhs.priority).rawValue
        let right = TaskPriority(wireValue: rhs.priority).rawValue
        if left != right { return left > right }
        return compareNames(lhs, rhs)
    }

    private static func compareDueThenName(_ lhs: TodoistTask, _ rhs: TodoistTask, calendar: Calendar) -> Bool {
        let left = lhs.due.flatMap { TaskFilter.startOfDueDay($0, calendar: calendar) }
        let right = rhs.due.flatMap { TaskFilter.startOfDueDay($0, calendar: calendar) }
        switch (left, right) {
        case let (l?, r?) where l != r: return l < r
        // A dated task outranks an undated one at the same priority.
        case (nil, _?): return false
        case (_?, nil): return true
        default: return compareNames(lhs, rhs)
        }
    }

    private static func compareNames(_ lhs: TodoistTask, _ rhs: TodoistTask) -> Bool {
        let result = lhs.content.localizedStandardCompare(rhs.content)
        return result == .orderedSame ? lhs.id < rhs.id : result == .orderedAscending
    }
}
