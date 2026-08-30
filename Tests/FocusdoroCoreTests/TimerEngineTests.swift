import Foundation
import Testing
@testable import FocusdoroCore

@Suite("Timer engine")
struct TimerEngineTests {
    private func makeEngine(
        now: Date = Fixture.date("2026-08-29 09:00:00"),
        preferences: AppPreferences = .default,
        persistence: TimerStatePersisting = InMemoryTimerStateStore()
    ) -> (TimerEngine, MutableDateProvider, InMemoryPreferencesStore) {
        let clock = MutableDateProvider(now: now)
        let prefs = InMemoryPreferencesStore(preferences)
        return (TimerEngine(clock: clock, persistence: persistence, preferences: prefs), clock, prefs)
    }

    @Test("Starts idle with no active phase")
    func startsIdle() async {
        let (engine, _, _) = makeEngine()
        let snapshot = await engine.snapshot()
        #expect(snapshot.state == .idle)
        #expect(snapshot.phase == nil)
        #expect(snapshot.remainingSeconds == 0)
    }

    @Test("Starting focus sets a deadline exactly one focus duration out")
    func startFocus() async {
        let (engine, clock, _) = makeEngine()
        let id = await engine.startFocus(task: Fixture.task)
        #expect(id != nil)

        var snapshot = await engine.snapshot()
        #expect(snapshot.state == .focusing)
        #expect(snapshot.phase == .focus)
        #expect(snapshot.remainingSeconds == 1500)
        #expect(snapshot.task == Fixture.task)

        clock.advance(by: 1)
        snapshot = await engine.snapshot()
        #expect(snapshot.remainingSeconds == 1499)
        #expect(snapshot.elapsedSeconds == 1)
        #expect(snapshot.formattedRemaining == "24:59")
    }

    @Test("A second start while focusing is ignored")
    func doubleStartIgnored() async {
        let (engine, _, _) = makeEngine()
        let first = await engine.startFocus(task: Fixture.task)
        let second = await engine.startFocus(task: SelectedTask(id: "other", title: "Other"))
        #expect(second == nil)
        let snapshot = await engine.snapshot()
        #expect(snapshot.sessionID == first)
        #expect(snapshot.task == Fixture.task)
    }

    @Test("Snapshots are pure projections of the deadline, not accumulated ticks")
    func snapshotIsProjection() async {
        let (engine, clock, _) = makeEngine()
        await engine.startFocus(task: Fixture.task, duration: 60)
        // Jump 30 s in one step without any intermediate tick.
        clock.advance(by: 30)
        let snapshot = await engine.snapshot()
        #expect(snapshot.remainingSeconds == 30)
        #expect(snapshot.elapsedSeconds == 30)
    }

