import AppKit
import SwiftUI

/// Composition root. Owns every long-lived service and wires the AppKit shell to the
/// core. Menu-bar-only: the accessory activation policy means no Dock icon and no
/// dashboard window ever exists (spec §2).
@MainActor
public final class AppLifecycleCoordinator: NSObject, NSApplicationDelegate {
    public private(set) var model: AppModel!
    private var menuBar: MenuBarController!
    private let overlay = CompletionOverlayController()
    private let hotKeys = HotKeyService()
    private let preferencesStore: PreferencesStoring
    private let tokenStore: TokenStoring
    private var store: SessionStoring?
    private var storeError: String?

    /// Menu-bar-only: no Dock icon, no app switcher entry, no dashboard window (spec §2).
    public static let activationPolicy: NSApplication.ActivationPolicy = .accessory

    public init(
        preferencesStore: PreferencesStoring = UserDefaultsPreferencesStore(),
        tokenStore: TokenStoring = KeychainStore()
    ) {
        self.preferencesStore = preferencesStore
        self.tokenStore = tokenStore
        super.init()
    }

    // MARK: - Launch

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(Self.activationPolicy)
        // Must exist before the first popover opens, or ⌘V has no key equivalent to hit.
        AppMainMenu.install()
        buildGraph()
        menuBar.start()
        registerHotKeys()
        observeSystemEvents()
        Task {
            await model.start()
            if model.preferences.notificationsEnabled {
                // Asked on the first launch that will actually need it.
                _ = await notificationService.requestAuthorizationIfNeeded()
            }
            if let storeError {
                model.banner = BannerMessage(kind: .error, text: storeError)
            }
        }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        // The deadline is already persisted; nothing is written here that a crash
        // would otherwise lose.
        hotKeys.unregisterAll()
        model?.shutdown()
        menuBar?.shutdown()
        overlay.dismiss()
    }

    public func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: - Graph

    private var notificationService: NotificationService!

    private func buildGraph() {
        let clock = SystemDateProvider()

        let sessionStore: SessionStoring
        do {
            sessionStore = try SessionStore()
        } catch {
            // History is degraded but the timer must still work.
            storeError = (error as? SessionStoreError)?.userMessage ?? "Local history is unavailable."
            sessionStore = (try? SessionStore(inMemory: true)) ?? NullSessionStore()
        }
        store = sessionStore

        let client = TodoistClient(tokenProvider: { [tokenStore] in try tokenStore.readToken() })
        let sync = TodoistSync(client: client, tokenStore: tokenStore, clock: clock)
        let engine = TimerEngine(
            clock: clock,
            persistence: UserDefaultsTimerStateStore(),
            preferences: preferencesStore
        )
        let orchestrator = CompletionOrchestrator(store: sessionStore, todoist: client, clock: clock)

        // Focus mode: macOS Focus through the user's Shortcuts, plus Slack DND and
        // status. The Slack token gets its own Keychain entry, never preferences.
        let slackTokens = KeychainStore(service: KeychainStore.slackService, account: "slack-user-token")
        let slack = SlackClient(tokenProvider: { [slackTokens] in try slackTokens.readToken() })
        let presence = PresenceServices.live(
            slack: slack,
            slackTokens: slackTokens,
            settings: { [preferencesStore] in preferencesStore.preferences.presence }
        )
        notificationService = NotificationService(preferences: preferencesStore)

        let model = AppModel(
            sync: sync,
            engine: engine,
            orchestrator: orchestrator,
            store: sessionStore,
            preferencesStore: preferencesStore,
            notifications: notificationService,
            clock: clock,
            presence: presence
        )
        model.presentCompletionOverlay = { [weak self] summary in
            self?.overlay.present(summary)
        }
        model.dismissCompletionOverlay = { [weak self] in
            self?.overlay.dismiss()
        }
        overlay.onStartBreak = { [weak model] phase in
            Task { await model?.startBreak(phase) }
        }
        overlay.onSkipBreak = { [weak model] in
            Task { await model?.skipBreak() }
        }

        self.model = model
        self.menuBar = MenuBarController(model: model)
    }

    // MARK: - Hot keys

    private func registerHotKeys() {
        hotKeys.onTogglePopover = { [weak self] in self?.menuBar.togglePopover() }
        hotKeys.onStartStop = { [weak self] in
            guard let self else { return }
            Task { await self.model.requestStartStop() }
            // Stop routes to a confirmation, which only makes sense with UI visible.
            if self.model.snapshot.state.activePhase != nil { self.menuBar.openPopover() }
        }
        applyHotKeyBindings()
        NotificationCenter.default.addObserver(
            forName: .focusdoroHotKeysChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.applyHotKeyBindings() }
        }
    }

    private func applyHotKeyBindings() {
        do {
            try hotKeys.register(bindings: preferencesStore.preferences.bindings)
        } catch let error as HotKeyError {
            model?.banner = BannerMessage(kind: .warning, text: error.userMessage)
        } catch {
            model?.banner = BannerMessage(kind: .warning, text: "Global shortcuts could not be registered.")
        }
    }

    // MARK: - Sleep / wake

    private func observeSystemEvents() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.model.handleSystemWake() }
        }
        // A day boundary crossed while running would otherwise stale the today stats.
        NotificationCenter.default.addObserver(
            forName: .NSCalendarDayChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.model.reloadHistory() }
        }
    }
}

/// Last-resort store so a Core Data failure degrades history instead of crashing.
final class NullSessionStore: SessionStoring {
    func insertSession(_ record: SessionRecord) throws {}
    func updateSession(_ record: SessionRecord) throws {}
    func session(id: UUID) throws -> SessionRecord? { nil }
    func markCommentStatus(sessionID: UUID, status: CommentStatus, commentID: String?) throws {}
    func todaySummary(now: Date, calendar: Calendar) throws -> TodaySummary { TodaySummary() }
    func recentSessions(limit: Int) throws -> [SessionRecord] { [] }
    func sessionsNeedingCommentRetry() throws -> [SessionRecord] { [] }
}
