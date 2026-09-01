import AppKit
import SwiftUI

public enum MenuBarClick: Equatable, Sendable {
    case togglePopover
    case showQuitMenu

    public static func action(for eventType: NSEvent.EventType) -> MenuBarClick {
        eventType == .rightMouseUp ? .showQuitMenu : .togglePopover
    }
}

/// `NSStatusItem` plus one anchored `NSPopover`. Open/close are idempotent, so a
/// double hotkey press or a click while already open cannot create a second popover.
@MainActor
public final class MenuBarController: NSObject, NSPopoverDelegate {
    private let model: AppModel
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let terminate: @MainActor () -> Void
    private var hosting: NSHostingController<PopoverRoot>!
    /// Closes the popover when the user clicks anywhere else.
    private var eventMonitor: Any?

    public init(model: AppModel, terminate: @escaping @MainActor () -> Void = { NSApp.terminate(nil) }) {
        self.model = model
        self.terminate = terminate
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
    }

    public func start() {
        configureStatusItem()
        configurePopover()
        model.onMenuBarTitleChange = { [weak self] title in
            self?.updateTitle(title)
        }
        model.onRequestPopoverClose = { [weak self] in
            self?.closePopover()
        }
        updateTitle(AppModel.menuBarTitle(for: model.snapshot))
    }

    // MARK: - Status item

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.image = NSImage(
            systemSymbolName: "timer",
            accessibilityDescription: "Focusdoro"
        )
        button.image?.isTemplate = true
        button.imagePosition = .imageLeading
        button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        button.target = self
        button.action = #selector(statusItemClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.setAccessibilityLabel("Focusdoro")
    }

    private func updateTitle(_ title: String) {
        guard let button = statusItem.button else { return }
        let text = title.isEmpty ? "" : " \(title)"
        // Re-setting the same title relays out the whole status item, which shows as a
        // twitch next to the other menu-bar icons.
        guard button.title != text else { return }
        button.title = text
        button.setAccessibilityValue(title.isEmpty ? "Idle" : title)
    }

    @objc private func statusItemClicked() {
        handleStatusItemClick(eventType: NSApp.currentEvent?.type ?? .leftMouseUp)
    }

    public func handleStatusItemClick(eventType: NSEvent.EventType) {
        switch MenuBarClick.action(for: eventType) {
        case .togglePopover:
            togglePopover()
        case .showQuitMenu:
            closePopover()
            showQuitMenu()
        }
    }

    public var statusContextMenuItemTitles: [String] {
        ["Quit Focusdoro"]
    }

    public func invokeQuitAction() {
        terminate()
    }

    private func showQuitMenu() {
        let menu = NSMenu()
        let quit = NSMenuItem(title: "Quit Focusdoro", action: #selector(quitFromStatusMenu), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
        defer { statusItem.menu = nil }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @objc private func quitFromStatusMenu() {
        invokeQuitAction()
    }

    // MARK: - Popover

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        // Transparent so the SwiftUI surface owns the rounded corner and border.
        hosting = NSHostingController(rootView: PopoverRoot(model: model, maxHeight: Self.availableHeight()))
        // Without this the popover keeps its 320×320 default at show time and only then
        // adopts the SwiftUI size. A popover window grows from its fixed bottom-left
        // origin, so that late growth pushed the top of a long task list off the screen.
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
    }

    /// Tallest popover this screen can show below the menu bar.
    private static func availableHeight(for button: NSStatusBarButton? = nil) -> CGFloat {
        let screen = button?.window?.screen ?? NSScreen.main
        guard let visible = screen?.visibleFrame.height else { return Theme.Metric.popoverFallbackHeight }
        // Leave the anchor gap plus a little breathing room at the bottom edge.
        return max(320, visible - popoverGap - 16)
    }

    /// Sizes the popover to its content *before* it is shown, so AppKit anchors the
    /// window at the height it will actually have.
    private func sizePopover(for button: NSStatusBarButton) {
        let available = Self.availableHeight(for: button)
        hosting.rootView = PopoverRoot(model: model, maxHeight: available)
        hosting.view.layoutSubtreeIfNeeded()
        var size = hosting.view.fittingSize
        size.width = Theme.Metric.popoverWidth
        size.height = min(max(size.height, 1), available)
        popover.contentSize = size
    }

    /// True once `start()` has claimed the single status item.
    public var hasStatusItem: Bool { statusItem.button != nil }

    public var isPopoverShown: Bool { popover.isShown }

    /// Exposed for tests: the size the popover was given before it was shown.
    public var popoverContentSize: NSSize { popover.contentSize }

    /// Releases the status item and the global monitor. Used at termination and by tests
    /// so a run never leaves an orphaned item in the menu bar.
    public func shutdown() {
        stopEventMonitor()
        if popover.isShown { popover.performClose(nil) }
        popover.contentViewController = nil
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    public func togglePopover() {
        popover.isShown ? closePopover() : openPopover()
    }

    /// How far below the status item the popover sits. The default anchor tucks the
    /// popover under the menu bar itself on current macOS, so the anchor rect is pushed
    /// down by this much.
    private static let popoverGap: CGFloat = 6

    public func openPopover() {
        guard !popover.isShown, let button = statusItem.button else { return }
        sizePopover(for: button)
        let anchor = button.bounds.offsetBy(dx: 0, dy: -Self.popoverGap)
        popover.show(relativeTo: anchor, of: button, preferredEdge: .minY)
        // An accessory app is not active by default, and an inactive app's window never
        // becomes key — which is what stops ⌘V from reaching the token field.
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()
        startEventMonitor()
        Task { await model.popoverDidOpen() }
    }

    public func closePopover() {
        guard popover.isShown else { return }
        popover.performClose(nil)
    }

    private func startEventMonitor() {
        stopEventMonitor()
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.closePopover() }
        }
    }

    private func stopEventMonitor() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
    }

    // MARK: - NSPopoverDelegate

    public func popoverDidClose(_ notification: Notification) {
        stopEventMonitor()
        model.popoverDidClose()
    }
}
