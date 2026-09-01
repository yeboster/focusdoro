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
    private var _updateModes: [Bool] = []

    var focusCompleteCalls: [(String, TimerPhase)] { lock.withLock { _focusCompleteCalls } }
    var breakCompleteCalls: [TimerPhase] { lock.withLock { _breakCompleteCalls } }
    var soundCount: Int { lock.withLock { _soundCount } }
    var updateCount: Int { lock.withLock { _updateModes.count } }
    var updateModes: [Bool] { lock.withLock { _updateModes } }

    func requestAuthorizationIfNeeded() async -> Bool { true }
    func notifyFocusComplete(taskTitle: String, nextBreak: TimerPhase) {
        lock.withLock { _focusCompleteCalls.append((taskTitle, nextBreak)) }
    }
    func notifyBreakComplete(nextPhase: TimerPhase) {
        lock.withLock { _breakCompleteCalls.append(nextPhase) }
    }
    func notifyUpdateAvailable(automaticInstallEnabled: Bool) {
        lock.withLock { _updateModes.append(automaticInstallEnabled) }
    }
    func playCompletionSound() { lock.withLock { _soundCount += 1 } }
}

private actor StubUpdater: UpdateChecking, UpdateInstalling {
    let release: UpdateRelease?
    private(set) var installed: [UpdateRelease] = []

    init(release: UpdateRelease?) { self.release = release }

    func check() async throws -> UpdateRelease? { release }
    func install(_ release: UpdateRelease) async throws { installed.append(release) }
}

