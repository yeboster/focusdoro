import AppKit
import Foundation
import Observation

public enum PopoverRoute: Equatable, Sendable {
    case connect
    case tasks
    case timer
    case settings
    case history
}

public enum PendingConfirmation: Equatable, Sendable {
    case abandon
    case completeTask
    case disconnect
}

public struct BannerMessage: Equatable, Identifiable, Sendable {
    public enum Kind: Sendable { case info, warning, error, success }
    public let id = UUID()
    public var kind: Kind
    public var text: String
    /// Session whose comment can be retried, when the banner came from a failed post.
    public var retrySessionID: UUID?

    public init(kind: Kind, text: String, retrySessionID: UUID? = nil) {
        self.kind = kind
        self.text = text
        self.retrySessionID = retrySessionID
    }
}

/// Single observable surface the SwiftUI views bind to. Views never touch the network
/// or Core Data directly (plan Task 8).
@MainActor
@Observable
public final class AppModel {
    // Presentation state
    public private(set) var snapshot = TimerSnapshot(state: .idle)
    public private(set) var todaySummary = TodaySummary()
    public private(set) var recentSessions: [SessionRecord] = []
    public private(set) var isBusy = false
    public var route: PopoverRoute = .tasks
    /// Stored, not computed: `@Observable` only tracks stored properties, so a computed
    /// forward to the preferences store would let a toggle write through without ever
    /// re-rendering the control that wrote it.
    public var preferences: AppPreferences {
        didSet {
            guard preferences != oldValue else { return }
            preferencesStore.preferences = preferences
        }
    }
    /// Picker controls write through to both the live sync and the persisted
    /// preferences; reads come from `sync`, which is observable.
    public var taskSortOrder: TaskSortOrder {
        get { sync.sortOrder }
        set {
            sync.sortOrder = newValue
            preferences.taskSortOrder = newValue
        }
    }

    public var taskFilter: TaskFilterCriteria {
        get { sync.filter }
        set {
            sync.filter = newValue
            preferences.taskFilter = newValue
        }
    }

    public var confirmation: PendingConfirmation?
    public var banner: BannerMessage?
    public var tokenDraft: String = ""

    // Collaborators
    public let sync: TodoistSync
    public let engine: TimerEngine
    private let orchestrator: CompletionOrchestrator
    private let store: SessionStoring
    private let preferencesStore: PreferencesStoring
    private let notifications: NotificationPresenting
    private let clock: DateProviding
    private let calendar: Calendar

    /// Set by the AppKit layer; the core stays free of window ownership.
    public var presentCompletionOverlay: ((FocusCompletionSummary) -> Void)?
    public var dismissCompletionOverlay: (() -> Void)?
    public var onMenuBarTitleChange: ((String) -> Void)?
    public var onRequestPopoverClose: (() -> Void)?

    private var tickTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var popoverIsVisible = false

    public init(
        sync: TodoistSync,
        engine: TimerEngine,
        orchestrator: CompletionOrchestrator,
        store: SessionStoring,
        preferencesStore: PreferencesStoring,
        notifications: NotificationPresenting,
        clock: DateProviding = SystemDateProvider(),
        calendar: Calendar = .current
    ) {
        self.sync = sync
        self.engine = engine
        self.orchestrator = orchestrator
        self.store = store
        self.preferencesStore = preferencesStore
        self.notifications = notifications
        self.clock = clock
        self.calendar = calendar
        self.preferences = preferencesStore.preferences
        self.route = sync.hasToken ? .tasks : .connect
        // The picker's ordering and filter are user choices, so they outlive a relaunch.
        sync.sortOrder = self.preferences.taskSortOrder
        sync.filter = self.preferences.taskFilter
    }

    // MARK: - Lifecycle

    public func start() async {
        observeEvents()
        // Restore before anything else so a deadline already passed completes now.
        await engine.restore()
        await engine.setCompletedFocusCount(todayCompletedFocusCount())
        await refreshSnapshot()
        reloadHistory()
        startTicking()
        if sync.hasToken {
            await sync.refresh()
            await orchestrator.retryPendingComments()
            reloadHistory()
        }
    }

    public func shutdown() {
        tickTask?.cancel()
        eventTask?.cancel()
        tickTask = nil
        eventTask = nil
    }

    public func handleSystemWake() async {
        await engine.handleWake()
        await refreshSnapshot()
    }

