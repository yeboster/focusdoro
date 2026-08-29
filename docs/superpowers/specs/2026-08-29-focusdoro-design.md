# Focusdoro Product and Design Specification

**Status:** Approved direction for handoff

**Date:** 2026-08-29

**Scope:** Personal-use macOS menu-bar Pomodoro app integrated with Todoist.

## 1. Product goal

Focusdoro helps one person stay on one Todoist task for a deliberate focus interval, records every session locally, and writes the measured focus time back to the Todoist task as a comment.

Success means the app is fast to open, nearly invisible while working, difficult to accidentally pause, and trustworthy about elapsed time and Todoist state.

## 2. Decisions already made

- Native macOS application, written in Swift.
- Menu-bar-only application. No Dock icon and no normal dashboard window in MVP.
- Menu-bar popover shows active task, timer, actions, today totals, and recent sessions.
- Personal MVP authentication: user pastes a Todoist API token; store it in macOS Keychain. No OAuth or server.
- Task picker shows today and overdue tasks first, with search across all active tasks.
- Default cycle: 25-minute focus, 5-minute short break, 15-minute long break after every fourth focus session. Durations are configurable.
- When focus ends: play sound, post notification, show a centered pop-up on the active display, then auto-start the break after confirmation in that pop-up.
- Global shortcuts are configurable for opening/closing the popover and starting/stopping the timer.
- No pause during focus. User may abandon, but abandonment requires confirmation.
- “Complete task” closes the Todoist task remotely and ends the active session.
- History is local and visible in the popover: today stats plus recent sessions.
- Every non-abandoned focus session creates a Todoist task comment containing measured duration. This includes normal timer completion and an explicit “Complete task” action. Abandoned sessions create no comment.

## 2.1 Architecture options considered

1. **AppKit shell + SwiftUI content + native services (chosen):** `NSStatusItem`/`NSPopover` gives exact menu-bar anchoring, no-Dock behavior, active-display overlay control, and low idle overhead; SwiftUI keeps the popover maintainable and testable.
2. **Pure SwiftUI `MenuBarExtra`:** less shell code, but weaker control over popover sizing, anchoring, overlay behavior, and older macOS compatibility. Not chosen for this utility's precise interaction model.
3. **Electron/Tauri/web shell:** faster cross-platform UI iteration, but unnecessary runtime/process overhead and weaker native menu-bar/material integration. Rejected because this app is intentionally macOS-native and resource-light.

The chosen architecture has no backend and no third-party runtime dependency in MVP.

## 3. User flows

### First launch

1. App installs as a menu-bar item and does not appear in the Dock.
2. Popover explains that a Todoist personal API token is required.
3. User pastes token into a secure field and taps “Connect”.
4. App validates the token with a lightweight authenticated request.
5. On success, token is stored in Keychain and the task picker opens.
6. On failure, show a plain-language error; never log or echo the token.

### Select and start

1. User opens popover by menu-bar click or global open shortcut.
2. Task picker displays today/overdue active tasks, then searchable active tasks.
3. User selects one task.
4. User taps “Start focus”.
5. Timer enters `focusing`; menu-bar title shows remaining time and popover shows the selected Todoist task.

### Focus completion

1. Timer reaches zero using measured monotonic time, not UI tick count.
2. App persists the completed session locally.
3. App posts a Todoist comment with measured duration.
4. App plays the configured completion sound.
5. App shows a native notification and a centered overlay on the active display.
6. Overlay states that focus is complete, shows the next break length, and offers “Start break” and “Skip break”.
7. Break auto-starts after the overlay's short confirmation window; selecting “Skip break” returns to task selection.

### Complete task early

1. User taps “Complete task”.
2. App asks for confirmation because this changes Todoist state.
3. App closes the Todoist task with the REST API.
4. App measures elapsed focus time, persists a completed session, and posts the duration comment.
5. App stops the timer and returns to the task picker.
6. If Todoist close succeeds but comment posting fails, local session remains completed and the UI exposes “Retry comment”.

### Abandon

