# Focus mode — macOS Focus

Focus mode can run user-selected Shortcuts to switch a macOS Focus on when a focus session starts and off when it ends. It is off until configured. A shortcut failure never delays or changes timer state.

## Pieces

| Type | File | Role |
| --- | --- | --- |
| `FocusPresenceContext` | `Services/FocusPresence.swift` | Session context supplied to a channel |
| `PresenceChannel` | `Services/FocusPresence.swift` | One outward surface with `engage` and `release` |
| `PresenceCoordinator` | `Services/FocusPresence.swift` | Actor that runs channels and collects failures |
| `PresenceServices` | `Services/FocusPresence.swift` | Coordinator provided to `AppModel` |
| `MacFocusChannel` | `Services/MacFocusChannel.swift` | Runs selected start/end shortcuts |
| `ShortcutsCommandRunner` | `Services/MacFocusChannel.swift` | Runs `/usr/bin/shortcuts` with fixed arguments and timeout |
| `FocusPresenceSettings` | `Services/AppPreferences.swift` | Optional persisted macOS Focus configuration |

## Lifecycle

| Moment | Effect |
| --- | --- |
| `AppModel.startFocus()` | engages configured channel |
| Focus finished | releases Focus before completion UI |
| Session stopped or task completed | releases Focus before Todoist action |
| Break starts or is skipped | releases Focus |
| `AppModel.shutdown()` | best-effort release |

`PresenceCoordinator.release()` is idempotent. Wake, finish, and quit paths may call it safely.

## Failure handling

A channel failure becomes a warning banner through `PresenceMessage.banner(for:)`; it never propagates to timer state. The coordinator continues any remaining channels.

## Configuration

macOS has no public Focus-setting API. Create two Shortcuts containing **Set Focus**, then choose their names in Focusdoro Settings. Focusdoro runs `/usr/bin/shortcuts run <name>` without shell interpolation. Saved names remain selectable if shortcut listing is temporarily unavailable.

A shortcut that blocks is terminated after ten seconds so session start remains responsive. Focusdoro cannot inspect or constrain actions inside shortcut; selected shortcut runs with user's authority.

`FocusPresenceSettings` is optional in `AppPreferences`, so preferences created before Focus mode existed decode to all-off configuration. Current fields are `macFocusEnabled`, `startShortcutName`, and `endShortcutName`.

Older releases could store a separate legacy Slack Keychain item. Current Focusdoro has no Slack integration and performs one best-effort deletion migration without reading or transmitting legacy value.

## Tests

`Tests/FocusdoroCoreTests/FocusPresenceTests.swift` covers shortcut invocation, missing configuration, coordinator failure isolation and idempotence, app-model focus lifecycle, legacy credential cleanup, and preference compatibility.
