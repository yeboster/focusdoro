# Per-session focus length

The ready screen sizes the next session to the task in front of you. ± controls flank the
countdown, stepping the length in 5-minute jumps between 1 and 180 minutes. It is a
one-off: the default configured in Settings is never touched, so shortening a session to
beat the clock on one task does not quietly reshape every session after it.

## Pieces

| Type | File | Role |
| --- | --- | --- |
| `AppModel.customFocusSeconds` | `Services/AppModel.swift` | The override itself. Stored, so `@Observable` tracks it; `nil` means "use the default" |
| `AppModel.plannedFocusSeconds` / `plannedFocusMinutes` | `Services/AppModel.swift` | What the next session will run for: override, else `preferences.focusDurationSeconds` |
| `AppModel.adjustPlannedFocus(byMinutes:)` / `setPlannedFocus(minutes:)` / `resetPlannedFocus()` | `Services/AppModel.swift` | The intents behind ±, and the reset link |
| `AppModel.focusLengthBounds` / `focusLengthStepMinutes` | `Services/AppModel.swift` | `1...180`, step 5 |
| `StepButtonStyle` | `DesignSystem/FocusdoroStyle.swift` | The circular ± control |
| `TimerView.timerSection` | `Views/TimerView.swift` | Renders ± in `.idle` only, and the "Reset to 25 min" link while an override stands |

## Behavior

- **Ready only.** `adjustPlannedFocus` and `setPlannedFocus` no-op while a phase is
  active, and the ± controls are not rendered outside `.idle`. Timer truth is the
  absolute deadline written at start, which is never extended (spec §4) — a stepper that
  worked mid-session would be lying about that.
- **Stepping back onto the default drops the override**, so the screen stops advertising
  a custom length the user has effectively undone.
- **Clamped at both ends.** The low bound is 1 minute, matching what Settings already
  allows, so a one-minute smoke test still works.
- **Cleared when the session ends** — finished, stopped, or task-completed — and when a
  *different* task is picked. Re-picking the same task keeps the length, since the
  picker is also how you get back to the timer screen.
- **The session records its own length.** `SessionRecord.plannedDurationSeconds` comes
  from the running session, not from today's default. That required carrying
  `plannedSeconds` on `TimerEvent.sessionAbandoned`, which previously fell back to
  `preferences.focusDurationSeconds` and would have mis-recorded every custom-length
  session that was stopped early.

## What it does not do

- No preset chips and no free text entry: two buttons and a reset link cover sizing a
  session without turning the ready screen into a form.
- Break lengths are untouched. A break runs on its configured length regardless of how
  long the focus before it was.
- Nothing is sent to Todoist differently: the comment still reports measured minutes.

## Tests

`SessionLengthTests.swift` — suite **Session length adjustment**: the default with no
override, stepping leaving preferences alone, clamping at both ends, stepping back onto
the default clearing the override, reset, the chosen length being what the session
actually runs for, the stepper ignored once running, switching tasks resetting it,
re-picking the same task keeping it, and a finished and a stopped session each recorded
against their own planned length.