1. User taps “Abandon”.
2. Confirmation explains that no Todoist completion or time comment will be sent.
3. On confirmation, persist an abandoned session for local history/analytics, stop timer, and return to task picker.

## 4. Timer state machine

States:

- `idle`: no active cycle; task may be selected.
- `focusing`: active task and focus deadline exist; pause is unavailable.
- `focusCompletionPending`: focus deadline reached; completion side effects are being persisted/sent.
- `breakPrompt`: overlay is visible after focus completion.
- `shortBreaking`: short break countdown active.
- `longBreaking`: long break countdown active.
- `abandoned`: terminal record state, then return to `idle`.
- `completed`: terminal record state, then return to `breakPrompt` or `idle`.

Timer source of truth is a monotonic clock deadline persisted with the session. UI refreshes once per second while visible and at a lower cadence while only the menu-bar title is visible. App relaunch reconstructs remaining time from the deadline. A deadline in the past completes immediately and is never silently extended.

## 5. macOS UI and visual language

Chosen structure is task-first. The popover should feel like a native macOS utility, not a web card:

- `NSStatusItem` menu-bar shell with a custom anchored popover.
- Dark translucent material, blue-black upper tint, graphite lower tint.
- Rounded outer popover around 28–30pt radius; subtle blue-gray border; layered shadow and inner highlight.
- Small centered notch aligned to the menu-bar item.
- SF Pro / system font; tabular numerals for timer.
- 8pt spacing grid; 42px minimum action height; 10–13px corner radii for controls.
- One blue primary action (`Complete task`); neutral secondary `Abandon`.
- Todoist task row has icon, title, metadata, and chevron. Long text truncates cleanly.
- Timer is largest element after task identity. Progress bar is thin, high contrast, and blue.
- Next-break row is informational, not another competing primary action.
- Stats row uses three compact columns: today minutes, sessions, streak.
- No gradients as decorative backgrounds beyond subtle material shading; no copied Look2 assets or branding.
- Light mode may be added later; MVP is dark material only, respecting macOS contrast settings.

Popover content order:

1. Focusdoro wordmark and settings menu.
2. `CURRENT TODOIST TASK` label and task row.
3. Focus phase label and large `MM:SS` timer.
4. Progress bar and elapsed-time hint.
5. `Abandon` and `Complete task` buttons.
6. Next break row.
7. Today/session/streak stats.
8. Recent sessions and shortcuts/settings links.

## 6. Data model

Use Core Data for local durable history. Use `UserDefaults` only for non-sensitive preferences. Use Keychain for the Todoist token.

### `FocusSession`

- `id: UUID`
- `taskID: String`
- `taskTitleSnapshot: String`
- `startedAt: Date`
- `endedAt: Date?`
- `plannedDurationSeconds: Int32`
- `elapsedDurationSeconds: Int32`
- `kind: String` (`focus`, `shortBreak`, `longBreak`)
- `status: String` (`completed`, `abandoned`, `interrupted`, `failed`)
- `todoistCommentStatus: String` (`notApplicable`, `pending`, `posted`, `failed`)
- `todoistCommentID: String?`
- `createdAt: Date`

### `AppPreferences`

Store in `UserDefaults`:

- focus duration, default 1500 seconds
- short break duration, default 300 seconds
- long break duration, default 900 seconds
- long-break cadence, default 4 focus sessions
- sound enabled and sound identifier
- notification enabled
- global shortcut key combinations
- last selected task ID (non-authoritative convenience only)

Never store the API token in `UserDefaults`, Core Data, logs, crash reports, or exported history.

## 7. Todoist integration contract

Use `URLSession` with `Authorization: Bearer <token>` against the Todoist REST v2 API.

- List active tasks: `GET https://api.todoist.com/rest/v2/tasks`
- Complete task: `POST https://api.todoist.com/rest/v2/tasks/{task_id}/close`, expect `204 No Content`.
- Add task comment: `POST https://api.todoist.com/rest/v2/comments` with JSON `{ "task_id": "...", "content": "..." }`, expect `200 OK` and comment object.

