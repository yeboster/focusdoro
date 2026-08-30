# Focusdoro

[![CI](https://github.com/yeboster/focusdoro/actions/workflows/ci.yml/badge.svg)](https://github.com/yeboster/focusdoro/actions/workflows/ci.yml)

Menu-bar-only Pomodoro timer for macOS, wired to Todoist. No Dock icon, no dashboard
window, no backend: one `NSStatusItem`, one anchored popover, and a local Core Data
history.

- 25 / 5 / 15-minute cycle by default, long break every 4th focus, all configurable.
- Focus cannot be paused. Stopping asks for confirmation and never closes the task.
- Every finished focus posts exactly one Todoist comment:
  `Focusdoro: 25 min focused on this task (2026-08-29 14:30).`
- Time already invested still counts: a stopped session keeps its minutes in the local
  history, feeds today's total, and posts them as
  `Focusdoro: 12 min focused on this task (stopped early, 2026-08-29 14:30).`
  Turn that off with "Log stopped sessions" in Settings.
- Focus mode quiets the interruptions for the length of a session: it runs your own
  Shortcuts shortcut to switch a macOS Focus on, and snoozes Slack notifications while
  setting your Slack status ("Focusing on {task}"). Both are optional, both are lifted
  when the session ends or a break starts, and neither can hold up the timer.
- The Todoist token — and the Slack user token, if you connect one — lives only in the
  macOS Keychain — never in `UserDefaults`, Core Data, logs, or exported
  history.
- The task picker groups by due date, priority, or project, filters by project,
  minimum priority, and "has a date", and ranks search so whole-word matches lead.
- The task picker is keyboard-first: the caret starts in the search field, ↑/↓ move the
  highlight, ⏎ starts a focus on it, and ⎋ clears the search before the highlight.
- History shows this week at a glance: seven daily bars, the busiest day accented, and
  the minutes broken down by project. Every session snapshots its project, so the
  breakdown survives a task being closed or moved.
- Focusdoro can start itself at login (`SMAppService`, no helper app); System Settings
  stays the single source of truth for that switch.
- Timer truth is a persisted absolute deadline, so it survives relaunch and sleep and is
  never silently extended.

## Requirements

macOS 14 or later, Swift 6 toolchain. Xcode is not required.

## Build and run

```bash
make app     # assembles build/Focusdoro.app (ad-hoc signed)
make run     # builds and launches it
make test    # 202 unit tests
```

CI (`.github/workflows/ci.yml`) runs the same `make test` on `macos-15`, then assembles
and verifies `build/Focusdoro.app` and uploads it as a build artifact.

Launch the bundle rather than the raw binary: notification support needs a bundle
identifier.

On first launch, paste a personal Todoist API token
(Todoist → Settings → Integrations → Developer). It is validated once, then stored in
the Keychain.

Default shortcuts: `⌥⌘F` opens/closes the popover, `⌥⌘T` starts/stops the timer. Both are
editable in Settings.

## Layout

| Path | What it holds |
| --- | --- |
| `Sources/FocusdoroCore/Models` | Timer and Todoist value types |
| `Sources/FocusdoroCore/Services` | Timer engine, Todoist client, Keychain, Core Data store, completion orchestration, hot keys, notifications |
| `Sources/FocusdoroCore/Views` | SwiftUI popover, task picker, settings, history, completion overlay |
| `Sources/FocusdoroCore/DesignSystem` | Theme tokens, surfaces, button styles |
| `Sources/Focusdoro` | `@main` executable that installs the AppKit delegate |
| `Tests/FocusdoroCoreTests` | swift-testing suites |

## Docs

- [Product and design spec](docs/superpowers/specs/2026-08-29-focusdoro-design.md)
- [As-built specs](docs/specs/) — one file per feature: [focus mode](docs/specs/focus-mode.md), [launch at login](docs/specs/launch-at-login.md), [keyboard picker](docs/specs/keyboard-picker.md), [weekly stats](docs/specs/weekly-stats.md)
- [Implementation plan](docs/superpowers/plans/2026-08-29-focusdoro-implementation-plan.md)
- [Testing checklist and verification record](docs/testing-checklist.md)
