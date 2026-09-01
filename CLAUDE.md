# Focusdoro

Focusdoro is a macOS menu-bar Pomodoro timer that drives its task list from Todoist: pick a Todoist task, run a focus/break cycle against it, and on completion Focusdoro posts a "minutes focused" comment to the task (and optionally closes it), while every session is also recorded locally so history and streaks work with no network round trip. It is a personal, single-user SwiftPM app — no Xcode project, no backend, no OAuth.

## Build, test, run

This machine has Command Line Tools only, not full Xcode. That has one hard consequence: **`swift build --build-tests` and `swift test` fail** with `no such module 'Testing'`, because the swift-testing framework only ships inside the CLT's bundled frameworks directory, which the plain SwiftPM invocation never sees.

- `make test` — the only working way to run tests. Injects `-F`/`-rpath` flags (see `Makefile`) pointing at `/Library/Developer/CommandLineTools/Library/Developer/{Frameworks,usr/lib}` so the linker finds `Testing.framework`. Currently green.
- `make build` / `make release` — plain `swift build` (debug / `-c release`); no test flags needed since the app target doesn't import Testing.
- `make app` — runs `Scripts/build-app.sh`: builds the release binary, assembles `build/Focusdoro.app` (an `LSUIElement` bundle, id `so.bon.focusdoro`, min macOS 14) with a generated `Info.plist`, and ad-hoc codesigns it (`codesign --force --deep --sign -`). A bundle identifier and signature are required for both `UNUserNotificationCenter` and the Keychain item to work — a bare `swift run` binary has neither.
- `make install` — `make app`, then quits the running Focusdoro, replaces `/Applications/Focusdoro.app`, and relaunches it. **Do this at the end of any build meant to be used, not just tested**: `/Applications` holds the copy the login item and the menu bar actually launch, so a build left in `build/` changes nothing the user sees. Nothing user-owned lives inside the bundle (token in the Keychain, history in Core Data, in-flight deadline in `UserDefaults`), so the swap is safe and the running session is restored on relaunch.
- `make run` — `make app` then `open build/Focusdoro.app`. Throwaway: it runs the build in place and leaves `/Applications` stale.
- `make clean` — removes `.build` and `build`.

If you invoke `swift test` directly instead of through `make`, you must pass the same `-Xswiftc -F ... -Xlinker -F ... -Xlinker -rpath ...` flags yourself or it won't compile.

## Architecture

AppKit shell → `AppModel` → actors, with SwiftUI only for the popover's content.