Task filtering is client-side for MVP: derive today and overdue groups from each task's `due.date` in the user's local calendar/time zone, while retaining every active task for search.

Comment format:

`Focusdoro: 25 min focused on this task (2026-08-29 14:30).`

Use the measured elapsed duration rounded to the nearest minute, minimum 1 minute for any non-zero session. Include local date/time for human auditability. Keep comment content plain and deterministic.

All requests have cancellation, a bounded timeout, and typed errors. Retry only transient transport/5xx failures with bounded exponential backoff. Never retry authentication failures or validation failures automatically. Include an idempotency guard locally so reconnect/retry cannot post duplicate comments for one session.

## 8. Notifications, sound, and overlay

- Request notification authorization on first action that needs it, with a clear explanation.
- Use `UNUserNotificationCenter` for a local notification containing task title and focus/break transition.
- Play a short bundled system-style sound through `NSSound`; respect the sound preference and macOS mute state.
- Overlay is a borderless, centered `NSPanel` on the active display. It must be above normal windows, non-activating where possible, keyboard dismissible, and accessible through VoiceOver.
- Overlay must not steal focus while the user is in a full-screen app unless macOS policy allows it; notification remains fallback.

## 9. Shortcuts

Register two global hotkeys using Carbon/HIToolbox `RegisterEventHotKey`, avoiding third-party runtime dependencies:

- Open/close popover.
- Start/stop current timer. “Stop” means abandon flow and always opens confirmation; it never silently discards a session.

Expose recording/editing in settings. Detect conflicts and show a recoverable error instead of claiming a shortcut that did not register.

## 10. Reliability and edge cases

- App termination or sleep: recover from persisted deadline on relaunch; do not count sleep time as focused work unless the deadline elapsed while asleep, in which case complete at wake and use measured wall-clock duration capped at planned duration.
- Network unavailable: timer and local history continue. Queue comment/close operations with explicit pending/failed status; never block timer completion on Todoist.
- Token invalid/revoked: mark integration disconnected, keep local history, preserve selected task snapshot, and ask for a new token.
- Task deleted/completed elsewhere: refresh on action, show conflict, and do not duplicate close/comment blindly.
- Duplicate callback/event: session IDs make persistence and Todoist comment posting idempotent.
- Accessibility: Dynamic Type where practical, VoiceOver labels, keyboard navigation, sufficient contrast, and Reduce Motion support.
- Resource target: idle memory under 50 MB in a normal run; no polling loop faster than once per second; no always-running web view; no backend process.

## 11. Acceptance criteria

1. App launches as menu-bar-only and uses no Dock icon.
2. Token is accepted, validated, and stored only in Keychain.
3. Today/overdue and all-active task search work with a valid token.
4. Selecting a task and starting focus updates menu-bar title and popover every second.
5. Pause is impossible during focus; abandon always confirms.
6. Timer survives popover close, app relaunch, and Mac sleep/wake without extending deadline.
7. Focus completion persists local session, plays sound, sends notification, shows overlay, and transitions to break.
8. “Complete task” closes Todoist task, persists measured duration, and posts exactly one comment.
9. Abandon persists local abandoned record and posts no Todoist comment.
10. Today totals and recent sessions reflect local records without a network round trip.
11. Global shortcuts can be configured, registered, and conflict-reported.
12. Tests cover timer transitions, duration measurement, task filtering, Keychain behavior, Todoist response mapping, retry policy, and duplicate-comment protection.

## 12. Explicit MVP exclusions

- Todoist OAuth/public multi-user distribution.
- Backend, cloud sync, or cross-device history.
- Smart pausing during calls/movies.
- Automatic task selection or automatic video/content generation.
- Project-level analytics dashboard.
- Dock window, menu-bar charts, or full-screen history browser.
- Google Trends, third-party trend providers, or unrelated integrations.

## 13. Reference

Todoist REST v2 endpoint behavior verified against the official reference: <https://developer.todoist.com/rest/v2/>.
