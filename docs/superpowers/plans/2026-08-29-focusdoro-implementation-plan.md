# Focusdoro Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a low-resource native macOS menu-bar Pomodoro app that binds focus sessions to Todoist tasks and records measured time back as task comments.

**Architecture:** Use an AppKit `NSStatusItem` and anchored popover as the lifecycle shell, hosting SwiftUI views for task selection, timer, history, and settings. Keep timer state in a testable actor/service backed by persisted deadlines; keep Core Data history local, Keychain credentials secure, and Todoist communication in an isolated async `URLSession` client.

**Tech Stack:** Swift 5.9+, SwiftUI, AppKit, Core Data, Security/Keychain, UserNotifications, NSSound, Carbon/HIToolbox hotkeys, URLSession async/await, XCTest, Xcode macOS app target.

**Spec:** `docs/superpowers/specs/2026-08-29-focusdoro-design.md`

## Global Constraints

- Menu-bar-only; no Dock icon and no normal dashboard window in MVP.
- Personal API-token authentication; token stored only in Keychain.
- Todoist REST v2: tasks `GET /rest/v2/tasks`, close `POST /tasks/{id}/close`, comment `POST /rest/v2/comments`.
- Default cycle is focus 1500s, short break 300s, long break 900s after four focus sessions.
- No focus pause; abandon requires confirmation.
- Every non-abandoned focus session posts one deterministic duration comment; abandoned sessions post none.
- Timer truth is a persisted monotonic-compatible deadline; UI ticks are presentation only.
- No third-party runtime dependencies unless a later decision documents why native APIs cannot meet the requirement.
- All network operations are cancellable, time-bounded, and redacted in logs.

## File map

- Create `Focusdoro/FocusdoroApp.swift`: app entry, lifecycle, menu-bar-only policy.
- Create `Focusdoro/MenuBarController.swift`: `NSStatusItem`, popover anchoring, open/close behavior.
- Create `Focusdoro/Views/PopoverView.swift`: task-first popover composition.
- Create `Focusdoro/Views/TaskPickerView.swift`: today/overdue/search task selection.
- Create `Focusdoro/Views/TimerView.swift`: phase, timer, progress, actions, break row.
- Create `Focusdoro/Views/HistoryView.swift`: today totals and recent sessions.
- Create `Focusdoro/Views/SettingsView.swift`: durations, sound/notification, shortcuts, token reset.
- Create `Focusdoro/DesignSystem/FocusdoroStyle.swift`: colors, materials, radii, spacing, button styles.
- Create `Focusdoro/Services/TimerEngine.swift`: actor-owned state machine and deadline calculations.
- Create `Focusdoro/Services/SessionStore.swift`: Core Data stack and session queries.
- Create `Focusdoro/Services/KeychainStore.swift`: token read/write/delete.
- Create `Focusdoro/Services/TodoistClient.swift`: REST v2 request/response mapping.
- Create `Focusdoro/Services/TodoistSync.swift`: task cache, filtering, close/comment orchestration.
- Create `Focusdoro/Services/NotificationService.swift`: authorization, notification, sound, overlay trigger.
- Create `Focusdoro/Services/HotKeyService.swift`: Carbon registration and conflict reporting.
- Create `Focusdoro/Models/FocusSession+CoreDataClass.swift` and `Focusdoro/Models/FocusSession+CoreDataProperties.swift`.
- Create `Focusdoro/Models/TimerModels.swift`: phases, states, task DTOs, typed errors.
- Create `FocusdoroTests/TimerEngineTests.swift`.
- Create `FocusdoroTests/TodoistClientTests.swift`.
- Create `FocusdoroTests/SessionStoreTests.swift`.
- Create `FocusdoroTests/KeychainStoreTests.swift`.
- Create `FocusdoroTests/TaskFilteringTests.swift`.
- Create `FocusdoroTests/HotKeyServiceTests.swift`.

## Task 1: Scaffold native menu-bar app

**Files:** Create the app target and `Focusdoro/FocusdoroApp.swift`, `Focusdoro/MenuBarController.swift`; add `FocusdoroTests/SmokeTests.swift`.

**Interfaces:** `MenuBarController.start()`, `MenuBarController.togglePopover()`, `MenuBarController.closePopover()`.

- [ ] Create macOS app target with App Sandbox and network client entitlement; set application policy to accessory so no Dock icon appears.
- [ ] Instantiate one `NSStatusItem` and one anchored `NSPopover`; make repeated open/close calls idempotent.
- [ ] Add smoke test that app composition creates one controller and no dashboard window.
- [ ] Run `xcodebuild test -scheme Focusdoro -destination 'platform=macOS'` and record baseline.

## Task 2: Add secure preferences and Keychain token flow

**Files:** Create `KeychainStore.swift`, `SettingsView.swift`, `TimerModels.swift`; test `KeychainStoreTests.swift`.

**Interfaces:** `KeychainStore.saveToken(_:)`, `KeychainStore.readToken() throws -> String?`, `KeychainStore.deleteToken()`; `AppPreferences` Codable wrapper over `UserDefaults`.

