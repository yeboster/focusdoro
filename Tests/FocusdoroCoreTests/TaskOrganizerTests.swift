import Foundation
import Testing
@testable import FocusdoroCore

@Suite("Task sorting and filtering")
struct TaskOrganizerTests {
    private let calendar = Fixture.calendar()
    private let now = Fixture.date("2026-08-29 14:30:00")

    private let projects = [
        TodoistProject(id: "inbox", name: "Inbox", isInboxProject: true),
        TodoistProject(id: "work", name: "Work"),
        TodoistProject(id: "admin", name: "Admin"),
    ]

    private var tasks: [TodoistTask] {
        [
            Fixture.task("a", "Overdue chore", due: "2026-08-27", priority: 2, projectID: "admin"),
            Fixture.task("b", "Ship release", due: "2026-08-29", priority: 4, projectID: "work"),
            Fixture.task("c", "Read paper", priority: 1, projectID: "inbox"),
            Fixture.task("d", "Plan quarter", due: "2026-09-04", priority: 3, projectID: "work"),
        ]
    }

    private func sections(_ sort: TaskSortOrder, criteria: TaskFilterCriteria = .none) -> [TaskSection] {
        TaskOrganizer.sections(
            tasks: tasks, projects: projects, criteria: criteria,
            sort: sort, now: now, calendar: calendar
        )
    }

    // MARK: - Sorting

    @Test("Due-date sort keeps the overdue/today/upcoming/undated order")
    func dueSort() {
        #expect(sections(.dueDate).map(\.title) == ["Overdue", "Today", "Upcoming", "No date"])
        #expect(sections(.dueDate).map { $0.tasks.map(\.id) } == [["a"], ["b"], ["d"], ["c"]])
    }

    @Test("Priority sort runs P1 first and names the unprioritized bucket")
    func prioritySort() {
        // Todoist inverts priority on the wire: 4 is the user's P1.
        #expect(sections(.priority).map(\.title) == ["P1", "P2", "P3", "No priority"])
        #expect(sections(.priority).map { $0.tasks.map(\.id) } == [["b"], ["d"], ["a"], ["c"]])
    }

    @Test("Project sort puts Inbox first, then alphabetical, and drops empty projects")
    func projectSort() {
        #expect(sections(.project).map(\.title) == ["Inbox", "Admin", "Work"])
        // Within a project, higher priority wins.
        #expect(sections(.project).last?.tasks.map(\.id) == ["b", "d"])
    }

    @Test("A task whose project was never fetched still shows, under Other")
    func orphanProject() {
        let orphan = [Fixture.task("z", "Stray", projectID: "gone")]
        let built = TaskOrganizer.sections(
            tasks: orphan, projects: projects, criteria: .none,
            sort: .project, now: now, calendar: calendar
        )
        #expect(built.map(\.title) == ["Other"])
        #expect(built[0].tasks.map(\.id) == ["z"])
    }

    @Test("Name sort is one flat, locale-aware section")
    func nameSort() {
        #expect(sections(.name).map(\.title) == ["All tasks"])
        #expect(sections(.name)[0].tasks.map(\.id) == ["a", "d", "c", "b"])
    }

    @Test("Sorting an empty list yields no sections at all")
    func emptyInput() {
        for order in TaskSortOrder.allCases {
            let built = TaskOrganizer.sections(
                tasks: [], projects: projects, criteria: .none,
                sort: order, now: now, calendar: calendar
            )
            #expect(built.isEmpty, "\(order) should produce no sections")
        }
    }

    // MARK: - Filtering

    @Test("Filtering by project keeps only that project's tasks")
    func projectFilter() {
        let filtered = TaskOrganizer.apply(
            TaskFilterCriteria(projectID: "work"), to: tasks, calendar: calendar
        )
        #expect(filtered.map(\.id) == ["b", "d"])
    }

    @Test("A minimum priority hides everything below it")
    func priorityFilter() {
        let filtered = TaskOrganizer.apply(
            TaskFilterCriteria(minimumPriority: .p2), to: tasks, calendar: calendar
        )
        // P1 (wire 4) and P2 (wire 3) survive; P3 and unprioritized do not.
        #expect(filtered.map(\.id) == ["b", "d"])
    }

    @Test("Hiding undated tasks drops the ones Todoist has no date for")
    func datedFilter() {
        let filtered = TaskOrganizer.apply(
            TaskFilterCriteria(hidesUndated: true), to: tasks, calendar: calendar
        )
        #expect(filtered.map(\.id) == ["a", "b", "d"])
    }

    @Test("Filters compose, and the sections reflect the narrowed list")
    func combinedFilter() {
        let criteria = TaskFilterCriteria(projectID: "work", minimumPriority: .p2, hidesUndated: true)
        #expect(criteria.isActive)
        #expect(sections(.dueDate, criteria: criteria).flatMap { $0.tasks.map(\.id) } == ["b", "d"])
    }

    @Test("The default criteria hides nothing")
    func noFilter() {
        #expect(!TaskFilterCriteria.none.isActive)
        #expect(TaskOrganizer.apply(.none, to: tasks, calendar: calendar).count == tasks.count)
    }

    @Test("The filter button summarises what is active")
    func filterSummary() {
        #expect(TaskFilterCriteria.none.summary(projectName: nil) == "All tasks")
        let criteria = TaskFilterCriteria(projectID: "work", minimumPriority: .p2, hidesUndated: true)
        #expect(criteria.summary(projectName: "Work") == "Work · P2+ · Dated")
    }

    // MARK: - Priority mapping

    @Test("Todoist's inverted wire priority maps to the labels users see")
    func priorityMapping() {
        #expect(TaskPriority(wireValue: 4) == .p1)
        #expect(TaskPriority(wireValue: 1) == .p4)
        #expect(TaskPriority(wireValue: nil) == .p4)
        // Out of range rather than crashing.
        #expect(TaskPriority(wireValue: 9) == .p4)
        #expect(TaskPriority.p1.label == "P1")
        #expect(TaskPriority.p1.isFlagged)
        #expect(!TaskPriority.p4.isFlagged)
    }

    // MARK: - Persistence

    @Test("Sort and filter survive an encode/decode of preferences")
    func preferencesRoundTrip() throws {
        var preferences = AppPreferences.default
        #expect(preferences.taskSortOrder == .dueDate)
        preferences.taskSortOrder = .project
        preferences.taskFilter = TaskFilterCriteria(projectID: "work", minimumPriority: .p2)

        let data = try JSONEncoder().encode(preferences)
        let decoded = try JSONDecoder().decode(AppPreferences.self, from: data)
        #expect(decoded.taskSortOrder == .project)
        #expect(decoded.taskFilter.projectID == "work")
        #expect(decoded.taskFilter.minimumPriority == .p2)
    }

    @Test("Preferences written before sorting existed still decode")
    func preferencesBackwardCompatible() throws {
        let legacy = """
        {"focusDurationSeconds":1500,"shortBreakDurationSeconds":300,"longBreakDurationSeconds":900,
         "longBreakCadence":4,"soundEnabled":true,"soundIdentifier":"Glass","notificationsEnabled":true,
         "bindings":[],"breakAutoStartDelaySeconds":10}
        """
        let decoded = try JSONDecoder().decode(AppPreferences.self, from: Data(legacy.utf8))
        #expect(decoded.taskSortOrder == .dueDate)
        #expect(decoded.taskFilter == .none)
    }
}
