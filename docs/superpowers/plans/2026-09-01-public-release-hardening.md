# Public Release Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove unused Slack integration and make Focusdoro safe and clear for public source distribution, with privacy-safe notifications, persistent opt-in automatic updates, least-privilege CI, public policy docs, and right-click Quit.

**Architecture:** Keep existing AppKit shell → `AppModel` → actor/service structure. Backward-compatible optional preference fields control new behavior; `PresenceCoordinator` remains for macOS Focus only; update discovery remains separate from installation. Public release controls and documentation must state current ad-hoc-signature limits rather than imply publisher authentication.

**Tech Stack:** Swift 6 tools / Swift 5 language mode, AppKit, SwiftUI Observation, UserNotifications, Security/Keychain, swift-testing, SwiftPM, GitHub Actions, shell scripts.

**Spec:** `docs/superpowers/specs/2026-09-01-public-release-hardening-design.md`

## Global Constraints

- macOS deployment target remains 14.0; no external SwiftPM dependencies.
- Run tests only through `make test`; plain `swift test` fails under Command Line Tools-only setup.
- Todoist token remains Keychain-only and must never enter preferences, Core Data, logs, docs examples, or errors.
- Todoist API remains `https://api.todoist.com/api/v1` only.
- New preference fields stay optional on wire so older stored JSON decodes.
- Automatic update installation defaults off and remains persisted once enabled.
- Task names are hidden from notifications by default.
- Slack is removed; macOS Focus through Shortcuts remains.
- Comments explain why, not what.
- Do not claim publisher verification while release artifacts are ad-hoc signed.

---

### Task 1: Add backward-compatible privacy and update preferences

**Files:**
- Modify: `Sources/FocusdoroCore/Services/AppPreferences.swift`
- Modify: `Tests/FocusdoroCoreTests/KeychainStoreTests.swift`
- Modify: `Tests/FocusdoroCoreTests/HotKeyServiceTests.swift`
- Modify: `Sources/FocusdoroCore/Services/NotificationService.swift`
- Modify: `Sources/FocusdoroCore/Views/SettingsView.swift`

**Interfaces:**
- Produces: `AppPreferences.automaticInstallUpdatesFlag: Bool?`
- Produces: `AppPreferences.automaticInstallUpdates: Bool` with false fallback
- Produces: `AppPreferences.showTaskNamesInNotificationsFlag: Bool?`
- Produces: `AppPreferences.showTaskNamesInNotifications: Bool` with false fallback
- Changes: `NotificationPolicy.focusCompleteBody(taskTitle:nextBreak:breakMinutes:showTaskName:) -> String`

- [ ] **Step 1: Add failing compatibility and round-trip tests**

Extend old-preferences JSON test to assert:

```swift
#expect(decoded.automaticInstallUpdates == false)
#expect(decoded.showTaskNamesInNotifications == false)
```

Extend round-trip test:

```swift
preferences.automaticInstallUpdates = true
preferences.showTaskNamesInNotifications = true
// encode/decode or write/read
#expect(decoded.automaticInstallUpdates == true)
#expect(decoded.showTaskNamesInNotifications == true)
```

Change notification policy tests to call `showTaskName:` and cover both branches:

```swift
#expect(NotificationPolicy.focusCompleteBody(
    taskTitle: "Private roadmap",
    nextBreak: .shortBreak,
    breakMinutes: 5,
    showTaskName: false
) == "Focus complete. Your 5-minute break is ready.")

#expect(NotificationPolicy.focusCompleteBody(
    taskTitle: "Private roadmap",
    nextBreak: .shortBreak,
    breakMinutes: 5,
    showTaskName: true
).contains("Private roadmap"))
```

- [ ] **Step 2: Run tests and verify red state**

Run: `make test`

Expected: compile failures for missing preference properties and `showTaskName:` argument.

- [ ] **Step 3: Implement optional fields and computed accessors**

Add stored fields:

```swift
public var automaticInstallUpdatesFlag: Bool?
public var showTaskNamesInNotificationsFlag: Bool?
```

Add accessors:

```swift
public var automaticInstallUpdates: Bool {
    get { automaticInstallUpdatesFlag ?? false }
    set { automaticInstallUpdatesFlag = newValue }
}

public var showTaskNamesInNotifications: Bool {
    get { showTaskNamesInNotificationsFlag ?? false }
    set { showTaskNamesInNotificationsFlag = newValue }
}
```

Append optional initializer parameters with default `nil`, assign them, and leave `.default` call unchanged so both defaults remain false.

