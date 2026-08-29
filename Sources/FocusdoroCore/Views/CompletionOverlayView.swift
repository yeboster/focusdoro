import SwiftUI

/// Content of the centered completion panel. Auto-start counts down visibly so the
/// break never begins without the user seeing why.
struct CompletionOverlayView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let summary: FocusCompletionSummary
    let remainingSeconds: Int
    let onStartBreak: () -> Void
    let onSkipBreak: () -> Void

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Theme.Palette.success)
                .symbolEffect(.pulse, isActive: !reduceMotion)

            VStack(spacing: Theme.Space.xs) {
                Text("Focus complete")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text("\(summary.focusedMinutes) min on “\(summary.taskTitle)”")
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }

            Text("\(summary.nextBreak.displayName) · \(summary.breakMinutes) min")
                .font(Theme.Font.meta)
                .foregroundStyle(Theme.Palette.textTertiary)

            HStack(spacing: Theme.Space.s) {
                Button("Skip break", action: onSkipBreak)
                    .buttonStyle(SecondaryActionStyle())
                    .keyboardShortcut(.cancelAction)
                Button(startTitle, action: onStartBreak)
                    .buttonStyle(PrimaryActionStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Space.l)
        .frame(width: 340)
        .popoverSurface()
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Focus complete. \(summary.focusedMinutes) minutes on \(summary.taskTitle). \(summary.nextBreak.displayName) of \(summary.breakMinutes) minutes starts in \(remainingSeconds) seconds.")
    }

    private var startTitle: String {
        remainingSeconds > 0 ? "Start break (\(remainingSeconds))" : "Start break"
    }
}
