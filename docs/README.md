# Focusdoro handoff

Greenfield native macOS Pomodoro app. Read these in order:

1. [Product and design spec](superpowers/specs/2026-08-29-focusdoro-design.md)
2. [Implementation plan](superpowers/plans/2026-08-29-focusdoro-implementation-plan.md)

Chosen UI direction: task-first macOS popover, inspired by the supplied Look2 screenshot's material language, but with original Focusdoro hierarchy, copy, and controls.

Implementation target: Swift/AppKit shell with SwiftUI views, local Core Data history, Keychain token storage, URLSession Todoist REST integration, native notifications/sound, and Carbon global hotkeys. Personal MVP; no OAuth or backend.