    public func popoverDidOpen() async {
        popoverIsVisible = true
        startTicking()
        await refreshSnapshot()
        reloadHistory()
        if sync.hasToken, snapshot.state == .idle { await sync.refresh() }
    }

    public func popoverDidClose() {
        popoverIsVisible = false
        // Timer keeps running; only the refresh cadence drops.
        startTicking()
    }

    // MARK: - Ticking

    /// 1 Hz whenever there is a countdown to draw — in the popover or in the menu bar —
    /// and 5 s only when nothing is running. Nothing accumulates: each tick just
    /// reprojects the persisted deadline.
    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.engine.tick()
                await self.refreshSnapshot()
                let interval = Self.tickInterval(
                    isActive: self.snapshot.state.activePhase != nil,
                    popoverIsVisible: self.popoverIsVisible
                )
                let delay = Self.tickDelay(after: self.clock.now, interval: interval)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    /// A running phase drives the menu-bar countdown, so it ticks every second even with
    /// the popover closed; the old 5 s cadence made the title jump five digits at a time.
    static func tickInterval(isActive: Bool, popoverIsVisible: Bool) -> Double {
        isActive || popoverIsVisible ? 1 : 5
    }

    /// Sleeps to just past the next whole second rather than a flat 1 s. A flat sleep
    /// drifts by however long the tick took, and once the drift passes a second boundary
    /// the countdown skips a number — which reads as a stutter in the menu bar.
    static func tickDelay(after now: Date, interval: Double) -> Double {
        guard interval <= 1 else { return interval }
        let fraction = now.timeIntervalSince1970.truncatingRemainder(dividingBy: 1)
        return min(1, max(0.05, 1 - fraction + 0.02))
    }

    private func refreshSnapshot() async {
        let next = await engine.snapshot()
        let wasIdle = snapshot.state == .idle
        snapshot = next
        onMenuBarTitleChange?(Self.menuBarTitle(for: next))
        if next.state.activePhase != nil, route == .tasks { route = .timer }
        // Only the *transition* out of a running session returns to the picker.
        // Testing `state == .idle` alone bounced the user back one tick after they
        // picked a task, because selecting one leaves the engine idle until start.
        if !wasIdle, next.state == .idle, route == .timer { route = .tasks }
    }

    public static func menuBarTitle(for snapshot: TimerSnapshot) -> String {
        switch snapshot.state {
        case .idle:
            return ""
        case .breakPrompt:
            return "Break?"
        case .focusing, .focusCompletionPending:
            return snapshot.formattedRemaining
        case .shortBreaking, .longBreaking:
            return "☕ " + snapshot.formattedRemaining
        }
    }

    // MARK: - Engine events