- [ ] Write failing tests for save/read/delete and missing-token behavior using a test service key.
- [ ] Implement Keychain operations with `kSecClassGenericPassword`, service scoped to bundle identifier, no token logging.
- [ ] Implement preferences with exact defaults 1500/300/900/4 and shortcut/sound/notification fields.
- [ ] Build first-launch settings state: secure token field, connect action, reset-token action, validation error state.
- [ ] Run `xcodebuild test -scheme Focusdoro -only-testing:FocusdoroTests/KeychainStoreTests`.

## Task 3: Implement Todoist REST v2 client

**Files:** Create `TodoistClient.swift`, `Models/TimerModels.swift`; test `TodoistClientTests.swift` with `URLProtocol`.

**Interfaces:** `TodoistClient.listTasks() async throws -> [TodoistTask]`; `TodoistClient.closeTask(id:) async throws`; `TodoistClient.addComment(taskID:content:) async throws -> TodoistComment`.

- [ ] Write URLProtocol tests for task decoding, `204` close response, `200` comment response, `401`, `429`, and `5xx`.
- [ ] Implement one injected `URLSession`, bearer authorization, request IDs, 15-second timeout, and JSON decoding for REST v2 task/comment shapes.
- [ ] Map errors into `TodoistError.unauthorized`, `.rateLimited(retryAfter:)`, `.transport`, `.server`, `.invalidResponse`.
- [ ] Implement retry policy only for transport/5xx with bounded exponential backoff; never auto-retry 401/4xx.
- [ ] Run `xcodebuild test -scheme Focusdoro -only-testing:FocusdoroTests/TodoistClientTests`.

## Task 4: Build task cache and today/overdue filtering

**Files:** Create `TodoistSync.swift`, `Views/TaskPickerView.swift`; test `TaskFilteringTests.swift`.

**Interfaces:** `TaskFilter.group(tasks:now:calendar:) -> TaskGroups`; `TodoistSync.refresh() async`; `TodoistSync.search(_:) -> [TodoistTask]`.

- [ ] Write tests for today tasks, overdue tasks, undated tasks, recurring due dates, local time-zone boundaries, and search across all active tasks.
- [ ] Implement client-side grouping from `due.date`; keep every active task in in-memory cache for search.
- [ ] Add loading, empty, unauthorized, offline, and retry states to task picker.
- [ ] Ensure selecting task stores only ID/title snapshot in app state; it never treats cached task data as authoritative for completion.
- [ ] Run `xcodebuild test -scheme Focusdoro -only-testing:FocusdoroTests/TaskFilteringTests`.

## Task 5: Implement deadline-based timer engine

**Files:** Create `TimerEngine.swift`, `TimerModels.swift`; test `TimerEngineTests.swift`.

**Interfaces:** `TimerEngine.startFocus(task:duration:) async`; `TimerEngine.requestAbandon() async`; `TimerEngine.completeTask() async`; `TimerEngine.snapshot(now:) -> TimerSnapshot`; `TimerEngine.handleWake(now:) async`.

- [ ] Write failing tests for idle/start, one-second snapshots, zero deadline, no-pause invariant, abandon confirmation intent, break cadence, relaunch recovery, and sleep/wake.
- [ ] Implement actor-isolated state with persisted absolute deadline and injected clock for deterministic tests.
- [ ] Make focus timer immutable against pause; stop/start shortcut routes to abandon confirmation rather than pausing.
- [ ] Emit typed events `focusFinished`, `breakFinished`, `sessionAbandoned`, `taskCompletionRequested` exactly once per session ID.
- [ ] Run `xcodebuild test -scheme Focusdoro -only-testing:FocusdoroTests/TimerEngineTests`.

## Task 6: Add Core Data session history

**Files:** Create Core Data model and `SessionStore.swift`, `FocusSession` generated classes; test `SessionStoreTests.swift`.

**Interfaces:** `SessionStore.insertSession(_:)`; `SessionStore.markCommentStatus(sessionID:status:commentID:)`; `SessionStore.todaySummary(now:calendar:) -> TodaySummary`; `SessionStore.recentSessions(limit:) -> [FocusSession]`.

- [ ] Write in-memory-store tests for completed, abandoned, pending, failed, and duplicate session IDs.
- [ ] Define attributes exactly as the spec's `FocusSession` model; enforce unique ID at the store boundary.
- [ ] Implement today summary using local calendar boundaries and recent-session query sorted by `endedAt` descending.
- [ ] Add migration version 1 and ensure store load failure produces a recoverable user-facing error.
- [ ] Run `xcodebuild test -scheme Focusdoro -only-testing:FocusdoroTests/SessionStoreTests`.

## Task 7: Orchestrate completion, close, and exactly-once comments

**Files:** Modify `TimerEngine.swift`, `TodoistSync.swift`, `SessionStore.swift`; add orchestration tests to `TodoistClientTests.swift` or a new `CompletionOrchestratorTests.swift`.

