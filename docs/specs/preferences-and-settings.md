# Preferences and settings

## What it does

`AppPreferences` (`Sources/FocusdoroCore/Services/AppPreferences.swift`) is the single non-sensitive settings struct: durations, long-break cadence, sound/notification toggles, hotkey bindings, task sort/filter, last-selected task, break auto-start delay, and whether abandoned time gets logged to Todoist. It is persisted as JSON in `UserDefaults` via `UserDefaultsPreferencesStore`. `SettingsView` (`Sources/FocusdoroCore/Views/SettingsView.swift`) is the editor.

## Rules it upholds

- **The Todoist token is never in here.** `AppPreferences` has no token field; the token lives only in `KeychainStore` (see `docs/specs/security.md`).
- **Backward-compatible decoding via optional fields.** `taskSortOrderID`, `taskFilterCriteria`, and `logsAbandonedTimeFlag` are all `Optional` on the struct specifically so the synthesized `Codable` (which calls `decodeIfPresent` for every optional stored property) can decode JSON written by an older Focusdoro build that predates the field. Each exposes a non-optional computed accessor with a default: `taskSortOrder` defaults to `.dueDate`, `taskFilter` defaults to `.none`, `logsAbandonedTime` defaults to `true` ("time already invested is real time"). Setting `taskFilter` to an inactive criteria (`!newValue.isActive`) writes `nil` back, so a default install's JSON stays minimal.
- **`bindings: [HotKeyAction: HotKeyBinding]` encodes as a JSON array, not an object** — `Dictionary` with a non-`String`/`Int` key type (an enum, even `String`-backed) isn't special-cased by `JSONEncoder`, so it serializes as `[key1, value1, key2, value2, ...]`. This is expected; nothing depends on the preferences JSON being human-editable as a keyed object.
- **`AppModel.preferences` is a stored property, not computed.** `@Observable` only tracks stored properties; `AppModel` stores its own `AppPreferences` copy and write-throughs to `preferencesStore` in a `didSet` (only when the value actually changed), rather than forwarding reads/writes straight to the store — a computed forward would mean a control writing a new value never triggers its own re-render.
- **Shortcut edits are validated as a whole set before being applied.** `SettingsView.apply(_:to:)` builds the candidate `bindings` dictionary and calls `HotKeyService.validate(bindings)` — checking every binding has at least one modifier and no two actions share a keycode+modifier combination — before writing to `AppModel.preferences`, so a bad second binding can't leave a half-applied set. See `docs/specs/notifications-and-hotkeys.md` for `HotKeyService` itself.
- **Duration steppers work in whole minutes but store seconds.** `SettingsView.stepper` divides/multiplies by 60 at the UI boundary; `AppPreferences` itself always stores `Int` seconds (`focusDurationSeconds`, etc.).
- **Long break cadence**: `AppPreferences.breakPhase(afterCompletedFocusCount:)` returns `.longBreak` only when `count % longBreakCadence == 0 && count > 0`, so a cadence of e.g. 4 means every 4th completed focus session, not the 0th.

## Key types / files

- `Sources/FocusdoroCore/Services/AppPreferences.swift` — `AppPreferences`, `.default`, `HotKeyBinding`, `HotKeyAction`, `PreferencesStoring`, `UserDefaultsPreferencesStore`, `InMemoryPreferencesStore`.
- `Sources/FocusdoroCore/Views/SettingsView.swift` — sectioned editor (Durations / Alerts / Global shortcuts / Todoist account), `ShortcutRecorder` (an `NSViewRepresentable` `NSButton` subclass that captures a `keyDown` while "recording").
- `Sources/FocusdoroCore/Services/AppModel.swift` — `preferences` stored property and its `didSet` write-through; `taskSortOrder`/`taskFilter` computed properties that write through to both `TodoistSync` (live) and `AppPreferences` (persisted).

## Edge cases

- A settings JSON blob from a build before `breakAutoStartDelaySeconds` existed: that field is **not** optional on the struct (it has always shipped with a value in `.default`), so this only matters for the three explicitly-optional fields above — anything else missing from an old blob fails the whole decode and `UserDefaultsPreferencesStore.load` falls back to `.default`.
- Recording a shortcut with no modifier key (e.g. bare `F`): `HotKeyBinding.isValid` is `false`, and `HotKeyService.validate` throws `.invalidBinding` before the binding is ever handed to Carbon.
- Two actions recorded to the identical keycode+modifier pair: `HotKeyService.validate` throws `.duplicateBinding(first, second)`, surfaced as `shortcutError` under the shortcuts list rather than silently overwriting the first binding.
- `SettingsView`'s `ScrollView` has no intrinsic height, so it's capped with both `minHeight` and `maxHeight` via a `listCap` derived from `popoverMaxHeight` (see the `CLAUDE.md` gotcha).

## Test coverage

- `Tests/FocusdoroCoreTests/KeychainStoreTests.swift`, suite **"App preferences"** — encode/decode round trip, `decodeIfPresent` backward compatibility, default values.
- `Tests/FocusdoroCoreTests/AppModelTests.swift`, suite **"Settings round trip"** — `AppModel.preferences` write-through and persistence via `PreferencesStoring`.
