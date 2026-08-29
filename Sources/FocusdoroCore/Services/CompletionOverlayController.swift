import AppKit
import SwiftUI

/// Borderless, centered panel on the active display. Non-activating so it does not
/// steal focus from whatever the user is doing; the notification is the fallback when
/// macOS refuses to place it (full-screen spaces owned by another app).
@MainActor
public final class CompletionOverlayController {
    private var panel: NSPanel?
    private var countdownTask: Task<Void, Never>?
    private var remaining: Int = 0

    public var onStartBreak: ((TimerPhase) -> Void)?
    public var onSkipBreak: (() -> Void)?

    public init() {}

    public func present(_ summary: FocusCompletionSummary) {
        dismiss()
        remaining = max(0, summary.autoStartAfterSeconds)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 240),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        // Visible over full-screen spaces where policy allows, without activating the app.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.animationBehavior = .utilityWindow

        let hosting = NSHostingView(rootView: overlayView(summary: summary))
        hosting.translatesAutoresizingMaskIntoConstraints = true
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        center(panel)

        self.panel = panel
        panel.orderFrontRegardless()
        // Key window so Return/Escape work, but the app itself is not activated.
        panel.makeKey()
        NSAccessibility.post(element: panel, notification: .applicationActivated)

        startCountdown(summary: summary)
    }

    public func dismiss() {
        countdownTask?.cancel()
        countdownTask = nil
        panel?.orderOut(nil)
        panel = nil
    }

    public var isPresented: Bool { panel != nil }

    // MARK: - Internals

    private func overlayView(summary: FocusCompletionSummary) -> some View {
        CompletionOverlayView(
            summary: summary,
            remainingSeconds: remaining,
            onStartBreak: { [weak self] in
                guard let self else { return }
                self.dismiss()
                self.onStartBreak?(summary.nextBreak)
            },
            onSkipBreak: { [weak self] in
                guard let self else { return }
                self.dismiss()
                self.onSkipBreak?()
            }
        )
    }

    /// Auto-starts the break once the confirmation window elapses (spec §3).
    private func startCountdown(summary: FocusCompletionSummary) {
        guard remaining > 0 else { return }
        countdownTask = Task { [weak self] in
            while let self, self.remaining > 0, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                self.remaining -= 1
                self.refresh(summary: summary)
            }
            guard let self, !Task.isCancelled else { return }
            self.dismiss()
            self.onStartBreak?(summary.nextBreak)
        }
    }

    private func refresh(summary: FocusCompletionSummary) {
        guard let panel, let hosting = panel.contentView as? NSHostingView<CompletionOverlayView> else { return }
        hosting.rootView = CompletionOverlayView(
            summary: summary,
            remainingSeconds: remaining,
            onStartBreak: { [weak self] in
                guard let self else { return }
                self.dismiss()
                self.onStartBreak?(summary.nextBreak)
            },
            onSkipBreak: { [weak self] in
                guard let self else { return }
                self.dismiss()
                self.onSkipBreak?()
            }
        )
    }

    /// The display holding the mouse cursor is the active one.
    private func center(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let frame = screen?.visibleFrame else {
            panel.center()
            return
        }
        let size = panel.frame.size
        panel.setFrameOrigin(
            NSPoint(
                x: frame.midX - size.width / 2,
                y: frame.midY - size.height / 2 + frame.height * 0.08
            )
        )
    }
}
