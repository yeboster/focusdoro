import SwiftUI

/// Sections 2–6 of the popover order: task identity, phase, timer, progress, actions,
/// next break. The timer is the largest element after task identity (spec §5).
public struct TimerView: View {
    @Bindable var model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    private var snapshot: TimerSnapshot { model.snapshot }
    private var isFocusing: Bool { snapshot.state.isFocusing }
    private var isRunning: Bool { snapshot.state.activePhase != nil }
    /// The ± controls belong to the ready screen only: mid-session there is nothing to
    /// adjust, and a break runs on its own configured length.
    private var canAdjustLength: Bool { snapshot.state == .idle }

    public var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            taskSection
            timerSection
            actionSection
            nextBreakRow
        }
    }

    // MARK: - Task identity

    private var taskSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionLabel("Current Todoist task")
            Button {
                guard !isRunning else { return }
                model.route = .tasks
            } label: {
                TaskRow(
                    title: snapshot.task?.title ?? "No task selected",
                    subtitle: snapshot.task == nil ? "Choose one to start focusing" : "Todoist",
                    showsChevron: !isRunning,
                    isPlaceholder: snapshot.task == nil
                )
            }
            .buttonStyle(.plain)
            .disabled(isRunning)
            .accessibilityHint(isRunning ? "Task is locked while focusing" : "Opens the task picker")
        }
    }

    // MARK: - Phase, timer, progress

    private var timerSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                Text(phaseLabel.uppercased())
                    .font(Theme.Font.phase)
                    .tracking(0.8)
                    .foregroundStyle(phaseColor)
                Spacer()
                if snapshot.completedFocusCount > 0 {
                    Text("\(snapshot.completedFocusCount) done today")
                        .font(Theme.Font.meta)
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
            }

            HStack(spacing: Theme.Space.s) {
                // Only before the session starts: the deadline is written at start and
                // is never extended afterwards (spec §4).
                if canAdjustLength {
                    Button("−") { model.adjustPlannedFocus(byMinutes: -AppModel.focusLengthStepMinutes) }
                        .buttonStyle(StepButtonStyle())
                        .disabled(!model.canShortenFocus)
                        .accessibilityLabel("Shorten this session by \(AppModel.focusLengthStepMinutes) minutes")
                }
                Text(displayTime)
                    .font(Theme.Font.timer)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .accessibilityLabel("\(phaseLabel) remaining")
                    .accessibilityValue(spokenTime)
                if canAdjustLength {
                    Button("+") { model.adjustPlannedFocus(byMinutes: AppModel.focusLengthStepMinutes) }
                        .buttonStyle(StepButtonStyle())
                        .disabled(!model.canLengthenFocus)
                        .accessibilityLabel("Lengthen this session by \(AppModel.focusLengthStepMinutes) minutes")
                }
            }

            ProgressBar(progress: snapshot.progress)

            HStack(spacing: Theme.Space.s) {
                Text(progressHint)
                    .font(Theme.Font.meta)
                    .foregroundStyle(model.hasCustomFocusLength && !isRunning
                        ? Theme.Palette.textSecondary : Theme.Palette.textTertiary)
                if canAdjustLength, model.hasCustomFocusLength {
                    Spacer(minLength: 0)
                    Button("Reset to \(model.preferences.focusDurationSeconds / 60) min") {
                        model.resetPlannedFocus()
                    }
                    .buttonStyle(QuietButtonStyle())
                    .font(Theme.Font.meta)
                }
            }
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    private var phaseLabel: String {
        switch snapshot.state {
        case .focusing, .focusCompletionPending: return "Focusing"
        case .shortBreaking: return "Short break"
        case .longBreaking: return "Long break"
        case .breakPrompt: return "Focus complete"
        case .idle: return "Ready"
        }
    }

    private var phaseColor: Color {
        switch snapshot.state {
        case .focusing, .focusCompletionPending: return Theme.Palette.accent
        case .shortBreaking, .longBreaking: return Theme.Palette.success
        case .breakPrompt: return Theme.Palette.warning
        case .idle: return Theme.Palette.textTertiary
        }
    }

    private var displayTime: String {
        isRunning ? snapshot.formattedRemaining : TimerSnapshot.format(seconds: model.plannedFocusSeconds)
    }

    private var spokenTime: String {
        let seconds = isRunning ? snapshot.remainingSeconds : model.plannedFocusSeconds
        let minutes = seconds / 60
        let rest = seconds % 60
        return "\(minutes) minutes \(rest) seconds"
    }

    private var progressHint: String {
        guard isRunning else {
            let tail = model.hasCustomFocusLength ? "just this session" : "no pause once started"
            return "\(model.plannedFocusMinutes) minute session · \(tail)"
        }
        return "\(snapshot.formattedElapsed) elapsed of \(TimerSnapshot.format(seconds: snapshot.plannedSeconds))"
    }

    // MARK: - Actions

    @ViewBuilder
    private var actionSection: some View {
        switch snapshot.state {
        case .idle:
            Button("Start focus") { Task { await model.startFocus() } }
                .buttonStyle(PrimaryActionStyle())
                .disabled(snapshot.task == nil || model.isBusy)

        case .focusing, .focusCompletionPending:
            HStack(spacing: Theme.Space.s) {
                Button("Abandon") { model.confirmation = .abandon }
                    .buttonStyle(SecondaryActionStyle())
                Button("Complete task") { model.requestCompleteTask() }
                    .buttonStyle(PrimaryActionStyle())
            }
            .disabled(model.isBusy)

        case .breakPrompt(let next):
            HStack(spacing: Theme.Space.s) {
                Button("Skip break") { Task { await model.skipBreak() } }
                    .buttonStyle(SecondaryActionStyle())
                Button("Start \(next == .longBreak ? "long" : "short") break") {
                    Task { await model.startBreak(next) }
                }
                .buttonStyle(PrimaryActionStyle())
            }
            .disabled(model.isBusy)

        case .shortBreaking, .longBreaking:
            Button("End break") { model.confirmation = .abandon }
                .buttonStyle(SecondaryActionStyle())
                .disabled(model.isBusy)
        }
    }

    // MARK: - Next break

    /// Informational only, so it never competes with the single blue action.
    private var nextBreakRow: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: snapshot.nextBreakPhase == .longBreak ? "cup.and.saucer" : "pause.circle")
                .foregroundStyle(Theme.Palette.textTertiary)
                .font(.system(size: 12))
            Text(nextBreakText)
                .font(Theme.Font.meta)
                .foregroundStyle(Theme.Palette.textSecondary)
            Spacer()
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(radius: Theme.Radius.chip)
        .accessibilityElement(children: .combine)
    }

    private var nextBreakText: String {
        let phase = snapshot.nextBreakPhase
        let minutes = max(1, model.preferences.duration(for: phase) / 60)
        let cadence = model.preferences.longBreakCadence
        if phase == .longBreak {
            return "Next up: long break, \(minutes) min (every \(cadence) sessions)"
        }
        return "Next up: short break, \(minutes) min"
    }
}

/// Todoist task row: icon, title, metadata, chevron. Long titles truncate cleanly.
public struct TaskRow: View {
    let title: String
    let subtitle: String
    var showsChevron: Bool = true
    var isPlaceholder: Bool = false

    public init(title: String, subtitle: String, showsChevron: Bool = true, isPlaceholder: Bool = false) {
        self.title = title
        self.subtitle = subtitle
        self.showsChevron = showsChevron
        self.isPlaceholder = isPlaceholder
    }

    public var body: some View {
        HStack(spacing: Theme.Space.s + 2) {
            Image(systemName: isPlaceholder ? "circle.dashed" : "circle")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(isPlaceholder ? Theme.Palette.textTertiary : Theme.Palette.accent)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.Font.taskTitle)
                    .foregroundStyle(isPlaceholder ? Theme.Palette.textSecondary : Theme.Palette.textPrimary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.leading)
                Text(subtitle)
                    .font(Theme.Font.meta)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: Theme.Space.s)

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s + 2)
        .frame(maxWidth: .infinity, minHeight: Theme.Metric.rowHeight, alignment: .leading)
        .cardSurface()
        .accessibilityElement(children: .combine)
    }
}
