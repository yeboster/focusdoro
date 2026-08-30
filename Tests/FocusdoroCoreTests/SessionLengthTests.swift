import Foundation
import Testing
@testable import FocusdoroCore

/// A per-session focus length picked on the ready screen: a one-off sprint sized for the
/// task in front of you, which must never leak into the configured default.
@MainActor
private struct LengthHarness {
    let clock = MutableDateProvider(now: Fixture.date("2026-08-29 14:00:00"))
    let todoist = FakeTodoist()
    let tokens = InMemoryTokenStore()
    let preferences = InMemoryPreferencesStore()
    let store: SessionStore
    let engine: TimerEngine
    let model: AppModel

    init() throws {
        try tokens.saveToken("test-token")
        store = try Fixture.store()
        engine = TimerEngine(clock: clock, persistence: InMemoryTimerStateStore(), preferences: preferences)
        let sync = TodoistSync(client: todoist, tokenStore: tokens, clock: clock, calendar: Fixture.calendar())
        model = AppModel(
            sync: sync,
            engine: engine,
            orchestrator: CompletionOrchestrator(
                store: store, todoist: todoist, clock: clock, timeZone: Fixture.calendar().timeZone
            ),
            store: store,
            preferencesStore: preferences,
            notifications: NullNotifications(),
            clock: clock,
            calendar: Fixture.calendar()
        )
    }
}

private final class NullNotifications: NotificationPresenting, @unchecked Sendable {
    func requestAuthorizationIfNeeded() async -> Bool { true }
    func notifyFocusComplete(taskTitle: String, nextBreak: TimerPhase) {}
    func notifyBreakComplete(nextPhase: TimerPhase) {}
    func playCompletionSound() {}
}

@Suite("Session length adjustment")
@MainActor
struct SessionLengthTests {
    @Test("Without an override the ready screen shows the configured default")
    func defaultLength() throws {
        let harness = try LengthHarness()
        #expect(harness.model.plannedFocusSeconds == 1500)
        #expect(harness.model.plannedFocusMinutes == 25)
        #expect(harness.model.hasCustomFocusLength == false)
    }

    @Test("Stepping changes only this session, never the stored default")
    func steppingLeavesPreferencesAlone() throws {
        let harness = try LengthHarness()
        harness.model.adjustPlannedFocus(byMinutes: 10)
        #expect(harness.model.plannedFocusMinutes == 35)
        #expect(harness.model.hasCustomFocusLength)
        // The whole point of the override: the default the user configured survives.
        #expect(harness.model.preferences.focusDurationSeconds == 1500)
        #expect(harness.preferences.preferences.focusDurationSeconds == 1500)
    }

    @Test("The length clamps at both ends")
    func clamping() throws {
        let harness = try LengthHarness()
        harness.model.setPlannedFocus(minutes: 500)
        #expect(harness.model.plannedFocusMinutes == AppModel.focusLengthBounds.upperBound)
        #expect(harness.model.canLengthenFocus == false)

        harness.model.setPlannedFocus(minutes: -10)
        #expect(harness.model.plannedFocusMinutes == AppModel.focusLengthBounds.lowerBound)
        #expect(harness.model.canShortenFocus == false)
    }

    @Test("Stepping back onto the default drops the override")
    func steppingBackToDefaultClearsTheOverride() throws {
        let harness = try LengthHarness()
        harness.model.adjustPlannedFocus(byMinutes: AppModel.focusLengthStepMinutes)
        #expect(harness.model.hasCustomFocusLength)
        harness.model.adjustPlannedFocus(byMinutes: -AppModel.focusLengthStepMinutes)
        #expect(harness.model.plannedFocusMinutes == 25)
        #expect(harness.model.hasCustomFocusLength == false)
    }

    @Test("Reset returns to the configured default")
    func resetting() throws {
        let harness = try LengthHarness()
        harness.model.setPlannedFocus(minutes: 45)
        harness.model.resetPlannedFocus()
        #expect(harness.model.plannedFocusSeconds == 1500)
        #expect(harness.model.hasCustomFocusLength == false)
    }

