# Focusdoro — Testing Checklist and Verification Record

Recorded 2026-08-29 on macOS 26.6 (arm64), Apple Swift 6.3.3, Command Line Tools only
(no Xcode installed).

## Build and test commands

```bash
make build     # swift build (debug)
make test      # full unit suite (280 tests, 32 suites)
make release   # swift build -c release
make app       # ./Scripts/build-app.sh — assembles build/Focusdoro.app, ad-hoc signed
make run       # make app && open ./build/Focusdoro.app
make clean
```

`make test` is `swift test` plus explicit search/rpath flags for the swift-testing
framework, which lives outside the default search paths under Command Line Tools:

```
-Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks
-Xlinker -F -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks
-Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks
-Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib
```

A focused suite runs with `swift test --filter <name>` plus the same flags, e.g.
`swift test --filter "Timer engine" $(TEST_FLAGS)`.

### Deviation from the plan

The plan specified an Xcode app target and `xcodebuild test -scheme Focusdoro`. Xcode is
not installed on this machine (`xcodebuild` reports the active developer directory is
`/Library/Developer/CommandLineTools`), so the deliverable is a SwiftPM package plus
`Scripts/build-app.sh`, which produces the same `LSUIElement` app bundle an Xcode target
would have. Two consequences:

- Tests use **swift-testing** (`import Testing`) rather than XCTest, which is not
  available to Command Line Tools builds.
- The Core Data model is built programmatically in `SessionStore.makeModel(uniqueByID:)`
  rather than from an `.xcdatamodeld`, because compiling one needs `momc` from Xcode.
- Previews use `PreviewProvider` rather than the `#Preview` macro; the macro's compiler
  plugin ships with Xcode.

None of this changes app behavior, and the package converts to an Xcode target unchanged.

## Automated evidence

`make test` — **280 tests in 32 suites passed**.

| Suite | Covers |
| --- | --- |
| Timer engine | idle/start, one-second snapshots, zero deadline, no-pause invariant, abandon intent, break cadence, relaunch recovery, sleep/wake, exactly-once events |
| Todoist API v1 client | task and project decoding, cursor pagination, `204` close, `200` comment, `401`, `410` retired endpoint, `429` with `Retry-After`, `5xx`, retry policy bounds, no retry on `4xx` |
| Task filtering and search | today/overdue/upcoming/undated, all-day vs zoned due dates, time-zone boundaries, diacritic-insensitive search, whole-word-first ranking, title over label over description |
| Task sorting and filtering | due/priority/project/name sections, Inbox-first ordering, unknown-project fallback, project and priority and dated filters, filter summary, inverted Todoist priority mapping, preference round trip and backward compatibility |
| Session store | completed/abandoned/pending/failed records, duplicate session IDs, today summary at local calendar boundaries with completed and stopped time reported separately, recent sessions ordering |
| Null session store | the degraded fallback used when Core Data is unavailable is a harmless no-op on every method |
| Abandoned time accounting | a stopped session keeps its minutes locally, logs them to Todoist as a partial comment when enabled, posts nothing under a minute or with logging off, retries a failed partial comment with the recorded time, stays idempotent, and the banner names where the time went |
| Todoist sync | connection state seeded from the token store, validate-before-save on connect, rollback of a rejected token, blank-token rejection without a network call, disconnect clearing the cache, unauthorized mapping to a rejected token, project-failure tolerance, refresh cancellation race, search over an empty list, local removal |
| Tick cadence | one-second ticks whenever a countdown is visible, five seconds only when idle and hidden, and sleeps aligned to the next second boundary so menu-bar digits never skip |
| Completion orchestration | exact comment string, minute rounding, one comment per completion, idempotence, close+comment, close failure, comment retry |
| Keychain token storage | save/read/delete, overwrite, missing token, service isolation, token absent from encoded preferences |
| App preferences | 1500/300/900/4 defaults, cadence, zero-cadence guard, `UserDefaults` round trip |
| Global hot keys | binding serialization, duplicate bindings, missing-modifier rejection, registration-failure message mapping, Carbon modifier conversion |
| Notification policy | preference + authorization gate, sound independence, body copy, blank-title fallback, system sound availability |
| App model | routing, task selection surviving ticks, project loading and its failure fallback, persisted sort and filter, menu-bar title, stop-routes-to-confirmation, abandon keeping and logging the invested time, completion flow, retryable comment failure, disconnect keeps history, token never in preferences |
| View rendering | every popover state, route, error state, every sort order and an empty filter, a long list on a short screen, uniform settings row widths, the completion overlay, and an overflowing task title lay out in a real `NSHostingView` at the popover width |
| Settings round trip | a preference edited in the settings screen reaches the store and the next session, with no write when the value is unchanged |
| Slack client | snooze minute clamping, form and JSON bodies, bearer auth, `ok:false` inside a 200, missing-scope naming, `snooze_not_active` treated as success, `429` retry, no request without a token, and no failure path carrying the token |
| Slack status text | placeholder substitution, empty title and empty template fallbacks, truncation at Slack's 100-character limit |
| Focus presence channels | Slack off does nothing, no token reports itself, snooze plus status for the session's length, status opt-out, release lifting both, a failed snooze lift still clearing the status, macOS Focus running the chosen shortcuts and refusing to run unconfigured |
| Focus presence coordinator | a failing channel not stopping the others, release inert without a session, release idempotent, banner wording for one and for several failures |
| Focus mode in the app model | starting a session engages for its length, finishing/stopping/breaking release, Slack connect storing a validated token, a rejected token discarded without leaking it, disconnect clearing everything, shortcut names offered from Shortcuts |
| Focus mode preferences | preferences written before focus mode existed still decode to the all-off default, settings round trip, macOS Focus usable only with both shortcuts picked |
| App composition | one status item, no titled window, idempotent popover, accessory activation policy, popover sized to the screen before it is shown |
| Login item service | `SMAppService` status mapping, enable and disable writes, a no-op re-register, approval-pending reported as on, and an unbundled process reporting unavailable |
| Launch at login in the app model | status refreshed on start, the toggle writing through, an approval-pending machine getting an info banner, and a failed write getting a warning banner without losing the real status |
| Task highlight maths | arrow movement wrapping at both ends, entering an empty highlight from the edge the key points at, first/last jumps, an empty list, and a highlight dropped when the list no longer holds it |
| Keyboard picking | arrowing through sections and through search results, return starting the highlighted task, escape clearing search before the highlight, and a re-filtered list re-entering at the first row |
| Weekly aggregation | seven day buckets oldest first, local day boundaries, stopped time counted as invested but not as a completed session, non-focus kinds skipped, sessions outside the week ignored, per-project rollup with the newest name winning, unassigned tasks bucketed once, and empty weeks |
| Weekly chart | bar heights scaled against the peak, a minimum visible height for a non-zero day, all-zero weeks flat, and weekday initials in calendar order |
| Weekly summary from the store | the Core Data read filtered to this week's focus sessions, the project snapshot surviving a closed task, and the null store returning an empty summary |
| Weekly stats in the app model | history reload filling the week, a day boundary refreshing it, and the summary surviving a disconnect |