    private func observeEvents() {
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            guard let self else { return }
            for await event in await self.engine.events() {
                await self.handle(event)
            }
        }
    }

    private func handle(_ event: TimerEvent) async {
        switch event {
        case .focusFinished(let sessionID, let task, let elapsed, let planned):
            await handleFocusFinished(sessionID: sessionID, task: task, elapsed: elapsed, planned: planned)
        case .breakFinished:
            notifications.playCompletionSound()
            notifications.notifyBreakComplete(nextPhase: .focus)
            await refreshSnapshot()
        case .sessionAbandoned(let sessionID, let task, let elapsed, let phase):
            guard phase == .focus else { break }
            let logs = preferences.logsAbandonedTime
            let outcome = await orchestrator.finishFocus(
                sessionID: sessionID, task: task, elapsedSeconds: elapsed,
                plannedSeconds: preferences.focusDurationSeconds, reason: .abandoned,
                logsPartialTime: logs
            )
            banner = BannerMessage(
                kind: outcome.commentStatus == .failed ? .warning : .info,
                text: Self.abandonBannerText(elapsedSeconds: elapsed, outcome: outcome)
            )
            reloadHistory()
        case .taskCompletionRequested(let sessionID, let task, let elapsed, let planned):
            await handleTaskCompletion(sessionID: sessionID, task: task, elapsed: elapsed, planned: planned)
        }
    }

    private func handleFocusFinished(sessionID: UUID, task: SelectedTask, elapsed: Int, planned: Int) async {
        notifications.playCompletionSound()
        let nextBreak = preferences.breakPhase(afterCompletedFocusCount: await engine.completedFocusSessions())
        notifications.notifyFocusComplete(taskTitle: task.title, nextBreak: nextBreak)
        presentCompletionOverlay?(
            FocusCompletionSummary(
                taskTitle: task.title,
                focusedMinutes: CommentFormatter.minutes(forElapsedSeconds: elapsed),
                nextBreak: nextBreak,
                breakMinutes: max(1, preferences.duration(for: nextBreak) / 60),
                autoStartAfterSeconds: preferences.breakAutoStartDelaySeconds
            )
        )
        let outcome = await orchestrator.finishFocus(
            sessionID: sessionID, task: task, elapsedSeconds: elapsed,
            plannedSeconds: planned, reason: .timerCompleted
        )
        applyCommentOutcome(outcome)
        await refreshSnapshot()
        reloadHistory()
    }

    private func handleTaskCompletion(sessionID: UUID, task: SelectedTask, elapsed: Int, planned: Int) async {
        isBusy = true
        defer { isBusy = false }
        let outcome = await orchestrator.finishFocus(
            sessionID: sessionID, task: task, elapsedSeconds: elapsed,
            plannedSeconds: planned, reason: .taskCompleted
        )
        if outcome.taskClosed { sync.removeLocally(taskID: task.id) }
        if !outcome.taskClosed {
            banner = BannerMessage(
                kind: .error,
                text: outcome.error?.userMessage ?? "Todoist did not confirm the completion.",
                retrySessionID: outcome.commentStatus == .failed ? sessionID : nil
            )
        } else {
            applyCommentOutcome(outcome, successText: "Closed “\(task.title)” and logged \(CommentFormatter.minutes(forElapsedSeconds: elapsed)) min.")
        }
        await engine.selectTask(nil)
        await refreshSnapshot()
        reloadHistory()
    }

    private func applyCommentOutcome(_ outcome: CompletionOutcome, successText: String? = nil) {
        switch outcome.commentStatus {
        case .posted:
            if let successText { banner = BannerMessage(kind: .success, text: successText) }
        case .failed:
            banner = BannerMessage(
                kind: .warning,
                text: (outcome.error?.userMessage ?? "Couldn't post the Todoist comment.") + " The session is saved locally.",
                retrySessionID: outcome.sessionID
            )
        case .pending, .notApplicable:
            break
        }
    }

    // MARK: - User intents

    public func connect() async {
        isBusy = true
        defer { isBusy = false }
        let result = await sync.connect(token: tokenDraft)
        // The draft is cleared either way so the token never lingers in view state.
        tokenDraft = ""
        switch result {
        case .success:
            banner = BannerMessage(kind: .success, text: "Connected to Todoist.")
            route = .tasks
        case .failure(let error):
            let message = (error as? TodoistError)?.userMessage
                ?? (error as? KeychainError)?.userMessage
                ?? "Could not connect to Todoist."
            banner = BannerMessage(kind: .error, text: message)
        }
    }

    public func select(task: TodoistTask) async {
        await engine.selectTask(task.selection)
        await refreshSnapshot()
        route = .timer
    }

    public func startFocus() async {
        guard let task = snapshot.task else {
            banner = BannerMessage(kind: .info, text: "Pick a Todoist task first.")
            route = .tasks
            return
        }
        await engine.startFocus(task: task, duration: preferences.focusDurationSeconds)
        await refreshSnapshot()
        route = .timer
        onRequestPopoverClose?()
    }

    public func startBreak(_ phase: TimerPhase) async {
        dismissCompletionOverlay?()
        await engine.startBreak(phase, duration: preferences.duration(for: phase))
        await refreshSnapshot()
    }

    public func skipBreak() async {
        dismissCompletionOverlay?()
        await engine.skipBreak()
        await refreshSnapshot()
        route = .tasks
    }

    /// Stop never silently discards a session; it opens the abandon confirmation.
    public func requestStartStop() async {
        if snapshot.state.activePhase == nil {
            await startFocus()
        } else {
            confirmation = .abandon
        }
    }

    public func confirmAbandon() async {
        confirmation = nil
        await engine.confirmAbandon()
        await refreshSnapshot()
        route = .tasks
    }

    /// The time spent is always kept locally; the wording tells the user where it went.
    static func abandonBannerText(elapsedSeconds: Int, outcome: CompletionOutcome) -> String {
        let minutes = CommentFormatter.minutes(forElapsedSeconds: elapsedSeconds)
        let spent = minutes >= 1 ? "\(minutes) min kept in your history." : "No measurable time was spent."
        switch outcome.commentStatus {
        case .posted:
            return "Session stopped. \(spent) The time was logged on the Todoist task."
        case .pending, .failed:
            return "Session stopped. \(spent) Logging the time to Todoist failed; it will retry."
        case .notApplicable:
            return "Session stopped. \(spent) Nothing was sent to Todoist."
        }
    }

    public func requestCompleteTask() {
        confirmation = .completeTask
    }

    public func confirmCompleteTask() async {
        confirmation = nil
        await engine.completeTask()
        await refreshSnapshot()
    }

    public func disconnect() {
        confirmation = nil
        sync.disconnect()
        banner = BannerMessage(kind: .info, text: "Token removed. Local history was kept.")
        route = .connect
    }

    public func retryComment(sessionID: UUID) async {
        isBusy = true
        defer { isBusy = false }
        let outcome = await orchestrator.retryComment(sessionID: sessionID)
        if outcome.commentStatus == .posted {
            banner = BannerMessage(kind: .success, text: "Todoist comment posted.")
        } else {
            banner = BannerMessage(
                kind: .warning,
                text: outcome.error?.userMessage ?? "Still couldn't post the comment.",
                retrySessionID: sessionID
            )
        }
        reloadHistory()
    }

    public func dismissBanner() { banner = nil }

    // MARK: - History

    public func reloadHistory() {
        todaySummary = (try? store.todaySummary(now: clock.now, calendar: calendar)) ?? TodaySummary()
        recentSessions = (try? store.recentSessions(limit: 8)) ?? []
    }

    private func todayCompletedFocusCount() -> Int {
        (try? store.todaySummary(now: clock.now, calendar: calendar).completedFocusSessions) ?? 0
    }
}