Update notification policy signature and gate title interpolation:

```swift
public static func focusCompleteBody(
    taskTitle: String,
    nextBreak: TimerPhase,
    breakMinutes: Int,
    showTaskName: Bool
) -> String
```

`NotificationService.notifyFocusComplete` passes `prefs.showTaskNamesInNotifications`.

Add Settings toggles:

```swift
toggleRow("Show task names in notifications", isOn: preferences.showTaskNamesInNotifications)
toggleRow("Install updates automatically", isOn: preferences.automaticInstallUpdates)
```

Footnotes explain lock-screen exposure and that auto-install remains enabled until switched off.

- [ ] **Step 4: Run tests and build**

Run: `make test && make build`

Expected: exit 0; generic and opted-in notification tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/FocusdoroCore/Services/AppPreferences.swift \
  Sources/FocusdoroCore/Services/NotificationService.swift \
  Sources/FocusdoroCore/Views/SettingsView.swift \
  Tests/FocusdoroCoreTests/KeychainStoreTests.swift \
  Tests/FocusdoroCoreTests/HotKeyServiceTests.swift
git commit -m "feat(settings): add privacy-safe update prefs"
```

---

### Task 2: Separate update discovery from persistent automatic installation

**Files:**
- Modify: `Sources/FocusdoroCore/Services/AppModel.swift`
- Modify: `Sources/FocusdoroCore/Services/NotificationService.swift`
- Modify: `Tests/FocusdoroCoreTests/AppModelTests.swift`
- Modify: `Tests/FocusdoroCoreTests/NotificationPolicyTests.swift`

**Interfaces:**
- Consumes: `AppPreferences.automaticInstallUpdates`
- Keeps: `AppModel.installAvailableUpdate()` as manual action
- Produces: discovery behavior where disabled means notification only; enabled means one call to `UpdateInstalling.install(_:)`
- Produces: `NotificationPresenting.notifyUpdateAvailable(automaticInstallEnabled: Bool)`

- [ ] **Step 1: Write failing update behavior tests**

Extend updater spy to record `check` and `install` counts. Add:

```swift
@Test("Update discovery notifies but does not install when automatic installation is off")
@Test("Update discovery installs once when automatic installation is on")
@Test("Automatic installation remains enabled after staging an update")
```

Use `InMemoryPreferencesStore`, set flag explicitly per test, start model, wait on existing async test helper, and assert:

```swift
#expect(await updater.installCount == 0) // disabled
#expect(notifications.updateCount == 1)
```

and:

```swift
#expect(await updater.installCount == 1) // enabled
#expect(preferencesStore.preferences.automaticInstallUpdates)
```

The persistence test calls the staging flow and verifies no code writes flag false.

Update notification identifier tests for changed protocol signature and both notification modes.

- [ ] **Step 2: Run tests and verify red state**

Run: `make test`

Expected: failures because discovery always follows current manual-notification path and protocol lacks mode argument.

- [ ] **Step 3: Implement mode-aware discovery**

In update-check completion:

```swift
availableUpdate = release
if preferences.automaticInstallUpdates {
    await installAvailableUpdate()
} else {
    notifications.notifyUpdateAvailable(automaticInstallEnabled: false)
    banner = BannerMessage(... offersUpdateInstall: true)
}
```

Preserve `isInstallingUpdate` guard and existing cold-launch re-resolution. Never mutate `preferences.automaticInstallUpdates` in installer paths. Keep user-triggered install action operational.

Change notification protocol to:

```swift
func notifyUpdateAvailable(automaticInstallEnabled: Bool)
```

Use accurate copy: disabled says update is available for review/install; enabled says automatic installation is starting. Remove “verified update” publisher implication.

- [ ] **Step 4: Run focused/full verification**

Run: `make test && make build`

Expected: exit 0; disabled and enabled tests pass; existing concurrent-install test stays green.

- [ ] **Step 5: Commit**

```bash
git add Sources/FocusdoroCore/Services/AppModel.swift \
  Sources/FocusdoroCore/Services/NotificationService.swift \
  Tests/FocusdoroCoreTests/AppModelTests.swift \
  Tests/FocusdoroCoreTests/NotificationPolicyTests.swift
