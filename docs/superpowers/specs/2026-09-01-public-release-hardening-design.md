# Public release hardening design

Date: 2026-09-01
Status: Approved

## Goal

Prepare Focusdoro for a public source repository without leaking credentials or overstating binary/update security. Remove unused Slack integration, keep macOS Focus support, make task notifications private by default, make automatic update installation an explicit persistent opt-in, harden release CI, and add public project policies. Add a right-click menu-bar path to quit the app.

Gitleaks independently scanned all 16 commits and approximately 706 KB with no leaks found.

## Scope

### Remove Slack; retain macOS Focus

Delete `SlackClient`, `SlackPresenceChannel`, Slack transport/status tests, Slack settings UI, Slack model state, Slack preference fields, Slack Keychain constants, and Slack documentation. Keep `PresenceChannel`, `PresenceCoordinator`, and `MacFocusChannel` so session lifecycle still drives user-selected Shortcuts without shell interpolation.

Unknown fields in older preferences JSON are ignored by synthesized `Codable`, so stored Slack preference keys do not require a schema migration. Add a one-time migration marker to preferences and delete the legacy `<bundle-id>.slack` Keychain item on launch. This deletion must never affect the Todoist Keychain entry. If deletion fails, surface no credential material; retry on a future launch until the migration marker can be committed.

`PresenceServices` becomes coordinator-only. `AppModel` loses Slack token drafts, connection state, connect/disconnect methods, and Slack-specific messages. Presence failures retain generic macOS Focus failure reporting.

### Update checking and automatic installation

Update checks and update-available notifications remain. Add optional `automaticInstallUpdates` to `AppPreferences` so older stored JSON continues decoding.

Effective behavior:

- Missing preference defaults to `false`.
- Disabled mode checks for releases and posts an availability notification, but never downloads or installs automatically.
- Enabled mode automatically downloads, validates, stages, installs, and relaunches when a new release is discovered.
- User choice persists through encoding, relaunch, bundle replacement, and successful installation. Update code must never reset it.
- Concurrent checks or duplicate discovery cannot trigger multiple installers for one release.
- Manual install action remains available where appropriate.

Settings explain that automatic installation is optional. Public docs state that current ad-hoc signing verifies bundle integrity only, not publisher identity. Developer ID signing, notarization, and signer-identity pinning remain required before claiming a trusted update channel.

Notification text must not call an ad-hoc-signed release publisher-verified. Disabled mode announces availability and directs user to review/install. Enabled mode may announce installation progress without overstating identity.

### Notification privacy

Add optional `showTaskNamesInNotifications` preference. Missing preference defaults to `false`.

- Disabled: focus-completion notification uses generic text and omits task title.
- Enabled: existing task-title text is used.
- Choice persists across relaunches and updates.
- Settings warns that task names can appear on lock screens, Notification Center, screen shares, and synced notification surfaces.

### Right-click Quit

Configure `NSStatusBarButton` to send both left- and right-mouse actions.

- Left click preserves existing popover toggle.
- Right click closes any visible popover and presents a small `NSMenu` containing `Quit Focusdoro`.
- Quit routes through `NSApplication.terminate`, preserving application termination callbacks and cleanup.
- Context menu is attached only for display and then detached so later left clicks continue opening the popover rather than permanently opening the menu.
- Keyboard/global-hotkey popover behavior remains unchanged.

### Public repository files

Add:

- MIT `LICENSE`, copyright holder `yeboster`.
- `SECURITY.md` directing reports to GitHub private vulnerability reporting, requesting no public credential/exploit disclosure, and giving token-revocation guidance.
- `PRIVACY.md` documenting Todoist traffic, local history and timer persistence, GitHub release checks, macOS notifications, user-selected Shortcuts, retention/deletion, and absence of Slack integration.
- `CONTRIBUTING.md` with build/test rules, no-secret/test-fixture requirements, and security-reporting route.

Expand `.gitignore` for environment files, private keys, signing profiles, Xcode user state, local databases, logs, dumps, and DerivedData. Preserve an explicit `.env.example` exception if examples are introduced later.

Refresh README with source installation, `make install` replacement behavior, current privacy/security/license links, current Todoist API v1 contract, update trust limitations, and no fixed test count. Remove Slack claims. Rewrite `docs/README.md` as current developer-doc index. Mark old Superpowers design/plan documents historical and superseded where they mention retired Todoist REST v2. Update specs, testing checklist, and `CLAUDE.md`; `AGENTS.md` follows through its symlink.

### CI and release hardening

Set workflow-level `contents: read`. Grant `contents: write` only to release-publishing job. Separate untrusted build/test work from write-capable publication as far as practical. Pin official actions and Gitleaks action to reviewed full commit SHAs, with comments naming upstream versions. Add automated full-history secret scanning and dependency/update automation for pinned action revisions.

The release workflow must not claim notarization or publisher authentication until Developer ID credentials and signer checks exist.

## Compatibility and migration

New preference fields remain optional to preserve synthesized `Codable` compatibility:

- `automaticInstallUpdates: Bool?`
- `showTaskNamesInNotifications: Bool?`
- legacy Slack Keychain cleanup marker: optional Boolean

Computed accessors provide false defaults. Setters write explicit values. Existing settings, Todoist token, history, timer deadline, and macOS Focus shortcut names remain untouched. Legacy Slack preference JSON becomes harmless unknown data after fields are removed; legacy Slack Keychain credential is removed once.

## Tests

Follow TDD:

1. Older preferences JSON decodes with automatic install and task-title display disabled.
2. Both preferences survive encode/decode and in-memory store round trips.
3. Disabled automatic install discovers/notifies but never installs.
4. Enabled automatic install installs once and remains enabled after simulated replacement/relaunch.
5. Generic task-completion body is default; title appears only after opt-in.
6. Legacy Slack Keychain migration deletes only Slack entry and retries safely after failure.
7. macOS Focus still engages/releases through `PresenceCoordinator`.
8. Left click toggles popover; right click exposes Quit; Quit uses app termination route.
9. Source/docs inventory contains no Slack implementation claims or retired live API guidance.
10. CI permissions are least-privilege and action references are immutable.

Final verification:

```bash
gitleaks git . --redact
make test
make build
make app
make install
```

Also inspect Git status/diff, tracked inventory, generated bundle metadata/signature structure, and release documentation consistency.

## Residual risks

- Opt-in automatic installation still lacks publisher authentication while builds are ad-hoc signed. Documentation and UI must not hide this limitation.
- User-selected Shortcuts execute with user authority; Focusdoro controls only fixed executable/argument invocation, not shortcut contents.
- Todoist task/history data remains plaintext under the user's app data and preferences locations; privacy documentation and clear-history behavior define this boundary.
- Commit author email remains public unless repository history is separately rewritten before visibility change.
