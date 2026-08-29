# Timer engine

## What it does

`TimerEngine` (`Sources/FocusdoroCore/Services/TimerEngine.swift`) is an `actor` implementing the Pomodoro state machine: idle → focusing → (deadline reached) → a break prompt → a break phase → idle again, plus abandon and early-complete exits from focusing. There is no pause.

Its state is `TimerState` (`Sources/FocusdoroCore/Models/TimerModels.swift`): `.idle`, `.focusing`, `.focusCompletionPending`, `.breakPrompt(next: TimerPhase)`, `.shortBreaking`, `.longBreaking`. `TimerPhase` is `.focus`/`.shortBreak`/`.longBreak`. The engine does not model "abandoned" or "completed" as states it sits in — those are terminal `TimerEvent`s the engine emits while transitioning straight back to `.idle`.

The engine holds no accumulating counter. Truth is a persisted absolute `deadline` (`PersistedTimerState`, saved via the injected `TimerStatePersisting`, normally `UserDefaultsTimerStateStore`). `tick()`, `handleWake()`, and `restore()` all call the same private `advance(to:)`, which compares `now` against `deadline` — so ticking twice, waking from sleep, and restoring after a relaunch can never double-advance or drift; a deadline already in the past on relaunch completes immediately rather than being silently extended.

`snapshot()` / `snapshot(now:)` is a pure projection from `active` + `state`, so any caller can poll at any cadence (the UI does, from `AppModel`) without the engine itself running a clock.

## Rules it upholds

- **Exactly-once terminal events.** `firedTerminalEvents: Set<UUID>` gates `emitOnce`, so a duplicate `tick()` racing a `handleWake()` cannot emit `.focusFinished`/`.breakFinished`/`.sessionAbandoned`/`.taskCompletionRequested` twice for the same session id.
- **Elapsed time is capped at planned time.** `finishFocus`, `confirmAbandon`, and `completeTask` all clamp measured elapsed seconds to `plannedSeconds` — sleeping past the deadline must not inflate the recorded duration.
- **No pause.** `requestPause()` unconditionally throws `TimerEngineError.pauseNotSupported`.
- **Task selection is locked while a phase is active.** `selectTask(_:)` is a no-op unless `state == .idle || state.activePhase == nil`, so a mid-focus task swap can't silently rewrite what the session records.
- **Long-break cadence.** `AppPreferences.breakPhase(afterCompletedFocusCount:)` returns `.longBreak` every `longBreakCadence`-th completed focus session (and only when count > 0), otherwise `.shortBreak`.
- **Restore reconstructs, never extends.** `restore()` reloads persisted state, re-derives `TimerState` from the persisted phase, and immediately calls `advance(to: clock.now)` so an already-expired deadline fires its terminal event on launch rather than waiting for the next tick.

## Key types / files

- `Sources/FocusdoroCore/Services/TimerEngine.swift` — the actor, `PersistedTimerState`, `TimerStatePersisting` protocol, `UserDefaultsTimerStateStore`, `InMemoryTimerStateStore`, `TimerEngineError`.
- `Sources/FocusdoroCore/Models/TimerModels.swift` — `TimerPhase`, `TimerState`, `TimerSnapshot`, `TimerEvent`, `SelectedTask`, `SessionStatus`, `CommentStatus`, `SessionRecord`, `TodaySummary`.
- `Sources/FocusdoroCore/Services/AppPreferences.swift` — `breakPhase(afterCompletedFocusCount:)`, `duration(for:)`.

## Edge cases

- Sleep across the deadline: `finishFocus`/`confirmAbandon`/`completeTask` all cap elapsed at `plannedSeconds`.
- A deadline already passed at launch: `restore()` calls `advance` immediately, so the terminal event fires on the very first tick after launch rather than requiring the UI to open first.
- Duplicate wake + tick racing the same expired deadline: blocked by `firedTerminalEvents`.
- `startFocus`/`startBreak` both guard `state.activePhase == nil`, so calling either while a phase is already active is a no-op (returns `nil`) instead of clobbering the running session.
- `skipBreak()` only acts from `.breakPrompt`; called from any other state it is a no-op.

## Test coverage

`Tests/FocusdoroCoreTests/TimerEngineTests.swift`, suite **"Timer engine"** — covers start/restore/tick/abandon/complete/skip transitions, elapsed-time capping, and exactly-once event emission. The tick/refresh cadence that `AppModel` layers on top of the engine (1 Hz active, 5 s idle, drift-corrected sleep) is covered separately by the **"Tick cadence"** suite — see `docs/specs/menu-bar-and-popover.md`.
