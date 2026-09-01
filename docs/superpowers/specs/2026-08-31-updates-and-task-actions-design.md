# GitHub update, task creation, and direct completion design

Date: 2026-08-31

## Scope

Add three small, independent capabilities to existing menu-bar flow:

1. Notify user when repository `main` advances beyond installed build.
2. Create Todoist task and immediately focus it.
3. Complete active Todoist task without starting focus.

## Update checking and installation

Build script embeds current git commit in `FocusdoroBuildCommit` inside app Info.plist. After tests pass on each `main` push, CI publishes a full GitHub release tagged `continuous-<40-character SHA>` with `Focusdoro.dmg` and marks it latest. New `UpdateChecking` service requests latest release for `yeboster/focusdoro`, validates tag/asset metadata, compares release SHA with embedded SHA, and persists last-notified SHA in `UserDefaults`. It checks once after launch and every six hours while app runs. Network/API errors remain silent: update checks must not disrupt timer or Todoist behavior.

When remote SHA differs from installed and has not already been announced, service posts macOS local notification with an **Install** action and returns update metadata so `AppModel` can show an in-app **Install update** banner action. Notification response delegates to updater installation.

Install downloads `Focusdoro.dmg` over HTTPS, verifies GitHub's immutable `sha256:` asset digest, mounts read-only, and validates staged app's bundle identifier, embedded commit, and code-signature structure. It then copies and re-verifies staged app as a hidden sibling under `/Applications` so replacement renames stay atomic on one volume, and launches a detached replacement helper. Helper waits for current process to exit, atomically moves current `/Applications/Focusdoro.app` to backup, moves verified replacement into place, requires rollback on failure, and relaunches. Existing persisted timer deadline restores after relaunch. If destination is not writable or app is not installed in `/Applications`, updater reports an error and leaves current app untouched; no privilege prompt or shell interpolation is used.

## Task creation and focus

Extend `TodoistAPI` with `createTask(content:)`. Client sends `POST /api/v1/tasks` JSON and decodes created task. `TodoistSync.createTask` validates trimmed non-empty content, calls client, inserts returned task into cache, and recomputes groups. `AppModel.createTaskAndFocus` clears draft, creates, selects, then starts focus through existing engine/presence path. Picker exposes compact title field and `Create & focus` action.

Creation defaults to Todoist Inbox: no project or date payload. User can organize it later in Todoist.

## Direct completion

Each picker row exposes separate checkmark button. Selecting it stores pending task and opens confirmation. Confirm calls `TodoistSync.completeTask`, which closes through client and removes task locally. Success/error appears in banner. No timer state, session history, comment, or presence state changes because no focus occurred.

## Error handling and security

Todoist errors reuse fixed user messages. Token remains only in Keychain and never appears in request errors. Update endpoint is public and sends no secrets. Executable replacement proceeds only after HTTPS download, release-asset digest verification, exact bundle-id/commit checks, and `codesign --verify --strict`. Shell helper receives file paths as positional arguments and quotes them; release metadata never becomes executable shell text. Empty task titles never reach API.

## Testing

- Client request tests: create path/body/response and close behavior.
- Sync tests: created task inserted; direct completion removed; failure preserves cache.
- AppModel tests: create-select-start flow; direct completion without session.
- Update tests: release parsing, SHA comparison, deduplication, malformed responses, digest mismatch, bundle validation, and notification action routing.
- Packaging tests: embedded commit and continuous release workflow shape.
- Full `make test`, `make build`, diff review, then `make install`.
