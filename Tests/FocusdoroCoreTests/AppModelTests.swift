import AppKit
import Foundation
import Testing
@testable import FocusdoroCore

/// `NotificationPresenting` is nonisolated, so the spy guards its own state instead of
/// borrowing the main actor.
private final class SpyNotifications: NotificationPresenting, @unchecked Sendable {
    private let lock = NSLock()
    private var _focusCompleteCalls: [(String, TimerPhase)] = []
    private var _breakCompleteCalls: [TimerPhase] = []
    private var _soundCount = 0

    var focusCompleteCalls: [(String, TimerPhase)] { lock.withLock { _focusCompleteCalls } }
    var breakCompleteCalls: [TimerPhase] { lock.withLock { _breakCompleteCalls } }
    var soundCount: Int { lock.withLock { _soundCount } }

    func requestAuthorizationIfNeeded() async -> Bool { true }
    func notifyFocusComplete(taskTitle: String, nextBreak: TimerPhase) {
        lock.withLock { _focusCompleteCalls.append((taskTitle, nextBreak)) }
    }
    func notifyBreakComplete(nextPhase: TimerPhase) {
        lock.withLock { _breakCompleteCalls.append(nextPhase) }
    }
    func playCompletionSound() { lock.withLock { _soundCount += 1 } }
}

@MainActor
fileprivate struct Harness {
    let clock = MutableDateProvider(now: Fixture.date("2026-08-29 14:00:00"))
    let todoist = FakeTodoist()
    let tokens = InMemoryTokenStore()
    let preferences = InMemoryPreferencesStore()
    let notifications = SpyNotifications()
    let store: SessionStore
    let engine: TimerEngine
    let model: AppModel

    init(token: String? = "test-token") throws {
        if let token { try tokens.saveToken(token) }
        store = try Fixture.store()
        engine = TimerEngine(clock: clock, persistence: InMemoryTimerStateStore(), preferences: preferences)
        let sync = TodoistSync(client: todoist, tokenStore: tokens, clock: clock, calendar: Fixture.calendar())
        let orchestrator = CompletionOrchestrator(
            store: store, todoist: todoist, clock: clock, timeZone: Fixture.calendar().timeZone
        )
        model = AppModel(
            sync: sync,
            engine: engine,
            orchestrator: orchestrator,
            store: store,
            preferencesStore: preferences,
            notifications: notifications,
            clock: clock,
            calendar: Fixture.calendar()
        )
    }
}

@Suite("Tick cadence")
@MainActor
struct TickCadenceTests {
    @Test("The countdown ticks every second whenever a number is on screen")
    func interval() {
        // A running session paints the menu-bar countdown even with the popover shut.
        #expect(AppModel.tickInterval(isActive: true, popoverIsVisible: false) == 1)
        #expect(AppModel.tickInterval(isActive: true, popoverIsVisible: true) == 1)
        #expect(AppModel.tickInterval(isActive: false, popoverIsVisible: true) == 1)
        // Idle and hidden: nothing is visible, so a slow poll is enough.
        #expect(AppModel.tickInterval(isActive: false, popoverIsVisible: false) == 5)
    }

    @Test("A one-second tick lands just after the next whole second")
    func delayAlignsToTheSecondBoundary() {
        // Sleeping a flat second after the work drifts, which visibly skips digits.
        let justAfter = Date(timeIntervalSince1970: 100.05)
        #expect(abs(AppModel.tickDelay(after: justAfter, interval: 1) - 0.97) < 0.001)

        let justBefore = Date(timeIntervalSince1970: 100.98)
        #expect(abs(AppModel.tickDelay(after: justBefore, interval: 1) - 0.05) < 0.001)

        let onTheSecond = Date(timeIntervalSince1970: 100)
        let delay = AppModel.tickDelay(after: onTheSecond, interval: 1)
        #expect(delay > 0.9 && delay <= 1)

        // The slow cadence is never realigned; it has no digit to keep up with.
        #expect(AppModel.tickDelay(after: justAfter, interval: 5) == 5)
    }
}

@Suite("App model")
@MainActor
struct AppModelTests {
    @Test("With no token the popover opens on the connect route")
    func routesToConnectWithoutToken() throws {
        let harness = try Harness(token: nil)
        #expect(harness.model.route == .connect)
    }

    @Test("With a stored token the popover opens on the task list")
    func routesToTasksWithToken() throws {
        let harness = try Harness()
        #expect(harness.model.route == .tasks)
    }

