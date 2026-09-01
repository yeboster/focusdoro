# Automatic Updates and Todoist Task Actions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship verified click-to-install updates plus Todoist create-and-focus and direct-complete actions.

**Architecture:** Add focused update service and installer beside existing notification composition root. Extend existing Todoist API/sync/model/view pipeline for task mutations. CI produces one immutable release per `main` SHA so every installed build can compare and safely install newer artifact.

**Tech Stack:** Swift 5 language mode, SwiftPM, AppKit/SwiftUI, URLSession, UserNotifications, CryptoKit, GitHub Actions, GitHub Releases.

**Spec:** `docs/superpowers/specs/2026-08-31-updates-and-task-actions-design.md`

## Global Constraints

- macOS 14 minimum; no new package dependencies.
- Todoist API v1 only; tokens remain Keychain-only and never appear in errors.
- Update replacement only after HTTPS download, GitHub SHA-256 digest, bundle id/commit, and strict codesign verification.
- `make test` is only supported local test command.
- Update failures never interrupt timer state.

---

### Task 1: Todoist mutation API and cache

**Files:**
- Modify: `Sources/FocusdoroCore/Services/TodoistClient.swift`
- Modify: `Sources/FocusdoroCore/Services/TodoistSync.swift`
- Modify: `Tests/FocusdoroCoreTests/TodoistClientTests.swift`
- Modify: `Tests/FocusdoroCoreTests/TodoistSyncTests.swift`
- Modify: `Tests/FocusdoroCoreTests/TestSupport.swift`

**Interfaces:**
- Produces: `TodoistAPI.createTask(content:) async throws -> TodoistTask`
- Produces: `TodoistSync.createTask(content:) async throws -> TodoistTask`
- Produces: `TodoistSync.completeTask(id:) async throws`

- [ ] Add failing client tests asserting `POST /api/v1/tasks`, JSON `content`, returned task decoding, and existing close endpoint.
- [ ] Add failing sync tests asserting create inserts into `allTasks`/groups, close removes only after API success, and failures preserve cache.
- [ ] Run `make test`; confirm protocol/method failures.
- [ ] Implement minimal client and sync methods; trim and reject empty content using `TodoistError.invalidResponse`.
- [ ] Update all protocol fakes with deterministic create behavior.
- [ ] Run `make test`; confirm green.

### Task 2: Model and picker task actions

**Files:**
- Modify: `Sources/FocusdoroCore/Services/AppModel.swift`
- Modify: `Sources/FocusdoroCore/Views/TaskPickerView.swift`
- Modify: `Sources/FocusdoroCore/Views/PopoverView.swift`
- Modify: `Tests/FocusdoroCoreTests/AppModelTests.swift`

**Interfaces:**
- Produces: `AppModel.newTaskDraft: String`
- Produces: `AppModel.createTaskAndFocus() async`
- Produces: `AppModel.requestCompleteTask(_ task: TodoistTask)`
- Produces: `AppModel.confirmCompleteTask() async` supporting both active-session and picker completion.

- [ ] Add failing model tests: create clears draft, inserts/selects/starts focus; blank title is inert; picker completion closes without session/comment; failed close preserves task.
- [ ] Run `make test`; confirm missing intents.
- [ ] Implement pending picker-task confirmation separate from timer completion state.
- [ ] Add quick-add field and `Create & focus` button above list.
- [ ] Add row checkmark button with explicit completion confirmation and accurate no-focus wording.
- [ ] Run `make test`; confirm green.

### Task 3: Release discovery, notification action, and verified installer

**Files:**
- Create: `Sources/FocusdoroCore/Services/UpdateService.swift`
- Modify: `Sources/FocusdoroCore/Services/NotificationService.swift`
- Modify: `Sources/FocusdoroCore/Services/AppModel.swift`
- Modify: `Sources/FocusdoroCore/AppLifecycleCoordinator.swift`
- Create: `Tests/FocusdoroCoreTests/UpdateServiceTests.swift`
- Modify: `Tests/FocusdoroCoreTests/NotificationPolicyTests.swift`

**Interfaces:**
- Produces: `UpdateRelease(commitSHA:assetURL:assetDigest:)`
- Produces: `UpdateChecking.check() async throws -> UpdateRelease?`
- Produces: `UpdateInstalling.install(_:) async throws`
- Produces: notification category `FOCUSDORO_UPDATE`, action `INSTALL_UPDATE`.

- [ ] Add failing pure tests for release decoding, exact 40-char SHA extraction, installed-SHA equality, last-notified dedupe, HTTPS/asset-name requirements, SHA-256 comparison, and installer error copy.
- [ ] Run `make test`; confirm missing update types.
- [ ] Implement `GitHubUpdateService` with injected session, bundle metadata, defaults, file manager/process runners, and six-hour caller cadence.
- [ ] Implement download-to-temp, CryptoKit digest comparison, read-only DMG mount, bundle/commit/codesign validation, detached quoted helper with rollback and relaunch.
- [ ] Register notification action/delegate in lifecycle coordinator; route click and in-app banner action to `AppModel.installUpdate()`.
- [ ] Run `make test`; confirm green.

### Task 4: Build metadata and continuous release

**Files:**
- Modify: `Scripts/build-app.sh`
- Modify: `.github/workflows/ci.yml`
- Modify: `Tests/verify-dmg.sh`
- Modify: `docs/specs/notifications-and-hotkeys.md`
- Modify: `docs/specs/todoist-sync.md`

**Interfaces:**
- Produces: Info.plist `FocusdoroBuildCommit` containing exact `git rev-parse HEAD`.
- Produces: immutable GitHub release tag `continuous-${GITHUB_SHA}` and `Focusdoro.dmg` asset.

- [ ] Add local packaging assertion for embedded commit and workflow release step inspection.
- [ ] Modify build script to embed commit and use commit-derived monotonically non-semantic build metadata.
- [ ] Grant workflow `contents: write`; publish release via `gh release create continuous-$GITHUB_SHA build/Focusdoro.dmg --latest` only on `main` push after tests.
- [ ] Update as-built docs for update safety and task actions.
- [ ] Run `make test`, `make app`, and bundle metadata/signature checks.

### Task 5: Final verification and delivery

**Files:** all changed files.

- [ ] Run `make test` and require zero failures.
- [ ] Run `make build` and require success.
- [ ] Review `git diff --check`, full diff, updater security properties, and token-error redaction.
- [ ] Request independent code review and resolve all blocking findings.
- [ ] Commit one coherent Conventional Commit.
- [ ] Push current branch to `origin`.
- [ ] Run `make install`; confirm `/Applications/Focusdoro.app` embedded commit equals committed SHA or documented pre-commit build SHA and app process is running.
