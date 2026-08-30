# Open at login

Focusdoro is a menu-bar app people expect to already be running. The Settings screen
has one switch, "Open at login", under a new **General** section.

## Pieces

| Type | File | Role |
| --- | --- | --- |
| `LoginItemStatus` | `Services/LoginItemService.swift` | `enabled` / `disabled` / `requiresApproval` / `unavailable` |
| `LoginItemManaging` | `Services/LoginItemService.swift` | `status()` and `setEnabled(_:)`, so `AppModel` is testable |
| `LoginItemService` | `Services/LoginItemService.swift` | `SMAppService.mainApp` (macOS 13+) |
| `InMemoryLoginItemService` | `Services/LoginItemService.swift` | Test double; records every write |

## Why `SMAppService`, not a helper

The old route was a bundled `LoginItemHelper.app` plus `SMLoginItemSetEnabled`, which
needs a second target and cannot be revoked from System Settings. `SMAppService.mainApp`
registers the app itself, shows up in System Settings › General › Login Items, and can
be turned off there by the user.

## The status is read, never mirrored

There is deliberately **no** preference for this. The user can revoke the login item in
System Settings at any time, and a mirrored `Bool` in `AppPreferences` would then be
wrong with no way to notice. `AppModel.loginItemStatus` is refreshed from the system on
`start()` and again in `SettingsView.onAppear`.

## Failure handling

| Case | Behaviour |
| --- | --- |
| No bundle identifier (`swift run` binary, test process) | Status is `unavailable`, the switch is disabled, and toggling banners an explanation |
| macOS defers to the user | Status is `requiresApproval`, which reads as **on**; an info banner points at System Settings |
| Registration throws | Warning banner carrying the system's own message, and the status is re-read so the switch snaps back |
| Double toggle | `setEnabled` checks the current status first: registering an already-registered app throws otherwise |

## Tests

`Tests/FocusdoroCoreTests/LaunchAtLoginTests.swift` — unbundled process, approval
pending, refused registration, status re-read on `start()`, and the double's bookkeeping.
