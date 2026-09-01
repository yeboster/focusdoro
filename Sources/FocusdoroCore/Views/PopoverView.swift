import SwiftUI

/// How tall the popover may grow on the screen it is anchored to. `MenuBarController`
/// sets it from the current screen; without it a long task list makes the popover taller
/// than the display, and AppKit then pushes its top off the top of the screen.
private struct PopoverMaxHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat = Theme.Metric.popoverFallbackHeight
}

extension EnvironmentValues {
    public var popoverMaxHeight: CGFloat {
        get { self[PopoverMaxHeightKey.self] }
        set { self[PopoverMaxHeightKey.self] = newValue }
    }
}

/// Hosting wrapper: lets the AppKit layer hand the current screen's height to SwiftUI
/// without the controller having to name a modifier type.
struct PopoverRoot: View {
    let model: AppModel
    var maxHeight: CGFloat

    var body: some View {
        PopoverView(model: model)
            .environment(\.popoverMaxHeight, maxHeight)
    }
}

/// Task-first popover. Content order is exactly spec §5:
/// wordmark/settings → current task → phase/timer → progress → actions →
/// next break → stats → recent sessions and links.
public struct PopoverView: View {
    @Bindable var model: AppModel
    @Environment(\.popoverMaxHeight) private var maxHeight

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            PopoverNotch()
                .frame(maxWidth: .infinity, alignment: .center)

            header

            if let banner = model.banner {
                BannerView(message: banner, onRetry: { sessionID in
                    Task { await model.retryComment(sessionID: sessionID) }
                }, onInstallUpdate: {
                    Task { await model.installUpdate() }
                }, onDismiss: { model.dismissBanner() })
            }

            switch model.route {
            case .connect:
                ConnectView(model: model)
            case .tasks:
                TaskPickerView(model: model)
                footerLinks
            case .timer:
                TimerView(model: model)
                HistoryView(model: model)
                footerLinks
            case .history:
                HistoryView(model: model)
                footerLinks
            case .settings:
                SettingsView(model: model)
            }
        }
        .padding(Theme.Space.m)
        .frame(width: Theme.Metric.popoverWidth)
        .frame(maxHeight: maxHeight, alignment: .top)
        .popoverSurface()
        .environment(\.colorScheme, .dark)
        .confirmationDialogs(model: model)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Theme.Space.s) {
            if model.route == .settings || model.route == .history {
                Button {
                    model.route = model.snapshot.state.activePhase == nil ? .tasks : .timer
                } label: {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(QuietButtonStyle())
                .accessibilityLabel("Back")
            }

            Text("Focusdoro")
                .font(Theme.Font.wordmark)
                .foregroundStyle(Theme.Palette.textPrimary)

            Spacer()

            if model.isBusy {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
            }

            Menu {
                Button("Settings…") { model.route = .settings }
                Button("History") { model.route = .history }
                Divider()
                Button("Quit Focusdoro") { NSApplication.shared.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 13, weight: .regular))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Focusdoro menu")
        }
    }

    // MARK: - Footer

    private var footerLinks: some View {
        HStack(spacing: Theme.Space.m) {
            if let toggle = model.preferences.bindings[.togglePopover] {
                Label(toggle.displayString, systemImage: "command")
                    .labelStyle(.titleAndIcon)
                    .font(Theme.Font.meta)
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
            Spacer()
            Button("Settings") { model.route = .settings }
                .buttonStyle(QuietButtonStyle())
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Banner

struct BannerView: View {
    let message: BannerMessage
    let onRetry: (UUID) -> Void
    let onInstallUpdate: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.s) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
            Text(message.text)
                .font(Theme.Font.meta)
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Theme.Space.xs)
            if let sessionID = message.retrySessionID {
                Button("Retry") { onRetry(sessionID) }
                    .buttonStyle(QuietButtonStyle())
                    .font(Theme.Font.meta)
                    .foregroundStyle(Theme.Palette.accent)
            }
            if message.offersUpdateInstall {
                Button("Install update") { onInstallUpdate() }
                    .buttonStyle(QuietButtonStyle())
                    .font(Theme.Font.meta)
                    .foregroundStyle(Theme.Palette.accent)
            }
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(QuietButtonStyle())
            .accessibilityLabel("Dismiss message")
        }
        .padding(.horizontal, Theme.Space.s + 2)
        .padding(.vertical, Theme.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(radius: Theme.Radius.chip)
        .accessibilityElement(children: .contain)
    }

    private var icon: String {
        switch message.kind {
        case .info: return "info.circle"
        case .warning: return "exclamationmark.triangle"
        case .error: return "xmark.octagon"
        case .success: return "checkmark.circle"
        }
    }

    private var tint: Color {
        switch message.kind {
        case .info: return Theme.Palette.accent
        case .warning: return Theme.Palette.warning
        case .error: return Theme.Palette.danger
        case .success: return Theme.Palette.success
        }
    }
}

// MARK: - Confirmations

/// Abandon and Todoist completion both change state the user cannot easily undo, so
/// both confirm (spec §3).
private struct ConfirmationDialogs: ViewModifier {
    @Bindable var model: AppModel

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                "Abandon this session?",
                isPresented: Binding(
                    get: { model.confirmation == .abandon },
                    set: { if !$0 { model.confirmation = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Abandon session", role: .destructive) { Task { await model.confirmAbandon() } }
                Button("Keep focusing", role: .cancel) { model.confirmation = nil }
            } message: {
                Text(model.preferences.logsAbandonedTime
                     ? "The task stays open. The time you already spent is kept in your history and logged as a comment on the Todoist task."
                     : "The task stays open and nothing is sent to Todoist. The time you already spent is kept in your local history.")
            }
            .confirmationDialog(
                "Complete this task in Todoist?",
                isPresented: Binding(
                    get: { model.confirmation == .completeTask || model.confirmation == .completePickerTask },
                    set: { if !$0 {
                        if model.confirmation == .completePickerTask {
                            model.cancelPickerTaskCompletion()
                        } else {
                            model.confirmation = nil
                        }
                    } }
                ),
                titleVisibility: .visible
            ) {
                Button("Complete task") { Task { await model.confirmCompleteTask() } }
                Button("Cancel", role: .cancel) { model.cancelPickerTaskCompletion() }
            } message: {
                if let task = model.pendingPickerCompletionTask {
                    Text("Focusdoro will close “\(task.content)” in Todoist. No focus session or Todoist comment will be created.")
                } else {
                    Text("Focusdoro will close “\(model.snapshot.task?.title ?? "this task")” in Todoist and post the measured focus time as a comment.")
                }
            }
            .confirmationDialog(
                "Remove the Todoist token?",
                isPresented: Binding(
                    get: { model.confirmation == .disconnect },
                    set: { if !$0 { model.confirmation = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Remove token", role: .destructive) { model.disconnect() }
                Button("Cancel", role: .cancel) { model.confirmation = nil }
            } message: {
                Text("Your local session history is kept. You will need to paste a token again to use Todoist.")
            }
    }
}

extension View {
    func confirmationDialogs(model: AppModel) -> some View {
        modifier(ConfirmationDialogs(model: model))
    }
}
