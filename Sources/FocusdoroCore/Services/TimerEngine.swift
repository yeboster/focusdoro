import Foundation

/// Everything the engine needs to survive relaunch, sleep, and crash.
public struct PersistedTimerState: Codable, Equatable, Sendable {
    public var sessionID: UUID
    public var task: SelectedTask
    public var phase: TimerPhase
    public var startedAt: Date
    /// Absolute wall-clock deadline. Never extended once written.
    public var deadline: Date
    public var plannedSeconds: Int
    public var completedFocusCount: Int

    public init(
        sessionID: UUID,
        task: SelectedTask,
        phase: TimerPhase,
        startedAt: Date,
        deadline: Date,
        plannedSeconds: Int,
        completedFocusCount: Int
    ) {
        self.sessionID = sessionID
        self.task = task
        self.phase = phase
        self.startedAt = startedAt
        self.deadline = deadline
        self.plannedSeconds = plannedSeconds
        self.completedFocusCount = completedFocusCount
    }
}

public protocol TimerStatePersisting: AnyObject, Sendable {
    func save(_ state: PersistedTimerState?)
    func load() -> PersistedTimerState?
}

public final class UserDefaultsTimerStateStore: TimerStatePersisting, @unchecked Sendable {
    private static let key = "focusdoro.timerState.v1"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func save(_ state: PersistedTimerState?) {
        guard let state else {
            defaults.removeObject(forKey: Self.key)
            return
        }
        if let data = try? JSONEncoder().encode(state) {
            defaults.set(data, forKey: Self.key)
        }
    }

    public func load() -> PersistedTimerState? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode(PersistedTimerState.self, from: data)
    }
}

public final class InMemoryTimerStateStore: TimerStatePersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var state: PersistedTimerState?

    public init(_ state: PersistedTimerState? = nil) { self.state = state }

    public func save(_ state: PersistedTimerState?) {
        lock.lock(); defer { lock.unlock() }
        self.state = state
    }

    public func load() -> PersistedTimerState? {
        lock.lock(); defer { lock.unlock() }
        return state
    }
}

public enum TimerEngineError: Error, Equatable {
    case noActiveSession
    case pauseNotSupported
    case wrongPhase
}