The two AppKit suites (**View rendering**, **App composition**) need a window server:
they are skipped when `CI` is set, when `FOCUSDORO_HEADLESS=1` is set, or when the
session is not on a console. GitHub's macOS runners report a session dictionary but have
no window server, and touching AppKit there trips an assertion inside `CGSConnectionByID`
that takes the whole test process down rather than failing one test.

Release build: `swift build -c release --product Focusdoro` completed; the bundle was
assembled and ad-hoc signed by `Scripts/build-app.sh`.

Resource check (Task 11): the bundled app was launched and left idle.

- Resident memory: **~49 MB**
- Child processes: **0** — no web view, no helper/backend process.

## Manual acceptance checklist

Automated coverage cannot exercise the AppKit shell end to end. Run these by hand after
`make run`, with a short focus duration set in Settings (e.g. 1 minute) where noted.

- [ ] **Fresh token.** First launch shows the connect screen. Paste a personal Todoist
      API token; it validates before being kept, and an invalid token shows a
      plain-language error with the token never echoed.
- [ ] **Task search.** Today and overdue tasks appear first; search matches tasks from
      any project, including ones with no due date.
- [ ] **Keyboard picker.** Opening the picker puts the caret in the search field. ↑/↓
      move the highlight (wrapping at both ends) and scroll it into view, ⏎ starts a
      focus on the highlighted task, and ⎋ clears the search text first, then the
      highlight.
- [ ] **Start focus.** Selecting a task and starting shows the countdown; the menu-bar
      title mirrors it.
- [ ] **Close popover.** Closing the popover leaves the timer running and the menu-bar
      countdown updating.
- [ ] **Shortcuts.** With another app focused, `⌥⌘F` opens/closes the popover and `⌥⌘T`
      starts/stops. Change both in Settings and re-verify; a shortcut already owned by
      another app must show the conflict message and leave the old binding in place.
- [ ] **No pause.** There is no pause control anywhere during focus.
- [ ] **Abandon confirmation.** `⌥⌘T` during focus opens the popover and asks for
      confirmation. Cancelling keeps the timer running with no lost time.
- [ ] **Stopped time is logged.** After confirming, the Todoist task carries one
      `(stopped early, …)` comment with the minutes actually spent, and today's total
      includes them. With "Log stopped sessions" off, no comment is posted and the
      minutes still show in local history.