- `Sources/Focusdoro/FocusdoroApp.swift` — `@main`, installs `AppLifecycleCoordinator` as the `NSApplicationDelegate` and runs `NSApplication`.
- `Sources/FocusdoroCore/AppLifecycleCoordinator.swift` — composition root. Builds the dependency graph (`SessionStore`, `TodoistClient`, `TodoistSync`, `TimerEngine`, `CompletionOrchestrator`, `NotificationService`), owns `MenuBarController`, `CompletionOverlayController`, `HotKeyService`, sets `.accessory` activation policy (no Dock icon), observes sleep/wake and day-change notifications. If Core Data fails to load it falls back to an in-memory store, then `NullSessionStore`, and surfaces a banner rather than crashing.
- `Sources/FocusdoroCore/AppMainMenu.swift` — minimal `NSMenu` installed before the first popover opens, purely so standard key equivalents (⌘V/⌘C in the token field) have something to route through.
- `Sources/FocusdoroCore/MenuBarController.swift` — `NSStatusItem` + one `NSPopover`, ticks the status-item title from `AppModel.menuBarTitle`.
- `Sources/FocusdoroCore/Services/AppModel.swift` — `@MainActor @Observable` class every view binds to. Owns routing (`PopoverRoute`), the tick loop, and dispatches `TimerEngine`'s `AsyncStream<TimerEvent>` into orchestrator calls, banners, and the completion overlay. Views never touch the network or Core Data directly.
- `Sources/FocusdoroCore/Services/TimerEngine.swift` (`actor`) — Pomodoro state machine. Truth is an absolute persisted `deadline`, not accumulated ticks, so a relaunch or sleep reconstructs remaining time exactly and `tick()`/`handleWake()`/`restore()` are all idempotent through the same `advance(to:)` path.
- `Sources/FocusdoroCore/Services/CompletionOrchestrator.swift` (`actor`) — writes the local session first, then does Todoist side effects (close task, post comment), so a network failure never loses measured focus time.
- `Sources/FocusdoroCore/Services/TodoistSync.swift` / `TodoistClient.swift` — `TodoistSync` is the `@Observable` in-memory task/project cache and connection state; `TodoistClient` is the `URLSession`-based Todoist API v1 client.
- `Sources/FocusdoroCore/Services/FocusPresence.swift` + `MacFocusChannel.swift` — macOS Focus mode. A starting session is sent through `PresenceCoordinator` (actor) to `MacFocusChannel`, which runs `/usr/bin/shortcuts run <name>` because no public API can set a Focus. Failures become one warning banner and never touch timer. See `docs/specs/focus-mode.md`.
- `Sources/FocusdoroCore/Services/WeeklyStats.swift` — pure aggregation for the week view: buckets focus sessions into seven `DayTotal`s (invested time counts stopped sessions, the session count does not), rolls them up into `ProjectTotal`s from each session's project snapshot, and computes bar heights. No Core Data, no AppKit — `SessionStore.weeklySummary(now:calendar:)` does the fetch and hands the rows here. See `docs/specs/weekly-stats.md`.
- `Sources/FocusdoroCore/Services/TaskHighlight.swift` — the picker's keyboard maths, kept pure so it is testable without a view: `next(_:in:from:)` wraps at both ends and enters an empty highlight from the edge the key points at. `AppModel.moveHighlight/activateHighlighted` drive it. See `docs/specs/keyboard-picker.md`.
- `Sources/FocusdoroCore/Services/LoginItemService.swift` — `SMAppService.mainApp` behind `LoginItemManaging`. The system is the only source of truth: there is no mirrored preference, because the user can turn the login item off in System Settings and nothing would tell us. See `docs/specs/launch-at-login.md`.
- Storage: `SessionStore.swift` (Core Data, programmatic `NSManagedObjectModel`), `UserDefaultsPreferencesStore`/`UserDefaultsTimerStateStore` (preferences and in-flight timer state), `KeychainStore.swift` (Todoist token only — Keychain only).
- Views under `Sources/FocusdoroCore/Views/`: `PopoverView` composes `ConnectView` / `TaskPickerView` / `TimerView`+`HistoryView` / `SettingsView` / `HistoryView` by `AppModel.route`; `CompletionOverlayView` is the full-screen-adjacent completion panel driven by `CompletionOverlayController`.
- `Sources/FocusdoroCore/DesignSystem/FocusdoroStyle.swift` — `Theme` enum: `Space`/`Radius`/`Metric`/`Palette`/`Font` namespaces, dark-material-only.

## Conventions

- Tests use swift-testing (`import Testing`, `@Suite`, `@Test`, `#expect`), not XCTest — XCTest isn't available under CLT-only. All targets set `swiftSettings: [.swiftLanguageMode(.v5)]` in `Package.swift` (tools-version 6.0).
- `@Observable`/`@Bindable` (Swift Observation) only track **stored** properties. `AppModel.preferences` is therefore a stored property with a `didSet` that writes through to `PreferencesStoring` — a computed forwarding property would silently break UI refresh for whoever wrote it.
- SwiftUI previews use `PreviewProvider` (`Views/Previews.swift`, 14 `_Previews: PreviewProvider` structs), not the `#Preview` macro — the macro's compiler plugin needs Xcode.
- Comments explain *why*, not *what* — many carry a `spec §N` reference back to `docs/superpowers/specs/2026-08-29-focusdoro-design.md`.
- Every persistence/notification/token dependency is behind a protocol (`TimerStatePersisting`, `PreferencesStoring`, `TokenStoring`, `SessionStoring`, `NotificationPresenting`, `TodoistAPI`) with an in-memory test double, so services and `AppModel` are constructible with no OS resources in tests.

