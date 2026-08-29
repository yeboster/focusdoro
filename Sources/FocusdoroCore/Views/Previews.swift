#if DEBUG
import SwiftUI

// Spec §5 states, each rendered from a static model so a preview never touches the
// network, the Keychain, or Core Data.
//
// These use `PreviewProvider` rather than the `#Preview` macro: the macro plugin ships
// with Xcode, and this package builds under Command Line Tools.

struct PopoverNoTask_Previews: PreviewProvider {
    static var previews: some View {
    PopoverView(model: .preview(route: .tasks))
        .previewDisplayName("Popover — no task selected")
    }
}

struct PopoverIdle_Previews: PreviewProvider {
    static var previews: some View {
    PopoverView(
        model: .preview(
            snapshot: TimerSnapshot(state: .idle, task: PreviewFixtures.selectedTask, plannedSeconds: 1500),
            route: .timer
        )
    )
        .previewDisplayName("Popover — idle with a task ready")
    }
}

struct PopoverFocusing_Previews: PreviewProvider {
    static var previews: some View {
    PopoverView(
        model: .preview(
            snapshot: TimerSnapshot(
                state: .focusing,
                task: PreviewFixtures.selectedTask,
                phase: .focus,
                remainingSeconds: 754,
                elapsedSeconds: 746,
                plannedSeconds: 1500,
                completedFocusCount: 2,
                sessionID: UUID()
            ),
            route: .timer
        )
    )
        .previewDisplayName("Popover — focusing")
    }
}

struct PopoverBreakPending_Previews: PreviewProvider {
    static var previews: some View {
    PopoverView(
        model: .preview(
            snapshot: TimerSnapshot(
                state: .breakPrompt(next: .longBreak),
                task: PreviewFixtures.selectedTask,
                remainingSeconds: 0,
                elapsedSeconds: 1500,
                plannedSeconds: 1500,
                completedFocusCount: 4,
                nextBreakPhase: .longBreak
            ),
            route: .timer
        )
    )
        .previewDisplayName("Popover — focus complete, break pending")
    }
}

struct PopoverBreaking_Previews: PreviewProvider {
    static var previews: some View {
    PopoverView(
        model: .preview(
            snapshot: TimerSnapshot(
                state: .shortBreaking,
                task: PreviewFixtures.selectedTask,
                phase: .shortBreak,
                remainingSeconds: 182,
                elapsedSeconds: 118,
                plannedSeconds: 300,
                completedFocusCount: 1,
                sessionID: UUID()
            ),
            route: .timer
        )
    )
        .previewDisplayName("Popover — on a break")
    }
}

struct PopoverAbandonConfirmation_Previews: PreviewProvider {
    static var previews: some View {
    PopoverView(
        model: .preview(
            snapshot: TimerSnapshot(
                state: .focusing,
                task: PreviewFixtures.selectedTask,
                phase: .focus,
                remainingSeconds: 900,
                elapsedSeconds: 600,
                plannedSeconds: 1500,
                sessionID: UUID()
            ),
            route: .timer,
            confirmation: .abandon
        )
    )
        .previewDisplayName("Popover — abandon confirmation")
    }
}

struct PopoverOffline_Previews: PreviewProvider {
    static var previews: some View {
    PopoverView(
        model: .preview(
            route: .timer,
            sync: .preview(loadState: .failed(.transport("The network connection was lost.")), connection: .connected),
            banner: BannerMessage(
                kind: .warning,
                text: "Couldn't reach Todoist. The session is saved locally.",
                retrySessionID: PreviewFixtures.recentSessions[1].id
            )
        )
    )
        .previewDisplayName("Popover — offline, comment queued")
    }
}

struct TaskPickerLoaded_Previews: PreviewProvider {
    static var previews: some View {
    TaskPickerView(model: .preview(route: .tasks))
        .frame(width: Theme.Metric.popoverWidth)
        .modifier(PopoverSurface())
        .previewDisplayName("Task picker — loaded")
    }
}

struct TaskPickerEmpty_Previews: PreviewProvider {
    static var previews: some View {
    TaskPickerView(model: .preview(route: .tasks, sync: .preview(tasks: [])))
        .frame(width: Theme.Metric.popoverWidth)
        .modifier(PopoverSurface())
        .previewDisplayName("Task picker — empty")
    }
}

struct TaskPickerTokenRejected_Previews: PreviewProvider {
    static var previews: some View {
    TaskPickerView(
        model: .preview(
            route: .tasks,
            sync: .preview(loadState: .failed(.unauthorized), connection: .tokenRejected)
        )
    )
    .frame(width: Theme.Metric.popoverWidth)
    .modifier(PopoverSurface())
        .previewDisplayName("Task picker — token rejected")
    }
}

struct Connect_Previews: PreviewProvider {
    static var previews: some View {
    ConnectView(model: .preview(route: .connect, sync: .preview(connection: .disconnected)))
        .frame(width: Theme.Metric.popoverWidth)
        .modifier(PopoverSurface())
        .previewDisplayName("Connect")
    }
}

struct History_Previews: PreviewProvider {
    static var previews: some View {
    HistoryView(model: .preview(route: .history))
        .frame(width: Theme.Metric.popoverWidth)
        .modifier(PopoverSurface())
        .previewDisplayName("History")
    }
}

struct Settings_Previews: PreviewProvider {
    static var previews: some View {
    SettingsView(model: .preview(route: .settings))
        .frame(width: Theme.Metric.popoverWidth)
        .modifier(PopoverSurface())
        .previewDisplayName("Settings")
    }
}

struct CompletionOverlay_Previews: PreviewProvider {
    static var previews: some View {
    CompletionOverlayView(
        summary: FocusCompletionSummary(
            taskTitle: "Write the handoff doc",
            focusedMinutes: 25,
            nextBreak: .longBreak,
            breakMinutes: 15,
            autoStartAfterSeconds: 10
        ),
        remainingSeconds: 7,
        onStartBreak: {},
        onSkipBreak: {}
    )
        .previewDisplayName("Completion overlay")
    }
}

#endif