- [ ] **macOS Focus.** With a "Set Focus" shortcut picked for start and end, starting a
      session turns the Focus on within a second or two, and finishing, stopping, or
      starting a break turns it off. Deleting the shortcut afterwards shows the
      "no longer exists" banner without disturbing the running timer.
- [ ] **Slack.** With a user token connected (`dnd:write`, `users.profile:write`),
      starting a session snoozes Slack for the session length and sets the status;
      ending the session lifts both. Quitting mid-session also lifts them. Revoking the
      token in Slack shows the reconnect banner, and the token never appears in it.
- [ ] **Timer completion.** Let a focus run out: sound plays, notification appears, and
      the overlay shows on the active display.
- [ ] **Overlay.** Overlay is centered, dismissable with the keyboard, and auto-starts
      the break after the countdown. Verify Start break and Skip break.
- [ ] **Break.** Break countdown runs; every fourth focus offers the long break.
- [ ] **Complete task.** Completing closes the Todoist task and posts exactly one comment.
- [ ] **Todoist comment.** The comment reads
      `Focusdoro: 25 min focused on this task (YYYY-MM-DD HH:MM).` with local time.
- [ ] **Offline retry.** Turn off networking, finish a focus: the session is saved
      locally with a warning banner and a retry action. Restore networking, retry, and
      confirm exactly one comment lands.
- [ ] **Relaunch recovery.** Quit mid-focus and relaunch: the countdown resumes from the
      persisted deadline, never extended.
- [ ] **Sleep/wake.** Sleep the Mac mid-focus. On wake, if the deadline passed, the
      session completes with elapsed time capped at the planned duration.
- [ ] **Menu-bar only.** No Dock icon, no app switcher entry, no dashboard window.
- [ ] **Notification denial.** Deny notification permission: the app still works, the
      sound and overlay still fire, and no repeated permission prompt appears.
- [ ] **Accessibility.** VoiceOver reads the timer, the primary action, and the overlay
      buttons. Reduce Motion suppresses the progress and overlay animation.
- [ ] **Increased text size.** At larger Display text sizes the popover stays legible
      with no clipped controls.
- [ ] **Multiple displays.** The overlay appears on the display holding the pointer.
- [ ] **Full-screen app.** With another app full-screen, the overlay still appears
      (`.canJoinAllSpaces`, `.fullScreenAuxiliary`); if it cannot, the notification is
      the fallback.
- [ ] **Launch at login.** Turning on "Launch at login" in Settings adds Focusdoro to
      System Settings › General › Login Items; turning it off removes it. Toggling it
      off in System Settings and reopening Settings shows the toggle off — the system
      is the only source of truth. On a managed Mac the toggle reports pending
      approval rather than silently failing.
- [ ] **This week.** The history screen shows seven bars oldest first, today included,
      with the busiest day accented and the project breakdown summing to the week's
      minutes. Finishing a focus updates it without reopening the popover, and a
      session run against a task in a project still shows that project after the task
      is closed in Todoist.
- [ ] **Token redaction.** With the app running, `log stream --predicate 'process ==
      "Focusdoro"'` shows no token. Check `~/Library/Logs/DiagnosticReports` after a
      forced crash: no token in the report.

## Known OS limitations

- **Notification centre needs a bundle identifier.** `UNUserNotificationCenter.current()`
  traps in a bare command-line binary, so `NotificationService.defaultCenter()` returns
  `nil` when `Bundle.main.bundleIdentifier` is `nil`. Run the app from
  `build/Focusdoro.app`, not from `.build/release/Focusdoro`; the sound and overlay still
  work in the unbundled case.
- **Keychain identity is tied to the signature.** The bundle is ad-hoc signed. Re-signing
  with a different identity makes macOS prompt once for access to the existing item.
- **Carbon hot keys are first-come.** `RegisterEventHotKey` fails if another app already
  owns the combination; macOS gives no way to discover the owner, so the error copy names
  the action and suggests choosing another shortcut.
- **Global shortcuts are unavailable while a secure input field is focused** (password
  fields, the login window). This is a system restriction with no workaround.
- **Overlay over full-screen apps.** A non-activating `NSPanel` can be suppressed while
  another app owns a full-screen space in some macOS releases; the notification is the
  designed fallback for that case.
- **In-memory Core Data stores reject uniqueness constraints,** so the model is built
  with constraints only for the SQLite store. Duplicate protection also runs as a
  fetch-before-insert in both paths, so behavior is identical.
- **Sleeping past a deadline** cannot be timed precisely: elapsed time is capped at the
  planned duration on wake, which is the spec's intended behavior, not a measurement.
