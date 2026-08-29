#if DEBUG
import Foundation

/// Deterministic sample data for SwiftUI previews. Debug-only: nothing here reaches a
/// release build, and none of it touches the network, the Keychain, or Core Data.
enum PreviewFixtures {
    static let now: Date = {
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 29
        components.hour = 14
        components.minute = 30
        return Calendar.current.date(from: components) ?? Date()
    }()

    static func day(offset: Int) -> String {
        let date = Calendar.current.date(byAdding: .day, value: offset, to: now) ?? now
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static let selectedTask = SelectedTask(id: "task-1", title: "Write the handoff doc")

    static let todaySummary = TodaySummary(focusedSeconds: 4500, completedFocusSessions: 3, streakDays: 5)

    static var recentSessions: [SessionRecord] {
        [
            SessionRecord(
                taskID: "task-1", taskTitleSnapshot: "Write the handoff doc",
                startedAt: now.addingTimeInterval(-1800), endedAt: now.addingTimeInterval(-300),
                plannedDurationSeconds: 1500, elapsedDurationSeconds: 1500,
                kind: .focus, status: .completed, todoistCommentStatus: .posted,
                todoistCommentID: "c-1", createdAt: now.addingTimeInterval(-1800)
            ),
            SessionRecord(
                taskID: "task-2", taskTitleSnapshot: "Review the pull request",
                startedAt: now.addingTimeInterval(-5400), endedAt: now.addingTimeInterval(-3900),
                plannedDurationSeconds: 1500, elapsedDurationSeconds: 1500,
                kind: .focus, status: .completed, todoistCommentStatus: .failed,
                createdAt: now.addingTimeInterval(-5400)
            ),
            SessionRecord(
                taskID: "task-3", taskTitleSnapshot: "Draft the release notes",
                startedAt: now.addingTimeInterval(-9000), endedAt: now.addingTimeInterval(-8600),
                plannedDurationSeconds: 1500, elapsedDurationSeconds: 400,
                kind: .focus, status: .abandoned, createdAt: now.addingTimeInterval(-9000)
            ),
        ]
    }
}

extension TodoistProject {
    static var previewProjects: [TodoistProject] {
        [
            TodoistProject(id: "project-1", name: "Inbox", isInboxProject: true),
            TodoistProject(id: "project-2", name: "Focusdoro"),
            TodoistProject(id: "project-3", name: "Admin"),
        ]
    }
}

extension TodoistTask {
    static func preview(_ id: String, _ content: String, due: String? = nil, priority: Int = 1, labels: [String] = [], projectID: String = "project-1") -> TodoistTask {
        TodoistTask(
            id: id,
            content: content,
            projectID: projectID,
            priority: priority,
            due: due.map { TodoistDue(date: $0, string: $0, isRecurring: false, datetime: nil) },
            labels: labels
        )
    }

    static var previewTasks: [TodoistTask] {
        [
            .preview("task-9", "Reply to the design review", due: PreviewFixtures.day(offset: -2), priority: 3),
            .preview("task-1", "Write the handoff doc", due: PreviewFixtures.day(offset: 0), priority: 4, labels: ["deep-work"], projectID: "project-2"),
            .preview("task-2", "Review the pull request", due: PreviewFixtures.day(offset: 0), priority: 2, projectID: "project-2"),
            .preview("task-5", "Plan next week", due: PreviewFixtures.day(offset: 3), projectID: "project-3"),
            .preview("task-7", "Read the Core Data migration guide", projectID: "project-2"),
        ]
    }
}
#endif