    @Test("Pause is not available during focus")
    func pauseUnavailable() async {
        let (engine, _, _) = makeEngine()
        await engine.startFocus(task: Fixture.task)
        await #expect(throws: TimerEngineError.pauseNotSupported) {
            try await engine.requestPause()
        }
        let snapshot = await engine.snapshot()
        #expect(snapshot.state == .focusing)
    }

    @Test("Reaching zero emits focusFinished once and moves to the break prompt")
    func focusCompletionEmitsOnce() async {
        let (engine, clock, _) = makeEngine()
        let events = await engine.events()
        await engine.startFocus(task: Fixture.task, duration: 60)

        clock.advance(by: 60)
        await engine.tick()
        // Extra ticks after the deadline must not re-fire the terminal event.
        await engine.tick()
        await engine.tick()

        var collected: [TimerEvent] = []
        for await event in events {
            collected.append(event)
            break
        }

        #expect(collected.count == 1)
        guard case .focusFinished(_, let task, let elapsed, let planned) = collected[0] else {
            Issue.record("Expected focusFinished, got \(collected)")
            return
        }
        #expect(task == Fixture.task)
        #expect(elapsed == 60)
        #expect(planned == 60)

        let snapshot = await engine.snapshot()
        #expect(snapshot.state == .breakPrompt(next: .shortBreak))
        #expect(await engine.completedFocusSessions() == 1)
    }

    @Test("Long break arrives on the fourth completed focus session")
    func longBreakCadence() async {
        let (engine, clock, _) = makeEngine()
        for index in 1...4 {
            await engine.startFocus(task: Fixture.task, duration: 10)
            clock.advance(by: 10)
            await engine.tick()
            let snapshot = await engine.snapshot()
            let expected: TimerPhase = index == 4 ? .longBreak : .shortBreak
            #expect(snapshot.state == .breakPrompt(next: expected), "session \(index)")
            await engine.skipBreak()
        }
    }

    @Test("Cadence honours a custom long-break interval")
    func customCadence() async {
        var preferences = AppPreferences.default
        preferences.longBreakCadence = 2
        let (engine, clock, _) = makeEngine(preferences: preferences)
        for index in 1...2 {
            await engine.startFocus(task: Fixture.task, duration: 5)
            clock.advance(by: 5)
            await engine.tick()
            let snapshot = await engine.snapshot()
            #expect(snapshot.state == .breakPrompt(next: index == 2 ? .longBreak : .shortBreak))
            await engine.skipBreak()
        }
    }

    @Test("Abandon emits once with measured elapsed time and clears the timer")
    func abandon() async {
        let (engine, clock, _) = makeEngine()
        let events = await engine.events()
        await engine.startFocus(task: Fixture.task, duration: 600)
        clock.advance(by: 125)

        let abandonedID = await engine.confirmAbandon()
        #expect(abandonedID != nil)
        // A repeat confirmation has nothing left to abandon.
        #expect(await engine.confirmAbandon() == nil)

        var collected: [TimerEvent] = []
        for await event in events {
            collected.append(event)
            break
        }
        guard case .sessionAbandoned(_, _, let elapsed, let planned, let phase) = collected[0] else {
            Issue.record("Expected sessionAbandoned")
            return
        }
        #expect(elapsed == 125)
        // The session's own planned length travels with the event, so a one-off length
        // is what gets recorded rather than whatever the default happens to be now.
        #expect(planned == 600)
        #expect(phase == .focus)
        #expect(await engine.currentState() == .idle)
    }

    @Test("Complete task emits taskCompletionRequested with measured time")
    func completeTask() async {
        let (engine, clock, _) = makeEngine()
        let events = await engine.events()
        await engine.startFocus(task: Fixture.task, duration: 1500)
        clock.advance(by: 421)

        let id = await engine.completeTask()
        #expect(id != nil)

        var collected: [TimerEvent] = []
        for await event in events {
            collected.append(event)
            break
        }
        guard case .taskCompletionRequested(_, let task, let elapsed, let planned) = collected[0] else {
            Issue.record("Expected taskCompletionRequested")
            return
        }
        #expect(task == Fixture.task)
        #expect(elapsed == 421)
        #expect(planned == 1500)
        #expect(await engine.currentState() == .idle)
    }

    @Test("Complete task is rejected outside focus")
    func completeTaskOnlyDuringFocus() async {
        let (engine, _, _) = makeEngine()
        #expect(await engine.completeTask() == nil)
        await engine.startBreak(.shortBreak, duration: 30)
        #expect(await engine.completeTask() == nil)
    }

    // MARK: - Persistence and recovery

    @Test("Relaunch reconstructs remaining time from the persisted deadline")
    func relaunchRecovery() async {
        let persistence = InMemoryTimerStateStore()
        let (engine, clock, _) = makeEngine(persistence: persistence)
        await engine.startFocus(task: Fixture.task, duration: 1500)
        clock.advance(by: 300)

        // Fresh engine, same persisted state and the same wall clock.
        let restoredClock = MutableDateProvider(now: clock.now)
        let restored = TimerEngine(
            clock: restoredClock,
            persistence: persistence,
            preferences: InMemoryPreferencesStore()
        )
        await restored.restore()

        let snapshot = await restored.snapshot()
        #expect(snapshot.state == .focusing)
        #expect(snapshot.remainingSeconds == 1200)
        #expect(snapshot.task == Fixture.task)
    }

    @Test("A deadline already in the past completes on restore and is never extended")
    func pastDeadlineCompletesImmediately() async {
        let persistence = InMemoryTimerStateStore()
        let (engine, clock, _) = makeEngine(persistence: persistence)
        await engine.startFocus(task: Fixture.task, duration: 600)

        // Machine slept through the whole session and then some.
        clock.advance(by: 4000)
        let restoredClock = MutableDateProvider(now: clock.now)
        let restored = TimerEngine(
            clock: restoredClock,
            persistence: persistence,
            preferences: InMemoryPreferencesStore()
        )
        let events = await restored.events()
        await restored.restore()

        var collected: [TimerEvent] = []
        for await event in events {
            collected.append(event)
            break
        }
        guard case .focusFinished(_, _, let elapsed, let planned) = collected[0] else {
            Issue.record("Expected focusFinished on restore")
            return
        }
        // Sleep time beyond the planned duration is not counted as focused work.
        #expect(elapsed == 600)
        #expect(planned == 600)
        #expect(await restored.currentState() == .breakPrompt(next: .shortBreak))
    }

    @Test("Wake handling completes a deadline that elapsed while asleep")
    func wakeCompletes() async {
        let (engine, clock, _) = makeEngine()
        await engine.startFocus(task: Fixture.task, duration: 120)
        clock.advance(by: 130)
        await engine.handleWake()
        #expect(await engine.currentState() == .breakPrompt(next: .shortBreak))
    }

    @Test("Persisted state is cleared once a session ends")
    func persistenceClearedOnEnd() async {
        let persistence = InMemoryTimerStateStore()
        let (engine, clock, _) = makeEngine(persistence: persistence)
        await engine.startFocus(task: Fixture.task, duration: 30)
        #expect(persistence.load() != nil)
        clock.advance(by: 30)
        await engine.tick()
        #expect(persistence.load() == nil)
    }

    // MARK: - Breaks

    @Test("Break countdown runs and finishes back at idle")
    func breakLifecycle() async {
        let (engine, clock, _) = makeEngine()
        let events = await engine.events()
        await engine.startBreak(.shortBreak, duration: 300)
        #expect(await engine.currentState() == .shortBreaking)

        clock.advance(by: 300)
        await engine.tick()

        var collected: [TimerEvent] = []
        for await event in events {
            collected.append(event)
            break
        }
        guard case .breakFinished(_, let phase) = collected[0] else {
            Issue.record("Expected breakFinished")
            return
        }
        #expect(phase == .shortBreak)
        #expect(await engine.currentState() == .idle)
    }

    @Test("Focus cannot be started as a break phase and vice versa")
    func phaseGuards() async {
        let (engine, _, _) = makeEngine()
        #expect(await engine.startBreak(.focus) == nil)
    }

    @Test("Selecting a different task mid-focus is ignored")
    func taskLockedDuringFocus() async {
        let (engine, _, _) = makeEngine()
        await engine.startFocus(task: Fixture.task, duration: 100)
        await engine.selectTask(SelectedTask(id: "x", title: "Something else"))
        let snapshot = await engine.snapshot()
        #expect(snapshot.task == Fixture.task)
    }

    @Test("Selecting a task records it as the last selection preference")
    func selectionPersistsPreference() async {
        let (engine, _, prefs) = makeEngine()
        await engine.selectTask(Fixture.task)
        #expect(prefs.preferences.lastSelectedTaskID == "task-1")
    }

    @Test("Skipping a break is ignored outside the break prompt")
    func skipBreakOnlyValidFromPrompt() async {
        let (engine, _, _) = makeEngine()

        // Idle: nothing to skip.
        await engine.skipBreak()
        #expect(await engine.currentState() == .idle)

        // Mid-focus: skipping must not tear down the running session.
        await engine.startFocus(task: Fixture.task, duration: 100)
        await engine.skipBreak()
        var snapshot = await engine.snapshot()
        #expect(snapshot.state == .focusing)
        #expect(snapshot.remainingSeconds == 100)

        // Mid-break: same guard applies; only the prompt itself can be skipped.
        _ = await engine.confirmAbandon()
        await engine.startBreak(.shortBreak, duration: 60)
        await engine.skipBreak()
        snapshot = await engine.snapshot()
        #expect(snapshot.state == .shortBreaking)
    }

    @Test("Restoring with nothing persisted leaves the engine idle")
    func restoreWithNothingPersistedIsNoop() async {
        let persistence = InMemoryTimerStateStore()
        let (engine, _, _) = makeEngine(persistence: persistence)
        await engine.restore()
        let snapshot = await engine.snapshot()
        #expect(snapshot.state == .idle)
        #expect(snapshot.task == nil)
    }
}