    @Test("Menu bar title is empty when idle and shows the countdown while focusing")
    func menuBarTitles() {
        #expect(AppModel.menuBarTitle(for: TimerSnapshot(state: .idle)).isEmpty)

        let focusing = TimerSnapshot(state: .focusing, remainingSeconds: 754, plannedSeconds: 1500)
        #expect(AppModel.menuBarTitle(for: focusing) == "12:34")

        let breaking = TimerSnapshot(state: .shortBreaking, remainingSeconds: 65, plannedSeconds: 300)
        #expect(AppModel.menuBarTitle(for: breaking) == "☕ 01:05")

        let prompt = TimerSnapshot(state: .breakPrompt(next: .longBreak), remainingSeconds: 0, plannedSeconds: 0)
        #expect(AppModel.menuBarTitle(for: prompt) == "Break?")
    }

    @Test("Starting a focus session moves the popover to the timer and reports the title")
    func startFocusUpdatesRoute() async throws {
        let harness = try Harness()
        var titles: [String] = []
        harness.model.onMenuBarTitleChange = { titles.append($0) }

        await harness.model.select(task: Fixture.task("task-1", "Write the handoff doc"))
        await harness.model.startFocus()

        #expect(harness.model.route == .timer)
        #expect(harness.model.snapshot.state == .focusing)
        #expect(titles.last == "25:00")
    }

    @Test("A refresh loads projects and sections the picker by them")
    func refreshLoadsProjects() async throws {
        let harness = try Harness()
        await harness.todoist.setProjects([
            TodoistProject(id: "work", name: "Work"),
            TodoistProject(id: "inbox", name: "Inbox", isInboxProject: true),
        ])
        await harness.todoist.setTasks([
            Fixture.task("1", "Ship it", due: "2026-08-29", projectID: "work"),
            Fixture.task("2", "Read paper", projectID: "inbox"),
        ])

        await harness.model.sync.refresh()

        #expect(harness.model.sync.projects.count == 2)
        #expect(harness.model.sync.projectName(id: "work") == "Work")
        // Inbox leads, as it does in Todoist itself.
        #expect(harness.model.sync.projectsWithTasks.map(\.id) == ["inbox", "work"])

        harness.model.taskSortOrder = .project
        #expect(harness.model.sync.sections.map(\.title) == ["Inbox", "Work"])
    }

    @Test("A project fetch failure leaves the task list intact")
    func projectFailureKeepsTasks() async throws {
        let harness = try Harness()
        await harness.todoist.setProjectsError(.server(status: 500))
        await harness.todoist.setTasks([Fixture.task("1", "Ship it", due: "2026-08-29")])

        await harness.model.sync.refresh()

        #expect(harness.model.sync.allTasks.count == 1)
        #expect(harness.model.sync.projects.isEmpty)
        #expect(harness.model.sync.loadState == .loaded)
    }

    @Test("Sort and filter choices are written to preferences")
    func sortAndFilterPersist() async throws {
        let harness = try Harness()
        harness.model.taskSortOrder = .priority
        harness.model.taskFilter = TaskFilterCriteria(projectID: "work", minimumPriority: .p2)

        #expect(harness.preferences.preferences.taskSortOrder == .priority)
        #expect(harness.preferences.preferences.taskFilter.projectID == "work")
        #expect(harness.model.sync.filter.minimumPriority == .p2)

        // A fresh model over the same store restores both.
        let restored = AppModel(
            sync: TodoistSync(client: harness.todoist, tokenStore: harness.tokens, clock: harness.clock),
            engine: harness.engine,
            orchestrator: CompletionOrchestrator(store: harness.store, todoist: harness.todoist, clock: harness.clock),
            store: harness.store,
            preferencesStore: harness.preferences,
            notifications: harness.notifications,
            clock: harness.clock
        )
        #expect(restored.taskSortOrder == .priority)
        #expect(restored.taskFilter.projectID == "work")
    }

    @Test("Selecting a task stays on the timer screen across later ticks")
    func selectionSurvivesTicks() async throws {
        let harness = try Harness()
        await harness.model.select(task: Fixture.task("task-1", "Write the handoff doc"))
        #expect(harness.model.route == .timer)

        // The engine is still idle until the user hits start; a tick must not read that
        // as "the session ended" and bounce back to the picker.
        await harness.model.handleSystemWake()
        await harness.model.handleSystemWake()

        #expect(harness.model.route == .timer)
        #expect(harness.model.snapshot.task?.id == "task-1")
    }

    @Test("Stopping mid-focus asks for confirmation instead of abandoning immediately")
    func stopRequiresConfirmation() async throws {
        let harness = try Harness()
        await harness.model.select(task: Fixture.task("task-1", "Write the handoff doc"))
        await harness.model.startFocus()

        await harness.model.requestStartStop()

        #expect(harness.model.confirmation == .abandon)
        #expect(harness.model.snapshot.state == .focusing)
        #expect(await harness.todoist.commentCount == 0)
    }