private actor DelayedStubUpdater: UpdateChecking, UpdateInstalling {
    let release: UpdateRelease?
    private(set) var installCount = 0

    init(release: UpdateRelease?) { self.release = release }

    func check() async throws -> UpdateRelease? { release }
    func install(_ release: UpdateRelease) async throws {
        installCount += 1
        try? await Task.sleep(for: .milliseconds(50))
    }
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

    init(
        token: String? = "test-token",
        updateChecker: UpdateChecking? = nil,
        updateInstaller: UpdateInstalling? = nil
    ) throws {
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
            calendar: Fixture.calendar(),
            updateChecker: updateChecker,
            updateInstaller: updateInstaller
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

        harness.model.taskDateScope = .all
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

    @Test("Scope, sort, and filter choices are written to preferences")
    func sortAndFilterPersist() async throws {
        let harness = try Harness()
        harness.model.taskDateScope = .upcoming
        harness.model.taskSortOrder = .priority
        harness.model.taskFilter = TaskFilterCriteria(projectID: "work", minimumPriority: .p2)

        #expect(harness.preferences.preferences.taskDateScope == .upcoming)
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
        #expect(restored.taskDateScope == .upcoming)
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
        // The banner is set before the history reload finishes, so waiting on the
        // banner alone races the record this test then reads.
        try await waitUntil("the failed comment surfaces a banner and its session") {
            harness.model.banner != nil && !harness.model.recentSessions.isEmpty
        }

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

    @Test("Starting the offered break dismisses the completion overlay and begins the break countdown")
    func startBreakDismissesOverlayAndBeginsCountdown() async throws {
        let harness = try Harness()
        await harness.model.select(task: Fixture.task("task-1", "Write the handoff doc"))
        await harness.model.startFocus()
        harness.clock.advance(by: 1500)
        await harness.engine.tick()
        await harness.model.handleSystemWake()
        #expect(harness.model.snapshot.state == .breakPrompt(next: .shortBreak))

        var dismissed = false
        harness.model.dismissCompletionOverlay = { dismissed = true }
        await harness.model.startBreak(.shortBreak)

        #expect(dismissed)
        #expect(harness.model.snapshot.state == .shortBreaking)
    }

    @Test("Skipping the offered break dismisses the overlay, returns to idle, and routes to the task list")
    func skipBreakDismissesOverlayAndReturnsToTasks() async throws {
        let harness = try Harness()
        await harness.model.select(task: Fixture.task("task-1", "Write the handoff doc"))
        await harness.model.startFocus()
        harness.clock.advance(by: 1500)
        await harness.engine.tick()
        await harness.model.handleSystemWake()
        #expect(harness.model.snapshot.state == .breakPrompt(next: .shortBreak))

        var dismissed = false
        harness.model.dismissCompletionOverlay = { dismissed = true }
        await harness.model.skipBreak()

        #expect(dismissed)
        #expect(harness.model.snapshot.state == .idle)
        #expect(harness.model.route == .tasks)
    }

    @Test("Dismissing the banner clears it without touching anything else")
    func dismissBannerClearsIt() throws {
        let harness = try Harness()
        harness.model.banner = BannerMessage(kind: .info, text: "Something happened.")

        harness.model.dismissBanner()

        #expect(harness.model.banner == nil)
    }

    @Test("Reloading history alone, without a fresh session, still picks up sessions written directly to the store")
    func reloadHistoryPicksUpExternalWrites() throws {
        let harness = try Harness()
        #expect(harness.model.recentSessions.isEmpty)

        let session = SessionRecord(
            taskID: "task-1",
            taskTitleSnapshot: "Write the handoff doc",
            startedAt: Fixture.date("2026-08-29 09:00:00"),
            endedAt: Fixture.date("2026-08-29 09:25:00"),
            plannedDurationSeconds: 1500,
            elapsedDurationSeconds: 1500,
            kind: .focus,
            status: .completed,
            todoistCommentStatus: .posted,
            createdAt: Fixture.date("2026-08-29 09:00:00")
        )
        try harness.store.insertSession(session)
        // Nothing refreshes the observable copies until this is called explicitly.
        #expect(harness.model.recentSessions.isEmpty)

        harness.model.reloadHistory()

        #expect(harness.model.recentSessions.count == 1)
        #expect(harness.model.todaySummary.completedFocusSessions == 1)
    }

    @Test("Creating a task clears its draft, selects it, and starts focus")
    func createTaskAndFocus() async throws {
        let harness = try Harness()
        await harness.todoist.setCreatedTask(Fixture.task("new-task", "Plan release"))
        harness.model.newTaskDraft = "  Plan release  "

        await harness.model.createTaskAndFocus()

        #expect(harness.model.newTaskDraft.isEmpty)
        #expect(await harness.todoist.createdContents == ["Plan release"])
        #expect(harness.model.sync.allTasks.map(\.id) == ["new-task"])
        #expect(harness.model.snapshot.task?.id == "new-task")
        #expect(harness.model.snapshot.state == .focusing)
        #expect(harness.model.route == .timer)
    }

    @Test("Concurrent quick-add submissions create and focus only the first task")
    func concurrentCreateTaskAndFocusIsIgnored() async throws {
        let harness = try Harness()
        let createdTask = Fixture.task("new-task", "Plan release")
        await harness.todoist.setCreatedTask(createdTask)
        await harness.todoist.setCreateTaskDelay(seconds: 0.05)
        harness.model.newTaskDraft = "Plan release"

        let firstSubmission = Task { await harness.model.createTaskAndFocus() }
        while !harness.model.isBusy { await Task.yield() }
        harness.model.newTaskDraft = "Duplicate release"
        let secondSubmission = Task { await harness.model.createTaskAndFocus() }
        await firstSubmission.value
        await secondSubmission.value

        #expect(await harness.todoist.createdContents == ["Plan release"])
        #expect(harness.model.snapshot.task?.id == createdTask.id)
        #expect(harness.model.snapshot.state == .focusing)
    }

    @Test("Creating a blank task is inert")
    func blankTaskCreationIsInert() async throws {
        let harness = try Harness()
        harness.model.newTaskDraft = " \n\t "

        await harness.model.createTaskAndFocus()

        #expect(harness.model.newTaskDraft.isEmpty)
        #expect(await harness.todoist.createdContents.isEmpty)
        #expect(harness.model.snapshot.state == .idle)
        #expect(harness.model.recentSessions.isEmpty)
    }

    @Test("Completing a picker task closes it without a session or comment")
    func pickerCompletionDoesNotCreateFocusRecord() async throws {
        let harness = try Harness()
        let task = Fixture.task("task-1", "Write the handoff doc")
        await harness.todoist.setTasks([task])
        await harness.model.sync.refresh()

        harness.model.requestCompleteTask(task)
        #expect(harness.model.confirmation == .completePickerTask)

        await harness.model.confirmCompleteTask()

        #expect(await harness.todoist.closeCount == 1)
        #expect(await harness.todoist.commentCount == 0)
        #expect(harness.model.sync.allTasks.isEmpty)
        #expect(harness.model.recentSessions.isEmpty)
        #expect(harness.model.snapshot.state == .idle)
        #expect(harness.model.banner?.kind == .success)
    }

    @Test("Failed picker completion preserves task without a session or comment")
    func failedPickerCompletionPreservesTask() async throws {
        let harness = try Harness()
        let task = Fixture.task("task-1", "Write the handoff doc")
        await harness.todoist.setTasks([task])
        await harness.model.sync.refresh()
        await harness.todoist.setCloseError(.server(status: 500))

        harness.model.requestCompleteTask(task)
        await harness.model.confirmCompleteTask()

        #expect(await harness.todoist.closeCount == 1)
        #expect(await harness.todoist.commentCount == 0)
        #expect(harness.model.sync.allTasks.map(\.id) == ["task-1"])
        #expect(harness.model.recentSessions.isEmpty)
        #expect(harness.model.banner?.kind == .error)
    }

    @Test("Requesting then confirming task completion closes the Todoist task, drops it locally, and bans a success message")
    func requestAndConfirmCompleteTaskEndToEnd() async throws {
        let harness = try Harness()
        await harness.todoist.setTasks([Fixture.task("task-1", "Write the handoff doc")])
        await harness.model.start()
        #expect(harness.model.sync.allTasks.count == 1)

        await harness.model.select(task: Fixture.task("task-1", "Write the handoff doc"))
        await harness.model.startFocus()
        harness.clock.advance(by: 600)

        harness.model.requestCompleteTask()
        #expect(harness.model.confirmation == .completeTask)
        #expect(harness.model.snapshot.state == .focusing)

        await harness.model.confirmCompleteTask()
        try await waitUntil("the completed task is recorded") { harness.model.recentSessions.count == 1 }

        #expect(harness.model.confirmation == nil)
        #expect(await harness.todoist.closeCount == 1)
        #expect(await harness.todoist.commentCount == 1)
        // The picker must not keep offering a task that was just closed.
        #expect(harness.model.sync.allTasks.isEmpty)
        #expect(harness.model.banner?.kind == .success)
        #expect(harness.model.banner?.text.contains("Write the handoff doc") == true)

        let saved = try #require(harness.model.recentSessions.first)
        #expect(saved.status == .completed)
        #expect(saved.elapsedDurationSeconds == 600)
    }

    @Test("Update discovery notifies but does not install when automatic installation is off")
    func disabledAutomaticUpdateInstallationOnlyAnnounces() async throws {
        let release = UpdateRelease(
            commitSHA: "0123456789abcdef0123456789abcdef01234567",
            assetURL: URL(string: "https://example.com/Focusdoro.dmg")!,
            assetDigest: "sha256:" + String(repeating: "a", count: 64)
        )
        let updater = StubUpdater(release: release)
        let harness = try Harness(updateChecker: updater, updateInstaller: updater)
        harness.model.preferences.automaticInstallUpdates = false

        await harness.model.start()
        try await waitUntil("the update is announced") { harness.notifications.updateCount == 1 }

        #expect(await updater.installed.isEmpty)
        #expect(harness.notifications.updateModes == [false])
        #expect(harness.model.banner?.offersUpdateInstall == true)
        harness.model.shutdown()
    }

    @Test("Update discovery installs once when automatic installation is on")
    func enabledAutomaticUpdateInstallationInstallsOnce() async throws {
        let release = UpdateRelease(
            commitSHA: "0123456789abcdef0123456789abcdef01234567",
            assetURL: URL(string: "https://example.com/Focusdoro.dmg")!,
            assetDigest: "sha256:" + String(repeating: "a", count: 64)
        )
        let updater = StubUpdater(release: release)
        let harness = try Harness(updateChecker: updater, updateInstaller: updater)
        harness.model.preferences.automaticInstallUpdates = true
        var terminationRequested = false
        harness.model.onUpdateInstallStarted = { terminationRequested = true }

        await harness.model.start()
        try await waitUntil("the update installs") { terminationRequested }

        #expect(await updater.installed == [release])
        #expect(harness.notifications.updateModes == [true])
        harness.model.shutdown()
    }

    @Test("Automatic installation remains enabled after staging an update")
    func automaticUpdateInstallationPreferenceSurvivesStaging() async throws {
        let release = UpdateRelease(
            commitSHA: "0123456789abcdef0123456789abcdef01234567",
            assetURL: URL(string: "https://example.com/Focusdoro.dmg")!,
            assetDigest: "sha256:" + String(repeating: "a", count: 64)
        )
        let updater = DelayedStubUpdater(release: release)
        let harness = try Harness(updateChecker: updater, updateInstaller: updater)
        harness.model.preferences.automaticInstallUpdates = true

        await harness.model.start()
        try await waitUntil("the update starts installing") { harness.model.isInstallingUpdate }

        #expect(harness.preferences.preferences.automaticInstallUpdates)
        harness.model.shutdown()
    }

    @Test("Installing an announced update requests app termination after staging")
    func updateInstallRequestsTermination() async throws {
        let release = UpdateRelease(
            commitSHA: "0123456789abcdef0123456789abcdef01234567",
            assetURL: URL(string: "https://example.com/Focusdoro.dmg")!,
            assetDigest: "sha256:" + String(repeating: "a", count: 64)
        )
        let updater = StubUpdater(release: release)
        let harness = try Harness(updateChecker: updater, updateInstaller: updater)
        var terminationRequested = false
        harness.model.onUpdateInstallStarted = { terminationRequested = true }

        await harness.model.start()
        try await waitUntil("the update is announced") {
            harness.model.banner?.offersUpdateInstall == true
        }
        #expect(harness.notifications.updateCount == 1)

        await harness.model.installUpdate()

        #expect(await updater.installed == [release])
        #expect(terminationRequested)
        harness.model.shutdown()
    }

    @Test("Install action resolves release after a cold launch")
    func coldLaunchUpdateInstallResolvesRelease() async throws {
        let release = UpdateRelease(
            commitSHA: "0123456789abcdef0123456789abcdef01234567",
            assetURL: URL(string: "https://example.com/Focusdoro.dmg")!,
            assetDigest: "sha256:" + String(repeating: "a", count: 64)
        )
        let updater = StubUpdater(release: release)
        let harness = try Harness(updateChecker: updater, updateInstaller: updater)
        var terminationRequested = false
        harness.model.onUpdateInstallStarted = { terminationRequested = true }

        // Notification action can cold-launch app before periodic check populates
        // in-memory state. Install intent must resolve validated latest metadata again.
        await harness.model.installUpdate()

        #expect(await updater.installed == [release])
        #expect(terminationRequested)
    }

    @Test("Concurrent install actions launch only one installer")
    func concurrentUpdateInstallIsGuarded() async throws {
        let release = UpdateRelease(
            commitSHA: "0123456789abcdef0123456789abcdef01234567",
            assetURL: URL(string: "https://example.com/Focusdoro.dmg")!,
            assetDigest: "sha256:" + String(repeating: "a", count: 64)
        )
        let updater = DelayedStubUpdater(release: release)
        let harness = try Harness(updateChecker: updater, updateInstaller: updater)
        var terminationCount = 0
        harness.model.onUpdateInstallStarted = { terminationCount += 1 }
        await harness.model.start()
        try await waitUntil("the update is announced") {
            harness.model.banner?.offersUpdateInstall == true
        }

        async let first: Void = harness.model.installUpdate()
        async let second: Void = harness.model.installUpdate()
        _ = await (first, second)

        #expect(await updater.installCount == 1)
        #expect(terminationCount == 1)
        harness.model.shutdown()
    }

    @Test("Waking after sleeping past the deadline completes the focus session immediately, not on the next tick")
    func systemWakeCompletesAnElapsedDeadline() async throws {
        let harness = try Harness()
        await harness.model.select(task: Fixture.task("task-1", "Write the handoff doc"))
        await harness.model.startFocus()

        // Simulate the machine sleeping through the entire session.
        harness.clock.advance(by: 1500)
        await harness.model.handleSystemWake()

        #expect(harness.model.snapshot.state == .breakPrompt(next: .shortBreak))
        #expect(harness.model.snapshot.completedFocusCount == 1)
    }
}

@Suite("App composition", .enabled(if: TestEnvironment.hasWindowServer))
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