**Interfaces:** `CompletionOrchestrator.finishFocus(sessionID:reason:) async`; `CompletionOrchestrator.completeTodoistTask(sessionID:) async`.

- [ ] Write tests proving timer completion posts one comment, explicit Complete task closes task and posts one comment, abandon posts none, and duplicate event does not duplicate comment.
- [ ] Format comment exactly as `Focusdoro: {rounded minutes} min focused on this task ({local timestamp}).`.
- [ ] Persist session before network calls; mark comment `pending`, then `posted` or `failed`.
- [ ] On close success/comment failure, preserve completed local session and expose retry; do not reverse Todoist completion.
- [ ] Run focused orchestration tests and full unit suite.

## Task 8: Implement polished task-first popover

**Files:** Create `PopoverView.swift`, `TimerView.swift`, `TaskPickerView.swift`, `HistoryView.swift`, `FocusdoroStyle.swift`; connect to `MenuBarController`.

**Interfaces:** Views consume `Observable` view models backed by `TimerEngine`, `TodoistSync`, and `SessionStore`; no view performs raw network or Core Data operations.

- [ ] Build the approved order: wordmark/settings, current task, phase/timer, progress, Abandon/Complete task, next break, stats, recent/shortcuts.
- [ ] Implement dark macOS material, 28–30pt popover radius, notch, system typography, tabular timer, 8pt spacing, 42px controls, one blue primary action.
- [ ] Add task picker navigation and search while preserving selected-task identity.
- [ ] Add confirmation dialogs for abandon and Todoist completion; disable duplicate taps while operation is pending.
- [ ] Add SwiftUI previews for idle, focusing, completion pending, break, offline, and no-task states.
- [ ] Run app manually and verify screenshot at normal and increased text sizes.

## Task 9: Add notification, sound, and completion overlay

**Files:** Create `NotificationService.swift`, `CompletionOverlayController.swift`; test pure notification preference logic.

**Interfaces:** `NotificationService.requestAuthorizationIfNeeded() async`; `NotificationService.notifyFocusComplete(taskTitle:)`; `CompletionOverlayController.present(result:)`.

- [ ] Implement first-use notification authorization and preference toggle.
- [ ] Bundle one short completion sound and play through `NSSound` only when enabled.
- [ ] Implement borderless centered active-display `NSPanel` with keyboard dismissal, Start break, Skip break, VoiceOver labels, and Reduce Motion behavior.
- [ ] Keep notification as fallback when overlay cannot be shown or app is not active.
- [ ] Verify overlay on multiple displays and full-screen app; document observed OS limitations.

## Task 10: Register configurable global shortcuts

**Files:** Create `HotKeyService.swift`, modify `SettingsView.swift`; test `HotKeyServiceTests.swift`.

**Interfaces:** `HotKeyService.register(bindings:) throws`; `HotKeyService.unregisterAll()`; `HotKeyService.onOpenToggle`; `HotKeyService.onStartStop`.

- [ ] Write tests for serialization, duplicate bindings, invalid binding, and registration failure mapping.
- [ ] Implement Carbon `RegisterEventHotKey`/unregister with retained references and main-thread event routing.
- [ ] Add shortcut recorder/edit controls and conflict/error copy; do not claim registration on failure.
- [ ] Route start/stop to timer engine; stop always invokes abandon confirmation.
- [ ] Run focused hotkey tests and manual shortcut test with another app focused.

## Task 11: Wire lifecycle recovery and resource safeguards

**Files:** Modify `FocusdoroApp.swift`, `MenuBarController.swift`, `TimerEngine.swift`, `SessionStore.swift`.

**Interfaces:** `AppLifecycleCoordinator.applicationDidLaunch() async`; `applicationWillTerminate()`; `handleSystemWake()`.

- [ ] Restore Keychain/token state, Core Data store, pending comment statuses, and timer deadline on launch.
- [ ] Refresh Todoist only on launch, popover open, manual retry, or completion conflict; no tight polling.
- [ ] Add sign-out/reset flow that deletes token but preserves local history.
- [ ] Test sleep/wake and app termination/relaunch manually with a short test duration.
- [ ] Measure idle memory and verify no web view/backend process exists.

## Task 12: Verification and handoff

**Files:** Modify the named test files when verification exposes a defect; create `docs/testing-checklist.md` with the recorded implementation evidence.

- [ ] Run full suite: `xcodebuild test -scheme Focusdoro -destination 'platform=macOS'`.
- [ ] Run static checks/build: `xcodebuild build -scheme Focusdoro -configuration Release`.
- [ ] Manual acceptance: fresh token, task search, start focus, close popover, shortcut, abandon confirmation, timer completion, overlay, break, Complete task, Todoist comment, offline retry, relaunch recovery.
- [ ] Verify Keychain/token redaction in logs and crash diagnostics.
- [ ] Verify menu-bar-only behavior, notification permission denial fallback, accessibility labels, increased text size, multiple displays, and Mac sleep/wake.
- [ ] Record known OS limitations and exact build/test commands in `docs/testing-checklist.md`.
