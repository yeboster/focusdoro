# Notifications and hotkeys

## What it does

Three OS-integration services. `NotificationService` (`Sources/FocusdoroCore/Services/NotificationService.swift`) posts local `UNUserNotificationCenter` notifications and plays a completion sound (`NSSound`) when a focus or break phase ends. It also registers an **Install** action for update notifications. `GitHubUpdateService` discovers and verifies immutable continuous releases, then stages a safe replacement. `HotKeyService` (`Sources/FocusdoroCore/Services/HotKeyService.swift`) registers global keyboard shortcuts via Carbon (`RegisterEventHotKey`/`InstallEventHandler`) so the toggle-popover and start/stop actions work even when Focusdoro doesn't have focus.

## Rules it upholds

- **Carbon, not a third-party hotkey package.** Chosen specifically to keep the app's runtime dependency footprint at zero (no Sparkle-adjacent or HotKey-package dependency) — it's the only global-hotkey mechanism available without one.
- **The whole binding set is validated before any registration touches Carbon.** `HotKeyService.validate(bindings)` checks every binding has `isValid` (at least one modifier) and that no two actions share the same keycode+modifier pair, throwing `.invalidBinding`/`.duplicateBinding` before `register(bindings:)` calls `RegisterEventHotKey` for anything — so a bad second binding can't leave the first one half-registered. `register` also calls `validate` itself as its first step, and rolls back (`unregisterAll()`) if any individual `RegisterEventHotKey` call fails partway through.
- **Deterministic registration order.** Bindings are registered sorted by `action.rawValue`, so a registration failure names a stable, reproducible action rather than depending on dictionary iteration order.
- **Hotkey handlers always land on the main thread.** Carbon's dispatcher already runs on the main run loop, but `HotKeyService.handle(id:)` still hops through `DispatchQueue.main.async` to make that a hard guarantee rather than an assumption.
- **First registrant wins.** This is an OS-level Carbon limitation, not something the app can override: if another running app has already registered the same keycode+modifier combination, Focusdoro's `RegisterEventHotKey` call fails and the user sees `HotKeyError.registrationFailed`'s message ("another app may already own it").
- **A hotkey can't reach a secure input field.** Also an OS-level restriction: while a secure text field (e.g. a password field in another app) has focus system-wide, Carbon global hotkeys are suppressed by the OS. Not something Focusdoro's code works around.
- **Notifications require a bundle identifier.** `NotificationService.defaultCenter()` returns `nil` (rather than calling `UNUserNotificationCenter.current()`, which traps) when `Bundle.main.bundleIdentifier == nil` — true for a bare `swift run` binary, false for the signed `build/Focusdoro.app` bundle produced by `make app`. Every notification-posting path checks for a non-nil `center` first.
- **Authorization is requested once, lazily, only if notifications are enabled.** `requestAuthorizationIfNeeded()` guards on `didRequest`; `AppLifecycleCoordinator` only calls it after `model.start()` and only if `model.preferences.notificationsEnabled`.
- **Update installs are opt-in and verified.** Launch and six-hour checks read public GitHub release metadata. One notification is posted per remote commit. Clicking **Install** downloads `Focusdoro.dmg`, checks GitHub's immutable SHA-256 asset digest, mounts read-only, verifies bundle id + embedded commit + strict code signature, stages a copy, then quits. A detached helper replaces `/Applications/Focusdoro.app`, rolls back on failure, and relaunches. Update errors never affect timer state.
- **Continuous releases are immutable.** CI publishes `continuous-<40-character SHA>` with one `Focusdoro.dmg` after every green `main` push. Built app embeds same SHA as `FocusdoroBuildCommit`.
- **Sound and notification gating is centralized and pure.** `NotificationPolicy.shouldNotify(preferences:authorized:)` / `shouldPlaySound(preferences:)` are free functions taking `AppPreferences` + authorization state, tested without any `UNUserNotificationCenter` involved.
- **The completion sound is a named system sound, not a bundled asset.** `NSSound(named:)` — no binary payload shipped, and it automatically honors the system's output device and mute state.

## Key types / files

- `Sources/FocusdoroCore/Services/NotificationService.swift` — `NotificationPresenting` protocol, `NotificationService`, `NotificationPolicy`.
- `Sources/FocusdoroCore/Services/UpdateService.swift` — GitHub release parser/policy, SHA-256 verifier, discovery client, DMG installer, rollback helper.
- `Sources/FocusdoroCore/Services/HotKeyService.swift` — `HotKeyRegistering` protocol, `HotKeyService`, `HotKeyError`, `HotKeyFormatter` (Carbon modifier mask ↔ display string, e.g. `⌥⌘F`).
- `Sources/FocusdoroCore/Services/AppPreferences.swift` — `HotKeyAction`, `HotKeyBinding` (the persisted binding data; see `docs/specs/preferences-and-settings.md`).
- `Sources/FocusdoroCore/AppLifecycleCoordinator.swift` — wires `hotKeys.onTogglePopover`/`onStartStop`, re-registers on `.focusdoroHotKeysChanged` (posted by `SettingsView` after a successful edit).

## Edge cases

- Registering a shortcut that's already taken by *another Focusdoro action* is caught by `validate`'s duplicate check before Carbon is even asked; taken by a *different app* is only detectable by Carbon's registration call itself failing.
- macOS full-screen spaces owned by another app can prevent the (unrelated) completion overlay panel from appearing even though it isn't a hotkey issue — see `docs/specs/completion-and-history.md`; the completion notification is the fallback path in that case, tying notifications and the overlay together operationally.
- Default bindings (`⌥⌘F` toggle, `⌥⌘T` start/stop) are defined in `AppPreferences.default`; both use `modifiers: 2048 | 256` (`cmdKey | optionKey`).

## Test coverage

- `Tests/FocusdoroCoreTests/HotKeyServiceTests.swift`, suite **"Global hot keys"** — validation (invalid/duplicate bindings), `HotKeyFormatter` display strings and Carbon modifier conversion.
- `Tests/FocusdoroCoreTests/NotificationPolicyTests.swift` — update category/action routing.
- `Tests/FocusdoroCoreTests/UpdateServiceTests.swift` — release/tag/URL validation, dedupe, digest verification, fixed safe error copy.
