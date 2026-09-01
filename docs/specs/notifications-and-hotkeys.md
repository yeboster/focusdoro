# Notifications and hotkeys

## What it does

`NotificationService` posts local `UNUserNotificationCenter` notifications and plays a completion sound. It registers an **Install** action for update notifications. `GitHubUpdateService` checks public release metadata and can stage a replacement. `HotKeyService` registers global toggle-popover and start/stop shortcuts through Carbon.

## Rules

- **Bundle required.** Notification center is unavailable for bare command-line binary; run `make app`, `make run`, or installed app.
- **Authorization is lazy.** Focusdoro requests notification authorization once, only when notifications preference is enabled.
- **Task names are private by default.** Completion notifications use generic text unless user enables **Show task names in notifications**. Opt-in titles can appear on lock screens, Notification Center, screen shares, and configured notification surfaces.
- **Update discovery stays on.** Launch and periodic checks read public GitHub release metadata. One availability notification is posted for each remote commit.
- **Automatic installation is explicit and persistent.** **Install updates automatically** defaults off. Disabled mode never downloads or installs automatically; user can review/install update. Enabled mode may download, validate, stage, and relaunch on discovery. Setting persists through relaunch and app replacement until user disables it. Installer concurrency guard prevents duplicate staging.
- **Current release trust is limited.** Update path checks HTTPS, release digest, bundle identifier, embedded commit, and structural code signature. Current artifacts are ad-hoc signed: these checks detect corruption but do not authenticate Developer ID publisher. Developer ID signing, notarization, and signer pinning are required before publisher-authenticated updates can be claimed.
- **Update failures never affect timer state.**
- **Hotkeys have no third-party runtime dependency.** `HotKeyService` validates every binding before Carbon registration, rejects invalid/duplicate bindings, registers in deterministic order, and rolls back partial registration.
- **Secure fields suppress global hotkeys by macOS policy.**
- **Sound and notification gates are pure.** `NotificationPolicy` accepts preferences and authorization state, so copy and policy test without notification center.

## Key files

- `Sources/FocusdoroCore/Services/NotificationService.swift`
- `Sources/FocusdoroCore/Services/UpdateService.swift`
- `Sources/FocusdoroCore/Services/HotKeyService.swift`
- `Sources/FocusdoroCore/Services/AppPreferences.swift`
- `Sources/FocusdoroCore/AppLifecycleCoordinator.swift`

## Test coverage

- `Tests/FocusdoroCoreTests/HotKeyServiceTests.swift` — binding validation, Carbon formatting, notification preference/body policy.
- `Tests/FocusdoroCoreTests/NotificationPolicyTests.swift` — update notification category/action routing.
- `Tests/FocusdoroCoreTests/UpdateServiceTests.swift` — release parsing, tag/URL policy, digest verification, and safe error copy.
- `Tests/FocusdoroCoreTests/AppModelTests.swift` — update discovery, automatic-install preference persistence, and installer concurrency.
