# Focusdoro — Testing Checklist and Verification Record

Recorded 2026-08-29 on macOS 26.6 (arm64), Apple Swift 6.3.3, Command Line Tools only
(no Xcode installed).

## Build and test commands

```bash
make build     # swift build (debug)
make test      # full unit suite (161 tests, 14 suites)
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

`make test` — **161 tests in 14 suites passed**.

| Suite | Covers |
| --- | --- |
| Timer engine | idle/start, one-second snapshots, zero deadline, no-pause invariant, abandon intent, break cadence, relaunch recovery, sleep/wake, exactly-once events |
| Todoist API v1 client | task and project decoding, cursor pagination, `204` close, `200` comment, `401`, `410` retired endpoint, `429` with `Retry-After`, `5xx`, retry policy bounds, no retry on `4xx` |
| Task filtering and search | today/overdue/upcoming/undated, all-day vs zoned due dates, time-zone boundaries, diacritic-insensitive search, whole-word-first ranking, title over label over description |
| Task sorting and filtering | due/priority/project/name sections, Inbox-first ordering, unknown-project fallback, project and priority and dated filters, filter summary, inverted Todoist priority mapping, preference round trip and backward compatibility |
| Session store | completed/abandoned/pending/failed records, duplicate session IDs, today summary at local calendar boundaries, recent sessions ordering |
| Completion orchestration | exact comment string, minute rounding, one comment per completion, idempotence, close+comment, close failure, comment retry |
| Keychain token storage | save/read/delete, overwrite, missing token, service isolation, token absent from encoded preferences |
| App preferences | 1500/300/900/4 defaults, cadence, zero-cadence guard, `UserDefaults` round trip |
| Global hot keys | binding serialization, duplicate bindings, missing-modifier rejection, registration-failure message mapping, Carbon modifier conversion |
| Notification policy | preference + authorization gate, sound independence, body copy, blank-title fallback, system sound availability |
| App model | routing, task selection surviving ticks, project loading and its failure fallback, persisted sort and filter, menu-bar title, stop-routes-to-confirmation, abandon posts nothing, completion flow, retryable comment failure, disconnect keeps history, token never in preferences |
| View rendering | every popover state, route, error state, every sort order and an empty filter, a long list on a short screen, the completion overlay, and an overflowing task title lay out in a real `NSHostingView` at the popover width |
| App composition | one status item, no titled window, idempotent popover, accessory activation policy, popover sized to the screen before it is shown |

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
- [ ] **Abandon posts nothing.** After confirming, check the Todoist task: no comment.
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
