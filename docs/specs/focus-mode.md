# Focus mode — macOS Focus and Slack

Turning a session on should quiet the places the interruptions come from. Focus mode
does two things when a focus session starts, and undoes both when it ends:

- runs a Shortcuts shortcut that switches a macOS Focus on (and a second one to switch
  it off);
- snoozes Slack notifications for the length of the session and, optionally, sets the
  Slack profile status.

Both are off until configured. Nothing here can block or fail the timer.

## Pieces

| Type | File | Role |
| --- | --- | --- |
| `FocusPresenceContext` | `Services/FocusPresence.swift` | Task title, minutes left, and the session's end date |
| `PresenceChannel` | `Services/FocusPresence.swift` | One outward surface: `engage` / `release` |
| `PresenceCoordinator` | `Services/FocusPresence.swift` | Actor that fans a session out to every channel and collects failures |
| `PresenceServices` | `Services/FocusPresence.swift` | Bundle handed to `AppModel`: coordinator, Slack client, Slack Keychain entry, Shortcuts runner |
| `MacFocusChannel` | `Services/MacFocusChannel.swift` | Runs the user's two shortcuts |
| `ShortcutsCommandRunner` | `Services/MacFocusChannel.swift` | `/usr/bin/shortcuts run` / `list`, with a timeout |
| `SlackClient` | `Services/SlackClient.swift` | `dnd.setSnooze`, `dnd.endSnooze`, `users.profile.set`, `auth.test` |
| `SlackPresenceChannel` | `Services/SlackPresenceChannel.swift` | Snooze + status, driven by preferences |
| `FocusPresenceSettings` | `Services/AppPreferences.swift` | Persisted configuration, optional on the wire |

## Lifecycle

| Moment | Effect |
| --- | --- |
| `AppModel.startFocus()` | `engage` with the remaining minutes, rounded up, minimum 1 |
| Focus finished | `release` before the completion sound and overlay |
| Session stopped early | `release`, then the usual abandoned-time accounting |
| "Complete task" | `release` before Todoist is told |
| A break starts, or is skipped | `release` — a break is time away from the desk |
| `AppModel.shutdown()` | Best-effort `release`, so quitting mid-session does not leave Slack snoozed |

`PresenceCoordinator.release()` is idempotent and a no-op when nothing was engaged, so
the wake path, the finish path, and quitting can all call it.

## Failure handling

A channel that throws never propagates: the coordinator collects a `PresenceFailure`
per channel, keeps going, and `AppModel` turns the list into one warning banner
(`PresenceMessage.banner(for:)`). The timer is already running by then.

## macOS Focus

macOS exposes no public API for switching a Focus on. The sanctioned path is the
Shortcuts app: a shortcut whose action is **Set Focus** can be run headlessly with
`/usr/bin/shortcuts run "<name>"`. Focusdoro therefore asks for two shortcut names and
runs them; the picker is populated from `shortcuts list`, and a name saved earlier stays
selectable even when the CLI is unavailable.

A shortcut that blocks (a dialog, a prompt) is terminated after ten seconds so a session
start is never held up.

## Slack

Needs a **user** token (`xoxp-…`) with `dnd:write` and, for the status,
`users.profile:write`. The token is validated with `auth.test` and stored in its own
Keychain entry (`<bundle id>.slack`, account `slack-user-token`) — never in preferences,
logs, or exported history, exactly like the Todoist token. No `SlackError` message
interpolates it; `SlackClientTests` asserts that across every failure path.

Slack reports failures inside a `200` body (`{"ok": false, "error": "…"}`), so the client
inspects the payload as well as the status code. `snooze_not_active` on release is
treated as success: the state we wanted is the state we have. `429` and `5xx` are
retried with the shared `RetryPolicy` backoff; auth and scope errors are not.

The snooze carries its own expiry, so a crash mid-session self-heals when it lapses.
The status expiry is set to the session's end for the same reason.

`SlackStatusFormatter` renders the status text: `{task}` is replaced with the task
title, an empty title reads "a task", an empty template falls back to "Focusing", and
anything longer than Slack's 100-character limit is cut with an ellipsis.

## Preferences

`FocusPresenceSettings` is stored as an optional field on `AppPreferences`, so
preferences written before focus mode existed still decode and land on the all-off
default. Fields: `macFocusEnabled`, `startShortcutName`, `endShortcutName`,
`slackEnabled`, `slackStatusEnabled`, `slackStatusTemplate` (default
`"Focusing on {task}"`), `slackStatusEmoji` (default `":tomato:"`).

## Tests

`Tests/FocusdoroCoreTests/FocusPresenceTests.swift` — Slack transport and error mapping
(with a private stub `URLProtocol`, since the shared one is process-global), token
redaction, status formatting, per-channel behaviour, coordinator fan-out and
idempotence, the `AppModel` lifecycle hooks, connect/disconnect, and preference
backward compatibility.
