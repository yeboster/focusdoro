# Focusdoro

[![CI](https://github.com/yeboster/focusdoro/actions/workflows/ci.yml/badge.svg)](https://github.com/yeboster/focusdoro/actions/workflows/ci.yml)

Menu-bar-only Pomodoro timer for macOS and Todoist. No Dock icon, dashboard window, or backend: one `NSStatusItem`, one anchored popover, and local Core Data history.

- 25 / 5 / 15-minute cycle by default, with configurable long-break cadence.
- Focus cannot pause. Stopping asks for confirmation and never closes task.
- Finished focus posts one measured-time comment to Todoist; stopped-session logging is configurable.
- Todoist API v1 only. Personal API token is validated then kept only in macOS Keychain—never preferences, history, or logs.
- macOS Focus mode runs user-selected Shortcuts when focus begins and ends. It never delays timer.
- Task picker is keyboard-first and supports due-date, priority, project, and search filtering.
- Local history provides daily and project summaries. Session project snapshots survive Todoist task changes.
- Timer uses persisted absolute deadline, so sleep and relaunch do not silently extend session.
- Left-click menu-bar icon opens popover. Right-click icon offers **Quit Focusdoro**.

## Requirements

macOS 14 or later and Swift 6 toolchain. Xcode is not required.

## Build, run, and install

```bash
make test    # run swift-testing suite
make build   # debug executable
make app     # build build/Focusdoro.app; ad-hoc signed for local use
make dmg     # create build/Focusdoro.dmg
make run     # build and launch local bundle
make install # replace /Applications/Focusdoro.app and relaunch it
```

`make install` quits Focusdoro, deletes `/Applications/Focusdoro.app`, replaces it with local build, then opens replacement. Todoist token, local history, and in-flight timer state live outside bundle, so replacement preserves them.

Run bundled app rather than raw binary: macOS notifications and Keychain item need bundle identifier. On first launch, paste personal Todoist API token from Todoist → Settings → Integrations → Developer.

Releases and CI artifacts: [GitHub Releases](https://github.com/yeboster/focusdoro/releases). Current builds are ad-hoc signed. Their structural signature and release digest checks help detect corruption, but do not prove Developer ID publisher identity. Gatekeeper/notarization and publisher-authenticated automatic updates are not available until Developer ID signing, notarization, and signer pinning ship.

## Privacy and updates

Completion notifications hide task names by default. Enable **Show task names in notifications** only if task-title exposure on lock screens, Notification Center, screen shares, and configured notification surfaces is acceptable.

Focusdoro checks GitHub for releases. **Install updates automatically** is off by default. If enabled, it stays enabled across relaunches and app replacement until switched off. Read [PRIVACY.md](PRIVACY.md) and [SECURITY.md](SECURITY.md) before enabling automatic updates.

## Layout

| Path | What it holds |
| --- | --- |
| `Sources/FocusdoroCore/Models` | Timer and Todoist value types |
| `Sources/FocusdoroCore/Services` | Timer engine, API client, Keychain, Core Data, completion, hot keys, notifications, updates |
| `Sources/FocusdoroCore/Views` | SwiftUI popover, task picker, settings, history, completion overlay |
| `Sources/FocusdoroCore/DesignSystem` | Theme tokens, surfaces, button styles |
| `Sources/Focusdoro` | `@main` executable installing AppKit delegate |
| `Tests/FocusdoroCoreTests` | swift-testing suites |

## Project docs

- [Security reporting](SECURITY.md)
- [Privacy](PRIVACY.md)
- [Contributing](CONTRIBUTING.md)
- [MIT License](LICENSE)
- [Current technical specs](docs/README.md)
- [Testing checklist](docs/testing-checklist.md)
- [Historical design and plans](docs/superpowers/)
