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
    case completePickerTask
    case disconnect
}

public struct BannerMessage: Equatable, Identifiable, Sendable {
    public enum Kind: Sendable { case info, warning, error, success }
    public let id = UUID()
    public var kind: Kind
    public var text: String
    /// Session whose comment can be retried, when the banner came from a failed post.
    public var retrySessionID: UUID?
    /// True only for update discovery, giving banner one explicit install action.
    public var offersUpdateInstall: Bool

    public init(
        kind: Kind,
        text: String,
        retrySessionID: UUID? = nil,
        offersUpdateInstall: Bool = false
    ) {
        self.kind = kind
        self.text = text
        self.retrySessionID = retrySessionID
        self.offersUpdateInstall = offersUpdateInstall
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
    public private(set) var weeklySummary = WeeklySummary()
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
    public var taskDateScope: TaskDateScope {
        get { sync.dateScope }
        set {
            sync.dateScope = newValue
            preferences.taskDateScope = newValue
        }
    }

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
    /// Picker completion never enters timer completion flow: it closes this task only,
    /// without creating a focus session or Todoist comment.
    public private(set) var pendingPickerCompletionTask: TodoistTask?
    public var banner: BannerMessage?
    /// Picker composer stays collapsed until plus button requests it.
    public var showsTaskComposer = false
    public var tokenDraft: String = ""
    /// New picker task title. Cleared before any API call so stale text cannot be sent twice.
    public var newTaskDraft: String = ""
    /// Slack user token being pasted. Cleared the moment it reaches the Keychain.
    public var slackTokenDraft: String = ""
    public private(set) var slackIsConnected = false
    /// Shortcut names offered in the two Focus pickers, read from the Shortcuts CLI.
    public private(set) var availableShortcuts: [String] = []
    /// Task the keyboard is pointing at in the picker. Nil until the user arrows or
    /// types; a mouse-only session never sees a highlight.
    public private(set) var highlightedTaskID: String?
    /// Read from `SMAppService`, never from preferences: the user can revoke the login
    /// item in System Settings and this has to reflect that.
    public private(set) var loginItemStatus: LoginItemStatus = .unavailable
    /// One-off focus length picked on the ready screen, in seconds. Deliberately not
    /// written to preferences: a sprint sized for one task must not silently become the
    /// new default for every task after it.
    public private(set) var customFocusSeconds: Int?

    // Collaborators
    public let sync: TodoistSync
    public let engine: TimerEngine
    private let orchestrator: CompletionOrchestrator
    private let store: SessionStoring
    private let preferencesStore: PreferencesStoring
    private let notifications: NotificationPresenting
    private let clock: DateProviding
    private let calendar: Calendar
    /// Optional: a build with neither macOS Focus nor Slack configured has none.
    private let presenceServices: PresenceServices?
    private var presence: PresenceCoordinator? { presenceServices?.coordinator }
    private let loginItem: LoginItemManaging?
    private let updateChecker: UpdateChecking?
    private let updateInstaller: UpdateInstalling?
    private var availableUpdate: UpdateRelease?
    public private(set) var isInstallingUpdate = false

    /// Set by the AppKit layer; the core stays free of window ownership.
    public var presentCompletionOverlay: ((FocusCompletionSummary) -> Void)?
    public var dismissCompletionOverlay: (() -> Void)?
    public var onMenuBarTitleChange: ((String) -> Void)?
    public var onRequestPopoverClose: (() -> Void)?
    /// AppKit terminates only after installer has staged verified replacement and
    /// detached helper. Persisted deadline restores current session after relaunch.
    public var onUpdateInstallStarted: (() -> Void)?

    private var tickTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var updateTask: Task<Void, Never>?
    private var popoverIsVisible = false

    public init(
        sync: TodoistSync,
        engine: TimerEngine,
        orchestrator: CompletionOrchestrator,
        store: SessionStoring,
        preferencesStore: PreferencesStoring,
        notifications: NotificationPresenting,
        clock: DateProviding = SystemDateProvider(),
        calendar: Calendar = .current,
        presence: PresenceServices? = nil,
        loginItem: LoginItemManaging? = nil,
        updateChecker: UpdateChecking? = nil,
        updateInstaller: UpdateInstalling? = nil
    ) {
        self.sync = sync
        self.engine = engine
        self.orchestrator = orchestrator
        self.store = store
        self.preferencesStore = preferencesStore
        self.notifications = notifications
        self.clock = clock
        self.calendar = calendar
        self.presenceServices = presence
        self.loginItem = loginItem
        self.updateChecker = updateChecker
        self.updateInstaller = updateInstaller
        self.preferences = preferencesStore.preferences
        self.route = sync.hasToken ? .tasks : .connect
        // The picker's scope, ordering, and filter are user choices, so they outlive a relaunch.
        sync.dateScope = self.preferences.taskDateScope
        sync.sortOrder = self.preferences.taskSortOrder
        sync.filter = self.preferences.taskFilter
    }

    // MARK: - Lifecycle

    public func start() async {
        observeEvents()
        slackIsConnected = ((try? presenceServices?.slackTokens.readToken()) ?? nil)?.isEmpty == false
        refreshLoginItemStatus()
        // Restore before anything else so a deadline already passed completes now.
        await engine.restore()
        await engine.setCompletedFocusCount(todayCompletedFocusCount())
        await refreshSnapshot()
        reloadHistory()
        startTicking()
        startUpdateChecking()
        if sync.hasToken {
            await sync.refresh()
            await orchestrator.retryPendingComments()
            reloadHistory()
        }
    }

    public func shutdown() {
        if let presence {
            // Fire and forget: termination will not wait, but a session ended by
            // quitting should still not leave Slack snoozed for its full length.
            Task { await presence.release() }
        }
        tickTask?.cancel()
        eventTask?.cancel()
        updateTask?.cancel()
        tickTask = nil
        eventTask = nil
        updateTask = nil
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
        case .sessionAbandoned(let sessionID, let task, let elapsed, let planned, let phase):
            await releasePresence()
            resetPlannedFocus()
            guard phase == .focus else { break }
            let logs = preferences.logsAbandonedTime
            // The session's own planned length, not today's default: a one-off sprint
            // must not be recorded against the 25 minutes it never planned to run.
            let outcome = await orchestrator.finishFocus(
                sessionID: sessionID, task: task, elapsedSeconds: elapsed,
                plannedSeconds: planned, reason: .abandoned,
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
        await releasePresence()
        resetPlannedFocus()
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
        await releasePresence()
        resetPlannedFocus()
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

    // MARK: - Focus presence

    /// Announces the session to macOS Focus and Slack. A channel that fails only
    /// produces a banner: the timer itself is already running and never waits on it.
    private func engagePresence(task: SelectedTask) async {
        guard let presence else { return }
        let snapshot = self.snapshot
        let remaining = snapshot.remainingSeconds > 0 ? snapshot.remainingSeconds : preferences.focusDurationSeconds
        let context = FocusPresenceContext(
            taskTitle: task.title,
            minutes: max(1, Int((Double(remaining) / 60).rounded(.up))),
            endsAt: clock.now.addingTimeInterval(TimeInterval(remaining))
        )
        let failures = await presence.engage(context)
        if let text = PresenceMessage.banner(for: failures) {
            banner = BannerMessage(kind: .warning, text: text)
        }
    }

    /// Validates the pasted Slack user token and stores it in the Keychain. Like the
    /// Todoist flow, the draft is cleared either way so the token never lingers in view
    /// state, and no failure message carries it.
    public func connectSlack() async {
        guard let services = presenceServices else { return }
        let token = slackTokenDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        slackTokenDraft = ""
        guard !token.isEmpty else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try services.slackTokens.saveToken(token)
            try await services.slack.validateToken()
            slackIsConnected = true
            preferences.presence.slackEnabled = true
            banner = BannerMessage(kind: .success, text: "Slack connected.")
        } catch {
            try? services.slackTokens.deleteToken()
            slackIsConnected = false
            banner = BannerMessage(kind: .error, text: PresenceMessage.text(for: error))
        }
    }

    public func disconnectSlack() {
        guard let services = presenceServices else { return }
        try? services.slackTokens.deleteToken()
        slackIsConnected = false
        preferences.presence.slackEnabled = false
    }

    /// Refreshes the shortcut names offered in settings. Cheap enough to call whenever
    /// the settings screen appears, and silent when Shortcuts is unavailable.
    public func loadAvailableShortcuts() async {
        guard let services = presenceServices else { return }
        availableShortcuts = await services.shortcuts.availableShortcuts()
    }

    private func releasePresence() async {
        guard let presence else { return }
        let failures = await presence.release()
        if let text = PresenceMessage.banner(for: failures) {
            banner = BannerMessage(kind: .warning, text: text)
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

    public func createTaskAndFocus() async {
        guard !isBusy else { return }
        let title = newTaskDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        newTaskDraft = ""
        guard !title.isEmpty else { return }

        isBusy = true
        defer { isBusy = false }
        do {
            let task = try await sync.createTask(content: title)
            await select(task: task)
            await startFocus()
        } catch {
            let message = (error as? TodoistError)?.userMessage ?? "Couldn't create the Todoist task."
            banner = BannerMessage(kind: .error, text: message)
        }
    }

    public func select(task: TodoistTask) async {
        // The project name is resolved here, while the sync cache still has it: history
        // has to keep reading after the task is closed or the app is offline.
        // A length sized for the previous task means nothing for this one.
        if snapshot.task?.id != task.id { resetPlannedFocus() }
        await engine.selectTask(task.selection(projectName: sync.projectName(id: task.projectID)))
        highlightedTaskID = task.id
        await refreshSnapshot()
        route = .timer
    }

    // MARK: - Session length

    /// Shortest and longest a single focus may be set to from the ready screen. The low
    /// bound matches what Settings already allows, so a one-minute smoke test still works.
    public static let focusLengthBounds = 1...180
    /// One tap of the stepper.
    public static let focusLengthStepMinutes = 5

    /// Length the next focus will run for: the one-off override when the user set one,
    /// otherwise the configured default.
    public var plannedFocusSeconds: Int {
        customFocusSeconds ?? preferences.focusDurationSeconds
    }

    public var plannedFocusMinutes: Int {
        max(Self.focusLengthBounds.lowerBound, plannedFocusSeconds / 60)
    }

    public var hasCustomFocusLength: Bool { customFocusSeconds != nil }

    public var canLengthenFocus: Bool { plannedFocusMinutes < Self.focusLengthBounds.upperBound }
    public var canShortenFocus: Bool { plannedFocusMinutes > Self.focusLengthBounds.lowerBound }

    /// Steps the next session's length. Ignored once a session is running: the deadline
    /// is written at start and is never extended (spec §4).
    public func adjustPlannedFocus(byMinutes delta: Int) {
        guard snapshot.state.activePhase == nil else { return }
        let target = plannedFocusMinutes + delta
        let clamped = min(max(target, Self.focusLengthBounds.lowerBound), Self.focusLengthBounds.upperBound)
        setPlannedFocus(minutes: clamped)
    }

    public func setPlannedFocus(minutes: Int) {
        guard snapshot.state.activePhase == nil else { return }
        let clamped = min(max(minutes, Self.focusLengthBounds.lowerBound), Self.focusLengthBounds.upperBound)
        // Landing back on the default drops the override, so the ready screen stops
        // claiming a custom length the user has effectively undone.
        customFocusSeconds = clamped * 60 == preferences.focusDurationSeconds ? nil : clamped * 60
    }

    public func resetPlannedFocus() {
        customFocusSeconds = nil
    }

    public func startFocus() async {
        guard let task = snapshot.task else {
            banner = BannerMessage(kind: .info, text: "Pick a Todoist task first.")
            route = .tasks
            return
        }
        await engine.startFocus(task: task, duration: plannedFocusSeconds)
        await refreshSnapshot()
        route = .timer
        onRequestPopoverClose?()
        await engagePresence(task: task)
    }

    public func startBreak(_ phase: TimerPhase) async {
        dismissCompletionOverlay?()
        // A break is time away from the desk, so notifications come back for it.
        await releasePresence()
        await engine.startBreak(phase, duration: preferences.duration(for: phase))
        await refreshSnapshot()
    }

    public func skipBreak() async {
        dismissCompletionOverlay?()
        await releasePresence()
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

    /// Completes current focusing task and keeps session/comment completion flow intact.
    public func requestCompleteTask() {
        confirmation = .completeTask
    }

    /// Completes a picker task directly. This intentionally bypasses timer engine and
    /// orchestrator because no focus occurred.
    public func requestCompleteTask(_ task: TodoistTask) {
        pendingPickerCompletionTask = task
        confirmation = .completePickerTask
    }

    public func cancelPickerTaskCompletion() {
        pendingPickerCompletionTask = nil
        confirmation = nil
    }

    public func confirmCompleteTask() async {
        let pickerTask = confirmation == .completePickerTask ? pendingPickerCompletionTask : nil
        pendingPickerCompletionTask = nil
        confirmation = nil

        guard let pickerTask else {
            await engine.completeTask()
            await refreshSnapshot()
            return
        }

        isBusy = true
        defer { isBusy = false }
        do {
            try await sync.completeTask(id: pickerTask.id)
            banner = BannerMessage(kind: .success, text: "Closed “\(pickerTask.content)” in Todoist.")
        } catch {
            let message = (error as? TodoistError)?.userMessage ?? "Couldn't complete the Todoist task."
            banner = BannerMessage(kind: .error, text: message)
        }
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

    public func installUpdate() async {
        guard !isInstallingUpdate, let updateInstaller else { return }
        isInstallingUpdate = true
        let release: UpdateRelease
        if let availableUpdate {
            release = availableUpdate
        } else {
            // Notification action may cold-launch app after announcement SHA was
            // persisted. Resolve latest validated metadata again instead of relying on
            // ephemeral model state.
            do {
                guard let resolved = try await updateChecker?.checkForInstallation() else {
                    isInstallingUpdate = false
                    banner = BannerMessage(kind: .warning, text: "The update is no longer available.")
                    return
                }
                availableUpdate = resolved
                release = resolved
            } catch {
                isInstallingUpdate = false
                banner = BannerMessage(kind: .warning, text: "The update could not be checked.")
                return
            }
        }
        // Remove both install surfaces immediately; notification action may still
        // arrive, but model guard makes it inert.
        if banner?.offersUpdateInstall == true {
            banner = BannerMessage(kind: .info, text: "Preparing verified update…")
        }
        do {
            try await updateInstaller.install(release)
            banner = BannerMessage(kind: .info, text: "Installing update…")
            onUpdateInstallStarted?()
        } catch {
            isInstallingUpdate = false
            let text = (error as? UpdateError)?.userMessage ?? "The update could not be installed."
            banner = BannerMessage(kind: .warning, text: text, offersUpdateInstall: true)
        }
    }

    private func startUpdateChecking() {
        guard let updateChecker else { return }
        updateTask?.cancel()
        updateTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    if let release = try await updateChecker.check() {
                        availableUpdate = release
                        let automaticInstallEnabled = preferences.automaticInstallUpdates
                        notifications.notifyUpdateAvailable(automaticInstallEnabled: automaticInstallEnabled)
                        if automaticInstallEnabled {
                            await installUpdate()
                        } else {
                            banner = BannerMessage(
                                kind: .info,
                                text: "A Focusdoro update is available.",
                                offersUpdateInstall: true
                            )
                        }
                    }
                } catch {
                    // Update availability never changes timer, Todoist, or presentation state.
                }
                do {
                    try await Task.sleep(for: .seconds(6 * 60 * 60))
                } catch { return }
            }
        }
    }

    // MARK: - Keyboard navigation

    /// Flattened picker order — exactly what the list renders, so arrow keys and the
    /// eye agree about what "next" means.
    public var visibleTaskIDs: [String] {
        if sync.isSearching { return sync.searchResults.map(\.id) }
        return sync.sections.flatMap { $0.tasks.map(\.id) }
    }

    public func moveHighlight(_ move: HighlightMove) {
        let ids = visibleTaskIDs
        // A highlight the list no longer contains is dropped rather than resolved, so
        // the first arrow press after a search lands on the first result, not the second.
        let current = highlightedTaskID.flatMap { ids.contains($0) ? $0 : nil }
        highlightedTaskID = TaskHighlight.next(move, in: ids, from: current)
    }

    /// Return in the picker: pick the highlighted task and start focusing on it. Falls
    /// back to the first row so Return works straight after typing a search.
    public func activateHighlighted(start: Bool = true) async {
        let ids = visibleTaskIDs
        guard let id = TaskHighlight.resolve(current: highlightedTaskID, in: ids), let task = sync.task(id: id) else { return }
        highlightedTaskID = id
        await select(task: task)
        if start { await startFocus() }
    }

    public func clearHighlight() {
        highlightedTaskID = nil
    }

    // MARK: - Launch at login

    public func refreshLoginItemStatus() {
        loginItemStatus = loginItem?.status() ?? .unavailable
    }

    /// Registers or unregisters the login item. macOS may leave it "requires approval",
    /// which is not a failure — it means the switch is now waiting in System Settings.
    public func setLaunchAtLogin(_ enabled: Bool) {
        guard let loginItem else {
            banner = BannerMessage(kind: .warning, text: LoginItemError.unavailable.userMessage)
            return
        }
        do {
            try loginItem.setEnabled(enabled)
            refreshLoginItemStatus()
            if enabled, loginItemStatus == .requiresApproval {
                banner = BannerMessage(
                    kind: .info,
                    text: "Allow Focusdoro in System Settings › General › Login Items to finish turning this on."
                )
            }
        } catch {
            refreshLoginItemStatus()
            let message = (error as? LoginItemError)?.userMessage ?? "The login item could not be changed."
            banner = BannerMessage(kind: .warning, text: message)
        }
    }

    // MARK: - History

    public func reloadHistory() {
        todaySummary = (try? store.todaySummary(now: clock.now, calendar: calendar)) ?? TodaySummary()
        weeklySummary = (try? store.weeklySummary(now: clock.now, calendar: calendar)) ?? WeeklySummary()
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
        weeklySummary: WeeklySummary = PreviewFixtures.weeklySummary,
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
        model.weeklySummary = weeklySummary
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
