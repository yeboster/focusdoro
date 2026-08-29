# Menu bar and popover

## What it does

The AppKit shell that hosts the SwiftUI popover, and `AppModel`, the single `@MainActor @Observable` class every view binds to. `AppLifecycleCoordinator` is the composition root (builds every service, wires them together, sets `.accessory` activation policy so there's no Dock icon or app-switcher entry). `MenuBarController` owns the `NSStatusItem` and one `NSPopover`. `AppModel` owns routing (`PopoverRoute`), the tick loop that drives the countdown display, and translates `TimerEngine`'s event stream into orchestrator calls, banners, and the completion overlay.

## Rules it upholds

- **Views never touch the network or Core Data directly.** Every view (`PopoverView`, `TaskPickerView`, `TimerView`, `SettingsView`, `HistoryView`, `ConnectView`) reads/writes only through `AppModel` (`@Bindable var model: AppModel`) or `AppModel.sync` (`TodoistSync`, itself `@Observable`).
- **Popover sizing must happen before `show`.** `MenuBarController.configurePopover()` sets `hosting.sizingOptions = [.preferredContentSize]`; `openPopover()` calls `sizePopover(for:)` — which lays out the hosted SwiftUI tree and sets `popover.contentSize` — **before** `popover.show(...)`. Skipping the pre-size step leaves the popover at its 320×320 default at show time; because an `NSPopover` grows from a fixed bottom-left origin, growing afterward pushes the top of a long list off the top of the screen. `availableHeight(for:)` computes the tallest the popover may be for the anchor's screen (`visibleFrame.height` minus the anchor gap and a margin), passed down through `PopoverRoot`/`PopoverView`'s `popoverMaxHeight` environment value so `SettingsView`/`TaskPickerView` can size their `ScrollView`s against it.
- **Open/close are idempotent.** `togglePopover()`/`openPopover()`/`closePopover()` all check `popover.isShown` first, so a double hotkey press or a click while it's already open never produces a second popover or a redundant close.
- **The status item title only updates on change.** `MenuBarController.updateTitle` early-returns if `button.title` already equals the new text — re-setting an identical `NSStatusItem` title relays out the whole item, visible as a flicker next to other menu-bar icons.
- **Tick cadence adapts to visibility, and drift-corrects.** `AppModel.startTicking()` ticks at 1 Hz whenever a phase is active or the popover is visible, 5 s otherwise (`tickInterval(isActive:popoverIsVisible:)`); `tickDelay(after:interval:)` sleeps to just past the next whole second (not a flat interval) so per-tick processing time can't accumulate drift that eventually skips a displayed second.
- **Route follows timer state, but only on the actual transition.** `refreshSnapshot()` moves to `.timer` whenever a phase becomes active while on `.tasks`, and back to `.tasks` only on the transition *out* of a running session into idle (`!wasIdle && next.state == .idle`) — checking `state == .idle` alone would bounce the user back to the picker one tick after selecting a task, since selecting a task leaves the engine idle until `startFocus` is called.
- **The completion overlay is presented by the AppKit layer, not owned by `AppModel`.** `AppModel.presentCompletionOverlay`/`dismissCompletionOverlay` are closures set by `AppLifecycleCoordinator`, keeping `AppModel` free of any `NSWindow`/`NSPanel` ownership.
- **`⌘V` requires an installed main menu even though there's no Dock icon.** `AppMainMenu.install()` runs before the first popover opens (`AppLifecycleCoordinator.applicationDidFinishLaunching`) — without a standard Edit menu, the token paste field has no key equivalent to route `⌘V` through, since an `.accessory` app has no menu bar of its own by default.
- **Design tokens, not ad hoc styling.** `FocusdoroStyle.swift`'s `Theme` enum groups `Space`/`Radius`/`Metric`/`Palette`/`Font` constants; the popover forces `.environment(\.colorScheme, .dark)` — the UI is dark-material-only, no light-mode variant.

## Key types / files

- `Sources/FocusdoroCore/Services/AppModel.swift` — `AppModel`, `PopoverRoute`, `PendingConfirmation`, `BannerMessage`, `FocusCompletionSummary`, ticking (`startTicking`, `tickInterval`, `tickDelay`), event dispatch (`handle(_: TimerEvent)`).
- `Sources/FocusdoroCore/AppLifecycleCoordinator.swift` — composition root, `NullSessionStore`.
- `Sources/FocusdoroCore/MenuBarController.swift` — `NSStatusItem`/`NSPopover` management, `sizePopover(for:)`, `availableHeight(for:)`.
- `Sources/FocusdoroCore/AppMainMenu.swift` — minimal `NSMenu` install.
- `Sources/FocusdoroCore/Views/PopoverView.swift` — route switch, header, footer, `ConfirmationDialogs` (abandon / complete-task / disconnect, each a `confirmationDialog`), `popoverMaxHeight` environment key.
- `Sources/FocusdoroCore/Views/TimerView.swift`, `Sources/FocusdoroCore/Views/ConnectView.swift` — phase/timer/actions rendering, token-entry flow.
- `Sources/FocusdoroCore/DesignSystem/FocusdoroStyle.swift` — `Theme` design tokens (`popoverWidth = 460`, `listMinHeight = 340`, `listMaxHeight = 520`, `pickerChromeHeight = 250`, `popoverFallbackHeight = 700`, `settingsRowHeight = 38`, `settingsValueWidth = 72`).
- `Sources/FocusdoroCore/Views/Previews.swift` — 14 `PreviewProvider` structs (not `#Preview` macro; see `CLAUDE.md`).

## Edge cases

- Stop while a phase is active always opens the abandon confirmation (`requestStartStop`); it never silently discards.
- "Complete task" and "abandon" and "disconnect" are three separate `confirmationDialog`s gated on `AppModel.confirmation`, presented one at a time — a destructive change to state the user can't easily undo always confirms first.
- `Core Data` load failure at launch still lets `menuBar.start()` and the timer run; only the history-dependent banner/UI degrades (see `docs/specs/completion-and-history.md`).
- A Carbon hotkey another app already owns fails registration (`HotKeyError.registrationFailed`), surfaced as a warning banner rather than crashing or silently doing nothing (see `docs/specs/notifications-and-hotkeys.md`).

## Test coverage

- `Tests/FocusdoroCoreTests/AppModelTests.swift`, suites **"Tick cadence"**, **"App model"**, **"App composition"** — tick interval/delay math, event-to-banner/route logic, dependency wiring.
- `Tests/FocusdoroCoreTests/ViewRenderingTests.swift`, suite **"View rendering"** — SwiftUI view construction against `AppModel.preview(...)` fixtures (`Sources/FocusdoroCore/Views/PreviewFixtures.swift`) doesn't crash/traps across states.