/// Actor-isolated Pomodoro state machine.
///
/// Truth is the persisted absolute `deadline`, not accumulated ticks. `snapshot(now:)`
/// is a pure projection, so the UI can refresh at any cadence without drifting, and a
/// relaunch reconstructs remaining time exactly. There is no pause: spec §2.
public actor TimerEngine {
    private let clock: DateProviding
    private let persistence: TimerStatePersisting
    private let preferences: PreferencesStoring

    private(set) var state: TimerState = .idle
    private var active: PersistedTimerState?
    private var selectedTask: SelectedTask?
    private var completedFocusCount: Int = 0
    /// Session ids whose terminal event already fired. Guarantees exactly-once emission.
    private var firedTerminalEvents: Set<UUID> = []

    private var continuations: [UUID: AsyncStream<TimerEvent>.Continuation] = [:]

    public init(
        clock: DateProviding = SystemDateProvider(),
        persistence: TimerStatePersisting,
        preferences: PreferencesStoring
    ) {
        self.clock = clock
        self.persistence = persistence
        self.preferences = preferences
    }

    // MARK: - Event stream

    public func events() -> AsyncStream<TimerEvent> {
        AsyncStream { continuation in
            let id = UUID()
            self.continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }

    private func emit(_ event: TimerEvent) {
        for continuation in continuations.values { continuation.yield(event) }
    }

    // MARK: - Selection

    public func selectTask(_ task: SelectedTask?) {
        // Changing the task mid-focus would silently rewrite what the session recorded.
        guard state == .idle || state.activePhase == nil else { return }
        selectedTask = task
        var prefs = preferences.preferences
        prefs.lastSelectedTaskID = task?.id
        preferences.preferences = prefs
    }

    public func currentTask() -> SelectedTask? { selectedTask }

    public func currentState() -> TimerState { state }

    public func completedFocusSessions() -> Int { completedFocusCount }

    public func setCompletedFocusCount(_ count: Int) {
        completedFocusCount = max(0, count)
    }

    // MARK: - Start

    @discardableResult
    public func startFocus(task: SelectedTask, duration: Int? = nil) -> UUID? {
        guard state.activePhase == nil else { return nil }
        let seconds = max(1, duration ?? preferences.preferences.focusDurationSeconds)
        selectedTask = task
        let now = clock.now
        let persisted = PersistedTimerState(
            sessionID: UUID(),
            task: task,
            phase: .focus,
            startedAt: now,
            deadline: now.addingTimeInterval(TimeInterval(seconds)),
            plannedSeconds: seconds,
            completedFocusCount: completedFocusCount
        )
        active = persisted
        state = .focusing
        persistence.save(persisted)
        return persisted.sessionID
    }

    @discardableResult
    public func startBreak(_ phase: TimerPhase, duration: Int? = nil) -> UUID? {
        guard phase.isBreak, state.activePhase == nil else { return nil }
        let seconds = max(1, duration ?? preferences.preferences.duration(for: phase))
        let now = clock.now
        let persisted = PersistedTimerState(
            sessionID: UUID(),
            task: selectedTask ?? SelectedTask(id: "", title: ""),
            phase: phase,
            startedAt: now,
            deadline: now.addingTimeInterval(TimeInterval(seconds)),
            plannedSeconds: seconds,
            completedFocusCount: completedFocusCount
        )
        active = persisted
        state = phase == .longBreak ? .longBreaking : .shortBreaking
        persistence.save(persisted)
        return persisted.sessionID
    }

    /// Break offered after the focus session that just finished.
    public func skipBreak() {
        guard case .breakPrompt = state else { return }
        state = .idle
        active = nil
        persistence.save(nil)
    }

    // MARK: - Pause is not a thing

    public func requestPause() throws {
        throw TimerEngineError.pauseNotSupported
    }

    // MARK: - Ticking

    /// Advances the state machine to `now`. Idempotent, so calling it from a UI tick,
    /// a wake notification, and a launch restore cannot double-fire completion.
    public func tick() {
        advance(to: clock.now)
    }

    public func handleWake() {
        advance(to: clock.now)
    }

    private func advance(to now: Date) {
        guard let current = active else { return }
        guard now >= current.deadline else { return }

        switch current.phase {
        case .focus:
            finishFocus(current, now: now)
        case .shortBreak, .longBreak:
            finishBreak(current)
        }
    }

    private func finishFocus(_ current: PersistedTimerState, now: Date) {
        // Sleep across the deadline must not inflate the record: cap at planned.
        let measured = min(
            current.plannedSeconds,
            max(0, Int(now.timeIntervalSince(current.startedAt).rounded()))
        )
        completedFocusCount += 1
        state = .focusCompletionPending
        active = nil
        persistence.save(nil)

        let nextBreak = preferences.preferences.breakPhase(afterCompletedFocusCount: completedFocusCount)
        state = .breakPrompt(next: nextBreak)

        emitOnce(
            .focusFinished(
                sessionID: current.sessionID,
                task: current.task,
                elapsedSeconds: measured,
                plannedSeconds: current.plannedSeconds
            ),
            for: current.sessionID
        )
    }

    private func finishBreak(_ current: PersistedTimerState) {
        state = .idle
        active = nil
        persistence.save(nil)
        emitOnce(.breakFinished(sessionID: current.sessionID, phase: current.phase), for: current.sessionID)
    }

    private func emitOnce(_ event: TimerEvent, for sessionID: UUID) {
        guard !firedTerminalEvents.contains(sessionID) else { return }
        firedTerminalEvents.insert(sessionID)
        emit(event)
    }

    // MARK: - Abandon and complete

    /// The confirmation lives in the UI layer; reaching here means the user confirmed.
    @discardableResult
    public func confirmAbandon() -> UUID? {
        guard let current = active else { return nil }
        let elapsed = max(0, Int(clock.now.timeIntervalSince(current.startedAt).rounded()))
        state = .idle
        active = nil
        persistence.save(nil)
        emitOnce(
            .sessionAbandoned(
                sessionID: current.sessionID,
                task: current.task,
                elapsedSeconds: min(current.plannedSeconds, elapsed),
                plannedSeconds: current.plannedSeconds,
                phase: current.phase
            ),
            for: current.sessionID
        )
        return current.sessionID
    }

    /// "Complete task" ends the focus session early and asks the orchestrator to close
    /// the Todoist task. Only valid while focusing.
    @discardableResult
    public func completeTask() -> UUID? {
        guard let current = active, current.phase == .focus else { return nil }
        let elapsed = min(
            current.plannedSeconds,
            max(0, Int(clock.now.timeIntervalSince(current.startedAt).rounded()))
        )
        completedFocusCount += 1
        state = .idle
        active = nil
        persistence.save(nil)
        emitOnce(
            .taskCompletionRequested(
                sessionID: current.sessionID,
                task: current.task,
                elapsedSeconds: elapsed,
                plannedSeconds: current.plannedSeconds
            ),
            for: current.sessionID
        )
        return current.sessionID
    }

    // MARK: - Recovery

    /// Rebuilds state from the persisted deadline on launch. A deadline already in the
    /// past completes immediately; it is never silently extended (spec §4).
    public func restore() {
        guard let persisted = persistence.load() else { return }
        active = persisted
        selectedTask = persisted.phase == .focus ? persisted.task : selectedTask
        completedFocusCount = persisted.completedFocusCount
        switch persisted.phase {
        case .focus: state = .focusing
        case .shortBreak: state = .shortBreaking
        case .longBreak: state = .longBreaking
        }
        advance(to: clock.now)
    }

    // MARK: - Projection

    public func snapshot() -> TimerSnapshot {
        snapshot(now: clock.now)
    }

    public func snapshot(now: Date) -> TimerSnapshot {
        let nextBreak = preferences.preferences.breakPhase(afterCompletedFocusCount: completedFocusCount + (state.isFocusing ? 1 : 0))
        guard let current = active else {
            return TimerSnapshot(
                state: state,
                task: selectedTask,
                phase: nil,
                remainingSeconds: 0,
                elapsedSeconds: 0,
                plannedSeconds: 0,
                completedFocusCount: completedFocusCount,
                nextBreakPhase: {
                    if case .breakPrompt(let next) = state { return next }
                    return nextBreak
                }()
            )
        }

        let remaining = max(0, Int(current.deadline.timeIntervalSince(now).rounded(.up)))
        let elapsed = min(current.plannedSeconds, current.plannedSeconds - remaining)
        return TimerSnapshot(
            state: state,
            task: current.phase == .focus ? current.task : selectedTask,
            phase: current.phase,
            remainingSeconds: remaining,
            elapsedSeconds: max(0, elapsed),
            plannedSeconds: current.plannedSeconds,
            completedFocusCount: completedFocusCount,
            nextBreakPhase: nextBreak,
            sessionID: current.sessionID
        )
    }
}