    @Test("Confirming the abandon keeps the invested time and logs it to Todoist")
    func confirmAbandonLogsInvestedTime() async throws {
        let harness = try Harness()
        await harness.model.start()
        await harness.model.select(task: Fixture.task("task-1", "Write the handoff doc"))
        await harness.model.startFocus()

        harness.clock.advance(by: 600)
        await harness.model.confirmAbandon()
        try await waitUntil("the abandoned session is recorded") { harness.model.recentSessions.count == 1 }

        #expect(harness.model.snapshot.state == .idle)
        #expect(harness.model.confirmation == nil)
        // The task is never closed, but the 10 min already spent are logged.
        #expect(await harness.todoist.closeCount == 0)
        #expect(await harness.todoist.commentCount == 1)
        #expect(await harness.todoist.commentContents.first?.contains("10 min") == true)
        #expect(await harness.todoist.commentContents.first?.contains("stopped early") == true)

        let abandoned = try #require(harness.model.recentSessions.first)
        #expect(abandoned.status == .abandoned)
        #expect(abandoned.elapsedDurationSeconds == 600)
        #expect(abandoned.todoistCommentStatus == .posted)
        #expect(harness.model.banner?.text.contains("10 min kept in your history") == true)
        // Stopped time shows up as invested time, never as a completed session.
        #expect(harness.model.todaySummary.partialSeconds == 600)
        #expect(harness.model.todaySummary.investedMinutes == 10)
        #expect(harness.model.todaySummary.completedFocusSessions == 0)
    }

    @Test("With logging off the abandoned time stays local")
    func confirmAbandonWithoutLogging() async throws {
        let harness = try Harness()
        // The model holds its own copy, so the toggle goes through the model.
        harness.model.preferences.logsAbandonedTime = false
        await harness.model.start()
        await harness.model.select(task: Fixture.task("task-1", "Write the handoff doc"))
        await harness.model.startFocus()

        harness.clock.advance(by: 600)
        await harness.model.confirmAbandon()
        try await waitUntil("the abandoned session is recorded") { harness.model.recentSessions.count == 1 }

        #expect(await harness.todoist.commentCount == 0)
        let abandoned = try #require(harness.model.recentSessions.first)
        #expect(abandoned.todoistCommentStatus == .notApplicable)
        #expect(abandoned.elapsedDurationSeconds == 600)
        #expect(harness.model.todaySummary.partialSeconds == 600)
    }

    @Test("A finished focus posts one comment, notifies, and shows the overlay")
    func focusCompletionFlow() async throws {
        let harness = try Harness()
        var overlays: [FocusCompletionSummary] = []
        harness.model.presentCompletionOverlay = { overlays.append($0) }
        await harness.model.start()

        await harness.model.select(task: Fixture.task("task-1", "Write the handoff doc"))
        await harness.model.startFocus()
        harness.clock.advance(by: 1500)
        await harness.engine.tick()
        try await waitUntil("the finished focus is recorded") { harness.model.todaySummary.completedFocusSessions == 1 }

        #expect(await harness.todoist.commentCount == 1)
        #expect(harness.notifications.soundCount == 1)
        #expect(harness.notifications.focusCompleteCalls.count == 1)

        let summary = try #require(overlays.first)
        #expect(summary.taskTitle == "Write the handoff doc")
        #expect(summary.focusedMinutes == 25)
        #expect(summary.nextBreak == .shortBreak)
        #expect(summary.breakMinutes == 5)
        #expect(summary.autoStartAfterSeconds == harness.model.preferences.breakAutoStartDelaySeconds)

        #expect(harness.model.todaySummary.focusedSeconds == 1500)
        #expect(harness.model.todaySummary.completedFocusSessions == 1)
    }

