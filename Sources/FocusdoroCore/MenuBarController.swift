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
    public static let quitMenuTitle = "Quit Focusdoro"

    private let model: AppModel
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let terminate: @MainActor () -> Void
    private let monitorsExternalClicks: Bool
    private let animatesPopover: Bool
    private let popoverBehavior: NSPopover.Behavior
    private var hosting: NSHostingController<PopoverRoot>!
    /// Tracks presentation intent; AppKit's transient-popover window can report false
    /// during its close animation, while click routing still needs deterministic state.
    private var popoverIsOpen = false
    /// Closes the popover when the user clicks anywhere else.
    private var eventMonitor: Any?

    public init(
        model: AppModel,
        monitorsExternalClicks: Bool = true,
        animatesPopover: Bool = true,
        popoverBehavior: NSPopover.Behavior = .transient,
        terminate: @escaping @MainActor () -> Void = { NSApp.terminate(nil) }
    ) {
        self.model = model
        self.monitorsExternalClicks = monitorsExternalClicks
        self.animatesPopover = animatesPopover
        self.popoverBehavior = popoverBehavior
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
        makeStatusContextMenu().items.compactMap(\.title)
    }

    public func invokeQuitAction() {
        terminate()
    }

    private func makeStatusContextMenu() -> NSMenu {
        let menu = NSMenu()
        let quit = NSMenuItem(title: Self.quitMenuTitle, action: #selector(quitFromStatusMenu), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    private func showQuitMenu() {
        let menu = makeStatusContextMenu()
        statusItem.menu = menu
        defer { statusItem.menu = nil }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @objc private func quitFromStatusMenu() {
        invokeQuitAction()
    }

    // MARK: - Popover

    private func configurePopover() {
        popover.behavior = popoverBehavior
        popover.animates = animatesPopover
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

    public var isPopoverShown: Bool { popoverIsOpen }

    /// Exposed for tests: the size the popover was given before it was shown.
    public var popoverContentSize: NSSize { popover.contentSize }

    /// Releases the status item and the global monitor. Used at termination and by tests
    /// so a run never leaves an orphaned item in the menu bar.
    public func shutdown() {
        stopEventMonitor()
        if popoverIsOpen { popover.close() }
        popover.contentViewController = nil
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    public func togglePopover() {
        popoverIsOpen ? closePopover() : openPopover()
    }

    /// How far below the status item the popover sits. The default anchor tucks the
    /// popover under the menu bar itself on current macOS, so the anchor rect is pushed
    /// down by this much.
    private static let popoverGap: CGFloat = 6

    public func openPopover() {
        guard !popoverIsOpen, let button = statusItem.button else { return }
        // An accessory app is inactive by default. Activate before showing a transient
        // popover: activating afterward can make AppKit immediately dismiss it.
        NSApp.activate(ignoringOtherApps: true)
        sizePopover(for: button)
        let anchor = button.bounds.offsetBy(dx: 0, dy: -Self.popoverGap)
        popover.show(relativeTo: anchor, of: button, preferredEdge: .minY)
        popoverIsOpen = true
        popover.contentViewController?.view.window?.makeKey()
        startEventMonitor()
        Task { await model.popoverDidOpen() }
    }

    public func closePopover() {
        guard popoverIsOpen else { return }
        popoverIsOpen = false
        popover.close()
    }

    private func startEventMonitor() {
        guard monitorsExternalClicks else { return }
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
        popoverIsOpen = false
        stopEventMonitor()
        model.popoverDidClose()
    }
}