## Hard rules

- The Todoist API token lives **only** in the Keychain (`KeychainStore`, `kSecClassGenericPassword` scoped to the bundle id). Never in `UserDefaults`, Core Data, logs, crash reports, or exported history, and never echoed back in an error message — `TodoistClient`'s transport-error path explicitly uses `(error as NSError).localizedDescription`, not the raw request, to avoid leaking the `Authorization` header.
- Todoist **API v1 only** (`https://api.todoist.com/api/v1`). REST v2 (`/rest/v2`) is retired and answers everything with `410 Gone`; the client surfaces that as `TodoistError.endpointRetired` with its own user-facing message ("this build is calling a retired API"), kept distinct from a generic outage.
- The wire priority is inverted: Todoist's wire value `4` is the user-facing **P1** (`TaskPriority: p4=1, p3=2, p2=3, p1=4`, `label` computes `"P\(5 - rawValue)"`).

## Gotchas worth knowing

- `AppPreferences` decodes with the synthesized `Codable`, which calls `decodeIfPresent` for every `Optional` stored property. New preference fields (`taskSortOrderID`, `taskFilterCriteria`, `logsAbandonedTimeFlag`, `focusPresenceSettings`) are declared optional specifically so preferences JSON written by an older build keeps decoding after a new field is added.
- The same optional-means-compatible trick carries the project snapshot: `SelectedTask.projectID/projectName` and `SessionRecord.projectID/projectNameSnapshot` are optional so a timer state persisted by an older build still decodes and pre-snapshot history rows still load. On the Core Data side that made `SessionStore.modelVersion = 2` — the two new attributes are optional, which is exactly what lightweight inferred migration (`shouldMigrateStoreAutomatically` + `shouldInferMappingModelAutomatically`) can handle with no mapping model.
- `AppPreferences.bindings` is `[HotKeyAction: HotKeyBinding]`. `Dictionary` keyed by a non-`String`/`Int` type (an enum, even a `String`-backed one) encodes as a flat JSON **array** of alternating keys and values, not an object — expected, not a bug, if you go looking at the raw preferences data.
- Popover sizing: `NSHostingController.sizingOptions = [.preferredContentSize]` (`MenuBarController.configurePopover`) plus computing and setting `popover.contentSize` in `sizePopover(for:)` **before** `popover.show(...)` is required. Skip either step and the popover keeps its 320×320 default at show time, grows from its fixed bottom-left origin only after showing, and a long task list pushes the top off the screen.
- `ScrollView` has no intrinsic height. `SettingsView` and `TaskPickerView` both set `.frame(minHeight:maxHeight:)` from a computed `listCap` derived from the popover's available height (`Theme.Metric.listMinHeight`/`listMaxHeight` clamped against `popoverMaxHeight - pickerChromeHeight`) — a bare `ScrollView` with no cap either collapses to zero or grows unbounded.
- There is no pause. `TimerEngine.requestPause()` always throws `TimerEngineError.pauseNotSupported`; stopping early always routes through the abandon confirmation (`AppModel.requestStartStop`), never a silent discard.
- Session ids are the idempotency key throughout: `TimerEngine.firedTerminalEvents: Set<UUID>` guarantees each terminal event fires once, `CompletionOrchestrator` checks `todoistCommentStatus == .posted` before re-posting, and `SessionStore`'s Core Data entity has a store-level uniqueness constraint on `id` (SQLite only — `NSInMemoryStoreType` rejects uniqueness constraints, so `SessionStore.makeModel(uniqueByID:)` drops it for in-memory/test stores and relies on the fetch-before-insert guard instead).