/// Payload the completion overlay renders. Pure data so it is testable and the panel
/// stays a dumb presenter.
public struct FocusCompletionSummary: Equatable, Sendable {
    public var taskTitle: String
    public var focusedMinutes: Int
    public var nextBreak: TimerPhase
    public var breakMinutes: Int
    public var autoStartAfterSeconds: Int

    public init(taskTitle: String, focusedMinutes: Int, nextBreak: TimerPhase, breakMinutes: Int, autoStartAfterSeconds: Int) {
        self.taskTitle = taskTitle
        self.focusedMinutes = focusedMinutes
        self.nextBreak = nextBreak
        self.breakMinutes = breakMinutes
        self.autoStartAfterSeconds = autoStartAfterSeconds
    }
}

#if DEBUG
/// Preview construction. In this file because `snapshot`, `todaySummary`, and
/// `recentSessions` are `private(set)`.
extension AppModel {
    static func preview(
        snapshot: TimerSnapshot = TimerSnapshot(state: .idle),
        route: PopoverRoute = .timer,
        sync: TodoistSync? = nil,
        todaySummary: TodaySummary = PreviewFixtures.todaySummary,
        recentSessions: [SessionRecord] = PreviewFixtures.recentSessions,
        banner: BannerMessage? = nil,
        confirmation: PendingConfirmation? = nil
    ) -> AppModel {
        let clock = MutableDateProvider(now: PreviewFixtures.now)
        let preferences = InMemoryPreferencesStore()
        let store = NullSessionStore()
        let engine = TimerEngine(clock: clock, persistence: InMemoryTimerStateStore(), preferences: preferences)
        let model = AppModel(
            sync: sync ?? .preview(),
            engine: engine,
            orchestrator: CompletionOrchestrator(store: store, todoist: PreviewTodoistAPI(), clock: clock),
            store: store,
            preferencesStore: preferences,
            notifications: PreviewNotifications(),
            clock: clock
        )
        model.snapshot = snapshot
        model.todaySummary = todaySummary
        model.recentSessions = recentSessions
        model.route = route
        model.banner = banner
        model.confirmation = confirmation
        return model
    }
}

final class PreviewNotifications: NotificationPresenting {
    func requestAuthorizationIfNeeded() async -> Bool { true }
    func notifyFocusComplete(taskTitle: String, nextBreak: TimerPhase) {}
    func notifyBreakComplete(nextPhase: TimerPhase) {}
    func playCompletionSound() {}
}
#endif