git commit -m "feat(updates): make auto-install persistent opt-in"
```

---

### Task 3: Remove Slack and migrate legacy credential

**Files:**
- Delete: `Sources/FocusdoroCore/Services/SlackClient.swift`
- Delete: `Sources/FocusdoroCore/Services/SlackPresenceChannel.swift`
- Modify: `Sources/FocusdoroCore/Services/FocusPresence.swift`
- Modify: `Sources/FocusdoroCore/Services/AppPreferences.swift`
- Modify: `Sources/FocusdoroCore/Services/AppModel.swift`
- Modify: `Sources/FocusdoroCore/Services/KeychainStore.swift`
- Modify: `Sources/FocusdoroCore/AppLifecycleCoordinator.swift`
- Modify: `Sources/FocusdoroCore/Views/SettingsView.swift`
- Modify: `Tests/FocusdoroCoreTests/FocusPresenceTests.swift`
- Modify: `Tests/FocusdoroCoreTests/KeychainStoreTests.swift`

**Interfaces:**
- Keeps: `FocusPresenceSettings(macFocusEnabled:startShortcutName:endShortcutName:)`
- Keeps: `PresenceChannel`, `PresenceCoordinator`, `MacFocusChannel`
- Changes: `PresenceServices` to contain only `coordinator`
- Produces: `LegacyCredentialMigrator.migrateIfNeeded(preferences:todoistTokens:legacySlackTokens:)`
- Produces: optional `legacySlackCredentialRemovedFlag` / computed false-default accessor

- [ ] **Step 1: Write failing migration and macOS-only tests**

Add tests proving:

```swift
@Test("Legacy Slack cleanup deletes only the old Slack entry")
@Test("Failed legacy cleanup remains pending for a future launch")
@Test("Completed legacy cleanup is idempotent")
```

Use separate `InMemoryTokenStore` instances for Todoist and legacy Slack. Assert Todoist token remains unchanged. Retain tests for Mac Focus engage/release, missing shortcut warnings, coordinator fan-out/error handling, and app-model session lifecycle. Delete Slack transport/status/channel/connect tests.

Update preference round-trip expectations to only macOS Focus fields while decoding historical JSON containing extra Slack keys successfully.

- [ ] **Step 2: Run tests and verify red state**

Run: `make test`

Expected: compile failures for missing migration API until implementation lands.

- [ ] **Step 3: Implement Slack-free presence model**

Reduce `FocusPresenceSettings` to three macOS fields. Remove Slack cases from `PresenceMessage`. Reduce `PresenceServices` to coordinator. Composition creates:

```swift
PresenceServices(
    coordinator: PresenceCoordinator(channels: [
        MacFocusChannel(runner: shortcuts, settings: settings)
    ])
)
```

Remove Slack draft/connection methods from `AppModel` and Slack controls from Settings.

- [ ] **Step 4: Implement one-time legacy Keychain cleanup**

Keep legacy service name as migration-only constant, not active feature API. Add migrator that:

1. Returns immediately when marker true.
2. Deletes token from legacy service.
3. Sets marker true only after successful deletion.
4. Never reads/logs/returns credential content.
5. Never receives or mutates Todoist service except test assertion boundary.

Invoke during composition before normal model startup. If cleanup fails, leave marker false and continue app startup without banner containing sensitive details.

- [ ] **Step 5: Delete Slack files and remove all live references**

Delete both production files. Search:

```bash
rg -n -i 'slack|xox[pbar]-|users\.profile|dnd\.set' Sources Tests README.md docs CLAUDE.md
```

At this task stage, expected matches may remain only in docs scheduled for Task 6 and legacy migration names/tests. Production feature/UI matches must be zero.

- [ ] **Step 6: Run tests and build**

Run: `make test && make build`

Expected: exit 0; macOS Focus behavior remains green; no Slack production types compile.

- [ ] **Step 7: Commit**

```bash
git add -A Sources Tests
git commit -m "refactor(presence): remove Slack integration"
```

Body must note one-time legacy Keychain cleanup because removal is security-sensitive migration.

---

### Task 4: Add right-click Quit to menu-bar icon

**Files:**
- Modify: `Sources/FocusdoroCore/MenuBarController.swift`
- Modify: `Tests/FocusdoroCoreTests/AppModelTests.swift`

**Interfaces:**
- Produces: `MenuBarClick` pure classifier or equivalent test seam mapping `NSEvent.EventType` to `.togglePopover` / `.showQuitMenu`
- Produces: temporary `NSMenu` with `Quit Focusdoro`
- Keeps: left-click `togglePopover()`

- [ ] **Step 1: Write failing click-routing tests**

Add pure tests independent of WindowServer where possible:

```swift
#expect(MenuBarClick.action(for: .leftMouseUp) == .togglePopover)
#expect(MenuBarClick.action(for: .rightMouseUp) == .showQuitMenu)
```

In WindowServer suite, assert controller reports context menu item title and left-click action remains popover toggle. Inject termination closure for testability rather than terminating test process:

```swift
MenuBarController(model: model, terminate: { quitCount += 1 })
```

Invoke exposed test seam and assert count becomes one.

- [ ] **Step 2: Run tests and verify red state**

Run: `make test`

Expected: compile failures for missing classifier/injected termination seam.

- [ ] **Step 3: Implement right-click route**

Set:

```swift
button.sendAction(on: [.leftMouseUp, .rightMouseUp])
```

Handler reads `NSApp.currentEvent?.type`, delegates to pure classifier, and either toggles popover or closes it then presents temporary menu. Menu contains one item:

```swift
NSMenuItem(title: "Quit Focusdoro", action: #selector(quitFromStatusMenu), keyEquivalent: "q")
```

`quitFromStatusMenu` invokes injected default `{ NSApp.terminate(nil) }`. Attach menu only while calling `button.performClick(nil)` or `statusItem.popUpMenu(menu)`, then set `statusItem.menu = nil` with `defer` so future left clicks keep popover behavior.

- [ ] **Step 4: Run tests/build**

Run: `make test && make build`

Expected: exit 0; existing popover tests unchanged; quit route test passes.

- [ ] **Step 5: Commit**

```bash
git add Sources/FocusdoroCore/MenuBarController.swift Tests/FocusdoroCoreTests/AppModelTests.swift
git commit -m "feat(menu): add right-click quit action"
```

---

### Task 5: Harden CI and add automated secret scanning

**Files:**
- Modify: `.github/workflows/ci.yml`
- Create: `.github/dependabot.yml`
- Modify: `.gitignore`

**Interfaces:**
- Produces: workflow default `contents: read`
- Produces: release-only job permission `contents: write`
- Produces: immutable SHA-pinned action references
- Produces: full-history Gitleaks scan

- [ ] **Step 1: Add a local workflow-policy verification script/check**

Use Python to parse workflow text and fail when:

- top-level `contents: write` exists;
- any `uses:` value ends in `@v5`, `@main`, or another non-40-hex ref;
- no Gitleaks invocation exists.

Run it before edits and confirm failure against current workflow.

- [ ] **Step 2: Resolve immutable action SHAs and update workflow**

Resolve reviewed current tag commits with:

```bash
git ls-remote https://github.com/actions/checkout.git refs/tags/v5
git ls-remote https://github.com/actions/cache.git refs/tags/v5
git ls-remote https://github.com/actions/upload-artifact.git refs/tags/v5
git ls-remote https://github.com/gitleaks/gitleaks-action.git refs/tags/v2
```

Replace each action ref with returned full 40-character SHA and trailing version comment. Set:

```yaml
permissions:
  contents: read
```

Move release publication into dedicated job after build artifact handoff, with:

```yaml
permissions:
  contents: write
```

Ensure write-capable job does not check out or execute pull-request code. Add Gitleaks full-history scan in read-only test/security job with `fetch-depth: 0`.

- [ ] **Step 3: Add Dependabot and ignore coverage**

Create weekly `github-actions` Dependabot config. Extend `.gitignore` with approved environment/key/signing/Xcode/database/log/dump patterns while retaining existing entries.

- [ ] **Step 4: Run policy check and YAML syntax sanity check**

Run Python policy check again; expected exit 0. Also run:

```bash
ruby -e 'require "yaml"; YAML.load_file(".github/workflows/ci.yml", aliases: true); puts "valid"'
```

Expected: `valid` and exit 0.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/ci.yml .github/dependabot.yml .gitignore
git commit -m "ci: harden release and secret scanning"
```

Body explains least-privilege token and immutable action pins.

---

### Task 6: Publish license, security, privacy, contribution, and current docs

**Files:**
- Create: `LICENSE`
- Create: `SECURITY.md`
- Create: `PRIVACY.md`
- Create: `CONTRIBUTING.md`
- Modify: `README.md`
- Modify: `docs/README.md`
- Modify: `docs/specs/focus-mode.md`
- Modify: `docs/specs/notifications-and-hotkeys.md`
- Modify: `docs/specs/security.md`
- Modify: `docs/testing-checklist.md`
- Modify: `docs/superpowers/specs/2026-08-29-focusdoro-design.md`
- Modify: `docs/superpowers/plans/2026-08-29-focusdoro-implementation-plan.md`
- Modify: `CLAUDE.md` (`AGENTS.md` is its symlink)

**Interfaces:**
- Produces: MIT licensing under `yeboster`
- Produces: GitHub private vulnerability-reporting route
- Produces: accurate privacy/data-flow contract
- Produces: current API/update/Slack-free docs

- [ ] **Step 1: Add policy documents**

Use canonical MIT license text with `Copyright (c) 2026 yeboster`.

`SECURITY.md` must tell reporters to use repository **Security → Advisories → Report a vulnerability**, avoid public issues for secrets/exploits, revoke exposed Todoist tokens immediately, list supported branch `main`/latest release, and set reasonable acknowledgment expectations without promising SLA.

`PRIVACY.md` documents Todoist API calls/comments, Keychain token, local Core Data history, UserDefaults timer/preferences, GitHub release metadata polling, local notifications/task-title opt-in, Shortcuts execution, no Slack, no analytics if verified, and deletion routes.

`CONTRIBUTING.md` documents macOS 14+, Swift 6 tools, `make test`, `make build`, `make app`, no real credentials in fixtures, public-release docs consistency, and private vulnerability reporting.

- [ ] **Step 2: Rewrite README and docs index**

Remove Slack. Replace fixed test count. Add source install (`make install` replaces `/Applications/Focusdoro.app`), release/signing limitation, right-click Quit, security/privacy/license/contributing links, Todoist API v1, and canonical releases URL. Do not claim notarization or publisher-authenticated auto-updates.

Rewrite `docs/README.md` as current spec index; move historical agent handoff language out of primary reading path.

- [ ] **Step 3: Update technical docs and archive labels**

Rewrite focus-mode spec as macOS Focus-only. Update notification/update spec with persistent opt-in and task privacy. Remove Slack checklist/tests. Update security spec and `CLAUDE.md`. Add top banners to old 2026-08-29 design/plan:

```markdown
> Historical document. Todoist REST v2 details are superseded by the shipped API v1 contract in `docs/specs/todoist-sync.md`.
```

Do not silently rewrite historical rationale beyond correcting dangerous live guidance.

- [ ] **Step 4: Run publication-content checks**

Run:

```bash
rg -n -i 'slack|xox[pbar]-|rest/v2|294 unit tests|verified update' README.md Sources Tests docs CLAUDE.md
```

Expected:

- no Slack feature/credential fixture matches;
- REST v2 matches only inside clearly marked historical/superseded context, or none;
- no stale fixed test count;
- no publisher-verification overclaim.

Check required root files exist and README links resolve locally.

- [ ] **Step 5: Run tests/build and commit**

Run: `make test && make build`

Then:

```bash
git add LICENSE SECURITY.md PRIVACY.md CONTRIBUTING.md README.md docs CLAUDE.md AGENTS.md
git commit -m "docs: prepare repository for public release"
```

---

### Task 7: Final independent review, secret scan, package, and install

**Files:**
- Review all changed files; modify only to resolve verified findings.

**Interfaces:**
- Consumes: all prior task outputs
- Produces: installed `/Applications/Focusdoro.app` matching reviewed source

- [ ] **Step 1: Review aggregate diff**

Run:

```bash
git status --short
git diff HEAD~6 --stat
git diff HEAD~6 --check
```

Request reviewer focused on spec compliance, migration safety, update concurrency, notification privacy, click routing, CI permissions, and docs truthfulness. Fix Critical/Important findings using TDD and commit each coherent fix.

- [ ] **Step 2: Run full secret and history scan**

Run:

```bash
gitleaks git . --redact
```

Expected: 16+ commits scanned and `no leaks found`. Any confirmed finding blocks publication; revoke credential before history cleanup.

- [ ] **Step 3: Run full tests and builds fresh**

Run:

```bash
make test
make build
make app
```

Expected: each exits 0. Verify generated bundle:

```bash
plutil -lint build/Focusdoro.app/Contents/Info.plist
codesign --verify --strict --verbose=2 build/Focusdoro.app
```

Expected: valid plist and structurally valid ad-hoc signature; do not interpret as publisher authentication.

- [ ] **Step 4: Install user-facing build**

Run:

```bash
make install
```

Expected: `/Applications/Focusdoro.app` replaced and relaunched. Manually confirm left click opens popover, right click shows `Quit Focusdoro`, auto-install toggle persists after relaunch, and task-title notification toggle defaults off.

- [ ] **Step 5: Final repository status**

Run:

```bash
git status --short
git log --oneline -8
```

Expected: clean worktree and coherent task commits. Report residual ad-hoc updater trust risk and GitHub settings still requiring owner action: private vulnerability reporting, branch protection, approved Actions policy, and repository visibility change.