    @Test("The chosen length is what the session actually runs for")
    func startFocusUsesTheOverride() async throws {
        let harness = try LengthHarness()
        await harness.model.start()
        await harness.model.select(task: Fixture.task("task-1", "Write the handoff doc"))
        harness.model.setPlannedFocus(minutes: 12)
        await harness.model.startFocus()

        #expect(harness.model.snapshot.plannedSeconds == 720)
        #expect(harness.model.snapshot.remainingSeconds == 720)
    }

    @Test("A running session ignores the stepper")
    func lengthIsLockedOnceStarted() async throws {
        let harness = try LengthHarness()
        await harness.model.start()
        await harness.model.select(task: Fixture.task("task-1", "Write the handoff doc"))
        harness.model.setPlannedFocus(minutes: 12)
        await harness.model.startFocus()

        // The deadline is written at start and never extended (spec §4).
        harness.model.adjustPlannedFocus(byMinutes: 30)
        #expect(harness.model.snapshot.plannedSeconds == 720)
        #expect(harness.model.plannedFocusMinutes == 12)
    }

    @Test("Picking a different task drops a length sized for the previous one")
    func switchingTaskResetsTheLength() async throws {
        let harness = try LengthHarness()
        await harness.model.start()
        await harness.model.select(task: Fixture.task("task-1", "Write the handoff doc"))
        harness.model.setPlannedFocus(minutes: 45)
        await harness.model.select(task: Fixture.task("task-2", "Review the PR"))
        #expect(harness.model.hasCustomFocusLength == false)
        #expect(harness.model.plannedFocusMinutes == 25)
    }

    @Test("Re-picking the same task keeps the length")
    func reselectingSameTaskKeepsTheLength() async throws {
        let harness = try LengthHarness()
        await harness.model.start()
        await harness.model.select(task: Fixture.task("task-1", "Write the handoff doc"))
        harness.model.setPlannedFocus(minutes: 45)
        await harness.model.select(task: Fixture.task("task-1", "Write the handoff doc"))
        #expect(harness.model.plannedFocusMinutes == 45)
    }

    @Test("A finished session records the length it was given and then forgets it")
    func finishedSessionRecordsTheChosenLength() async throws {
        let harness = try LengthHarness()
        await harness.model.start()
        await harness.model.select(task: Fixture.task("task-1", "Write the handoff doc"))
        harness.model.setPlannedFocus(minutes: 10)
        await harness.model.startFocus()

        harness.clock.advance(by: 600)
        await harness.engine.tick()
        try await waitUntil("the finished focus is recorded") {
            harness.model.todaySummary.completedFocusSessions == 1
        }

        let record = try #require(harness.model.recentSessions.first)
        #expect(record.plannedDurationSeconds == 600)
        #expect(record.elapsedDurationSeconds == 600)
        // Back to the default for whatever comes next.
        #expect(harness.model.hasCustomFocusLength == false)
        #expect(harness.model.plannedFocusMinutes == 25)
    }

    @Test("A stopped session is recorded against its own length, not today's default")
    func abandonedSessionRecordsTheChosenLength() async throws {
        let harness = try LengthHarness()
        await harness.model.start()
        await harness.model.select(task: Fixture.task("task-1", "Write the handoff doc"))
        harness.model.setPlannedFocus(minutes: 10)
        await harness.model.startFocus()

        harness.clock.advance(by: 300)
        await harness.model.confirmAbandon()
        try await waitUntil("the stopped session is recorded") { harness.model.recentSessions.count == 1 }

        let record = try #require(harness.model.recentSessions.first)
        #expect(record.plannedDurationSeconds == 600)
        #expect(record.elapsedDurationSeconds == 300)
        #expect(harness.model.hasCustomFocusLength == false)
    }
}