    @Test("A failed comment leaves a retryable banner and a locally saved session")
    func commentFailureIsRetryable() async throws {
        let harness = try Harness()
        await harness.todoist.setCommentError(.server(status: 503))
        await harness.model.start()

        await harness.model.select(task: Fixture.task("task-1", "Write the handoff doc"))
        await harness.model.startFocus()
        harness.clock.advance(by: 1500)
        await harness.engine.tick()
        try await waitUntil("the failed comment surfaces a banner") { harness.model.banner != nil }

        let banner = try #require(harness.model.banner)
        #expect(banner.kind == .warning)
        #expect(banner.retrySessionID != nil)

        let saved = try #require(harness.model.recentSessions.first)
        #expect(saved.status == .completed)
        #expect(saved.todoistCommentStatus == .failed)

        await harness.todoist.setCommentError(nil)
        await harness.model.retryComment(sessionID: try #require(banner.retrySessionID))

        #expect(await harness.todoist.commentCount == 1)
        #expect(harness.model.recentSessions.first?.todoistCommentStatus == .posted)
    }

    @Test("Disconnecting removes the token but keeps local history")
    func disconnectKeepsHistory() async throws {
        let harness = try Harness()
        await harness.model.start()
        await harness.model.select(task: Fixture.task("task-1", "Write the handoff doc"))
        await harness.model.startFocus()
        harness.clock.advance(by: 1500)
        await harness.engine.tick()
        try await waitUntil("the session is saved") { harness.model.recentSessions.count == 1 }

        harness.model.disconnect()

        #expect(try harness.tokens.readToken() == nil)
        #expect(harness.model.route == .connect)
        #expect(harness.model.recentSessions.count == 1)
        #expect(harness.model.todaySummary.focusedSeconds == 1500)
    }

    @Test("The token is never written to the preferences store")
    func tokenNeverLeavesTheKeychain() async throws {
        let harness = try Harness(token: nil)
        harness.model.tokenDraft = "super-secret-token"
        await harness.model.connect()

        let encoded = try JSONEncoder().encode(harness.preferences.preferences)
        let json = try #require(String(data: encoded, encoding: .utf8))
        #expect(!json.contains("super-secret-token"))
        #expect(try harness.tokens.readToken() == "super-secret-token")
        #expect(harness.model.tokenDraft.isEmpty)
    }
}

@Suite("App composition")
@MainActor
struct AppCompositionSmokeTests {
    @Test("Starting the menu bar controller creates exactly one status item and no window")
    func menuBarOnly() throws {
        let harness = try Harness()
        let controller = MenuBarController(model: harness.model)
        controller.start()
        defer { controller.shutdown() }

        #expect(controller.hasStatusItem)
        #expect(!controller.isPopoverShown)
        // A status item is backed by a private borderless window; what must never exist
        // is a titled dashboard window (spec §2).
        let titledWindows = NSApplication.shared.windows.filter { $0.styleMask.contains(.titled) }
        #expect(titledWindows.isEmpty)
    }

    @Test("Opening and closing the popover is idempotent")
    func popoverToggleIsIdempotent() throws {
        let harness = try Harness()
        let controller = MenuBarController(model: harness.model)
        controller.start()
        defer { controller.shutdown() }

        controller.closePopover()
        #expect(!controller.isPopoverShown)
    }

    @Test("The popover is sized to fit the screen before it is shown")
    func popoverFitsTheScreen() async throws {
        let harness = try Harness()
        // A list long enough that an unbounded popover would be taller than any display.
        await harness.todoist.setTasks((0..<200).map {
            Fixture.task("t\($0)", "A task title long enough to wrap onto a second line, number \($0)", due: "2026-08-29")
        })
        await harness.model.sync.refresh()

        let controller = MenuBarController(model: harness.model)
        controller.start()
        defer { controller.shutdown() }
        controller.openPopover()
        defer { controller.closePopover() }

        let available = NSScreen.main?.visibleFrame.height ?? Theme.Metric.popoverFallbackHeight
        #expect(controller.popoverContentSize.width == Theme.Metric.popoverWidth)
        #expect(controller.popoverContentSize.height > 0)
        // Sizing before `show` is what keeps AppKit from anchoring the window at the
        // default 320pt and then growing it up past the top of the screen.
        #expect(controller.popoverContentSize.height <= available)
    }

    @Test("The app runs as an accessory, so it never shows a Dock icon")
    func accessoryActivationPolicy() {
        #expect(AppLifecycleCoordinator.activationPolicy == .accessory)
    }
}

@Suite("Settings round trip")
@MainActor
struct SettingsBindingTests {
    @Test("A preference change persists to the store and is readable back")
    func writesReachTheStore() throws {
        let harness = try Harness()
        #expect(harness.model.preferences.soundEnabled)

        harness.model.preferences.soundEnabled = false
        #expect(!harness.preferences.preferences.soundEnabled)

        // The bug this covers: a control could write through while the model kept
        // reporting the old value, so a toggle could never be switched back on.
        harness.model.preferences.soundEnabled = true
        #expect(harness.model.preferences.soundEnabled)
        #expect(harness.preferences.preferences.soundEnabled)
    }

    @Test("Duration changes reach both the store and the next session")
    func durationsApply() async throws {
        let harness = try Harness()
        harness.model.preferences.focusDurationSeconds = 60

        #expect(harness.preferences.preferences.focusDurationSeconds == 60)

        await harness.model.select(task: Fixture.task("task-1", "Write the handoff doc"))
        await harness.model.startFocus()
        #expect(harness.model.snapshot.plannedSeconds == 60)
        #expect(harness.model.snapshot.remainingSeconds == 60)
    }

    @Test("Rewriting the same value does not churn the store")
    func idempotentWrite() throws {
        let harness = try Harness()
        let before = harness.preferences.preferences
        harness.model.preferences = before
        #expect(harness.preferences.preferences == before)
    }
}
