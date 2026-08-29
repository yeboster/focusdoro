import AppKit
import SwiftUI
import Testing
@testable import FocusdoroCore

/// Lays every popover state out in a real `NSHostingView`. SwiftUI bodies are only
/// evaluated when something hosts them, so without this the view layer would have no
/// automated coverage at all: a crash or an unsatisfiable layout would surface only
/// when a human opened the popover.
@Suite("View rendering")
@MainActor
struct ViewRenderingTests {
    private func measure(_ view: some View) -> NSSize {
        let host = NSHostingView(rootView: view.frame(width: Theme.Metric.popoverWidth))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    private func check(_ view: some View, _ label: String) {
        let size = measure(view)
        #expect(size.width == Theme.Metric.popoverWidth, "\(label) is not the popover width")
        #expect(size.height > 0, "\(label) laid out with no height")
        // A popover taller than a small display would be unusable in the menu bar.
        #expect(size.height < 800, "\(label) is \(Int(size.height))pt tall")
    }

    @Test("Every timer state lays out inside the popover")
    func timerStates() {
        let task = PreviewFixtures.selectedTask

        check(PopoverView(model: .preview(route: .tasks)), "no task selected")

        check(
            PopoverView(model: .preview(
                snapshot: TimerSnapshot(state: .idle, task: task, plannedSeconds: 1500),
                route: .timer
            )),
            "idle with a task"
        )

        check(
            PopoverView(model: .preview(
                snapshot: TimerSnapshot(
                    state: .focusing, task: task, phase: .focus,
                    remainingSeconds: 754, elapsedSeconds: 746, plannedSeconds: 1500,
                    completedFocusCount: 2, sessionID: UUID()
                ),
                route: .timer
            )),
            "focusing"
        )

        check(
            PopoverView(model: .preview(
                snapshot: TimerSnapshot(
                    state: .breakPrompt(next: .longBreak), task: task,
                    elapsedSeconds: 1500, plannedSeconds: 1500,
                    completedFocusCount: 4, nextBreakPhase: .longBreak
                ),
                route: .timer
            )),
            "break pending"
        )

        check(
            PopoverView(model: .preview(
                snapshot: TimerSnapshot(
                    state: .shortBreaking, task: task, phase: .shortBreak,
                    remainingSeconds: 182, elapsedSeconds: 118, plannedSeconds: 300,
                    completedFocusCount: 1, sessionID: UUID()
                ),
                route: .timer
            )),
            "on a break"
        )
    }

    @Test("Offline and error states lay out")
    func errorStates() {
        check(
            PopoverView(model: .preview(
                route: .tasks,
                sync: .preview(loadState: .failed(.transport("offline")), connection: .connected),
                banner: BannerMessage(kind: .warning, text: "Couldn't reach Todoist. The session is saved locally.", retrySessionID: UUID())
            )),
            "offline"
        )

        check(
            PopoverView(model: .preview(
                route: .tasks,
                sync: .preview(loadState: .failed(.unauthorized), connection: .tokenRejected)
            )),
            "token rejected"
        )

        check(
            PopoverView(model: .preview(route: .tasks, sync: .preview(tasks: []))),
            "no tasks"
        )
    }

    @Test("Every route lays out")
    func routes() {
        check(PopoverView(model: .preview(route: .connect, sync: .preview(connection: .disconnected))), "connect")
        check(PopoverView(model: .preview(route: .history)), "history")
        check(PopoverView(model: .preview(route: .settings)), "settings")
    }

    @Test("The picker lays out under every sort order, filtered and searching")
    func pickerSortAndFilter() {
        for order in TaskSortOrder.allCases {
            let model = AppModel.preview(route: .tasks)
            model.taskSortOrder = order
            check(PopoverView(model: model), "picker sorted by \(order.title)")
            #expect(!model.sync.sections.isEmpty, "\(order.title) produced no sections")
        }

        let filtered = AppModel.preview(route: .tasks)
        filtered.taskFilter = TaskFilterCriteria(
            projectID: TodoistProject.previewProjects[1].id, minimumPriority: .p3
        )
        check(PopoverView(model: filtered), "picker filtered")

        // A filter that matches nothing must render its empty state, not collapse.
        let empty = AppModel.preview(route: .tasks)
        empty.taskFilter = TaskFilterCriteria(projectID: "nonexistent")
        check(PopoverView(model: empty), "picker with an empty filter")
        #expect(empty.sync.sections.isEmpty)

        let searching = AppModel.preview(route: .tasks)
        searching.sync.searchQuery = "a"
        check(PopoverView(model: searching), "picker searching")
    }

    @Test("A short screen shrinks the popover instead of overflowing it")
    func respectsScreenHeight() {
        let many = (0..<120).map { index in
            TodoistTask(
                id: "t\(index)",
                content: "A task title long enough to wrap onto a second line, number \(index)",
                projectID: "p-work", priority: 4,
                due: TodoistDue(date: "2026-08-29", string: "today"),
                labels: ["triage"]
            )
        }
        let model = AppModel.preview(route: .tasks, sync: .preview(tasks: many))

        for limit in [Theme.Metric.popoverFallbackHeight, 520, 400] as [CGFloat] {
            let host = NSHostingView(
                rootView: PopoverRoot(model: model, maxHeight: limit)
                    .frame(width: Theme.Metric.popoverWidth)
            )
            host.layoutSubtreeIfNeeded()
            #expect(host.fittingSize.height <= limit, "popover is \(Int(host.fittingSize.height))pt in a \(Int(limit))pt space")
        }
    }

    @Test("Settings rows all span the popover width")
    func settingsRowsAreUniform() {
        // The Alerts toggles used to hug their own content, so each card was a
        // different width. Every row must fill the popover instead.
        for soundEnabled in [true, false] {
            let model = AppModel.preview(route: .settings)
            model.preferences.soundEnabled = soundEnabled
            let host = NSHostingView(
                rootView: PopoverRoot(model: model, maxHeight: Theme.Metric.popoverFallbackHeight)
                    .frame(width: Theme.Metric.popoverWidth)
            )
            host.layoutSubtreeIfNeeded()
            host.layout()

            let cards = Self.leafFrames(in: host).filter { $0.height >= Theme.Metric.settingsRowHeight - 1 }
            #expect(!cards.isEmpty, "settings rendered no rows")
            let widths = Set(cards.map { Int($0.width.rounded()) })
            #expect(widths.count <= 2, "settings row widths differ: \(widths.sorted())")
        }
    }

    /// Frames of the deepest hosted subviews, in the hosting view's coordinate space.
    private static func leafFrames(in view: NSView) -> [CGRect] {
        view.subviews.flatMap { child -> [CGRect] in
            let nested = leafFrames(in: child)
            return nested.isEmpty ? [view.convert(child.bounds, from: child)] : nested.map { view.convert($0, from: child) }
        }
    }

    @Test("The completion overlay lays out")
    func completionOverlay() {
        let view = CompletionOverlayView(
            summary: FocusCompletionSummary(
                taskTitle: "Write the handoff doc", focusedMinutes: 25,
                nextBreak: .longBreak, breakMinutes: 15, autoStartAfterSeconds: 10
            ),
            remainingSeconds: 7,
            onStartBreak: {},
            onSkipBreak: {}
        )
        let host = NSHostingView(rootView: view)
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.height > 0)
        #expect(host.fittingSize.width > 0)
    }

    @Test("A long task title does not blow the popover width")
    func longTitle() {
        let long = String(repeating: "Refactor the persistence layer ", count: 8)
        check(
            PopoverView(model: .preview(
                snapshot: TimerSnapshot(
                    state: .focusing,
                    task: SelectedTask(id: "task-x", title: long),
                    phase: .focus, remainingSeconds: 60, elapsedSeconds: 1440,
                    plannedSeconds: 1500, sessionID: UUID()
                ),
                route: .timer
            )),
            "long task title"
        )
    }
}
