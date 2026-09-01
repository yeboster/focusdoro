# Security

## What it does

Everything about how the Todoist personal API token is stored, read, and never leaked. `KeychainStore` (`Sources/FocusdoroCore/Services/KeychainStore.swift`) is the sole place the token is written or read, via `Security` framework calls (`SecItemAdd`/`SecItemUpdate`/`SecItemCopyMatching`/`SecItemDelete`) against a `kSecClassGenericPassword` item.

## Rules it upholds

- **The token lives only in the Keychain.** Never in `UserDefaults` (`AppPreferences` has no token field — see `docs/specs/preferences-and-settings.md`), never in Core Data (`SessionRecord` has no token field), never in a log line, never in a crash report, never in exported history. `TodoistClient`'s only reference to the token is through the injected `tokenProvider` closure, which reads it fresh from `KeychainStore` on each request rather than caching it in a property that could be dumped.
- **Never echoed in an error message.** `TodoistClient.send`'s transport-failure catch uses `(error as NSError).localizedDescription` — never the `URLRequest` itself, which carries the `Authorization: Bearer <token>` header. `KeychainError.userMessage` for `.unexpectedStatus` includes only the `OSStatus` code, never any data.
- **Validated before stored.** `TodoistSync.connect(token:)` writes the trimmed token to the Keychain, then calls `client.validateToken()`; on any failure (including a rejected token) it calls `tokenStore.deleteToken()` before returning failure — an invalid token is never left sitting in the Keychain.
- **Scoped to the bundle identifier.** `KeychainStore.defaultService` is `(Bundle.main.bundleIdentifier ?? "com.focusdoro.app") + ".todoist"`. The signed `build/Focusdoro.app` (bundle id `so.bon.focusdoro`, set by `Scripts/build-app.sh`) and a bare `swift run` binary (no bundle id, falls back to the hardcoded default) therefore read/write **different** Keychain items — expected, not a bug, and one reason `make run`/`make app` is the supported way to exercise Todoist features end-to-end rather than `swift run`.
- **Accessible after first unlock, not always.** New items are inserted with `kSecAttrAccessibleAfterFirstUnlock` — available once the user has unlocked the Mac at least once since boot, not before, and not requiring biometric/password re-auth on every read (this is a launch-agent-style menu-bar app, not something that should re-prompt for Touch ID every time it fetches tasks).
- **Update-in-place, not delete-then-insert.** `saveToken` tries `SecItemUpdate` first and only falls back to `SecItemAdd` on `errSecItemNotFound`, so an existing item's ACL/metadata aren't churned on every reconnect.
- **Disconnect removes the Keychain item but keeps local history.** `TodoistSync.disconnect()` calls `tokenStore.deleteToken()` and clears the in-memory task cache, but never touches `SessionStore` — past sessions, comments, and stats survive a disconnect.
- **An empty stored string is treated as "no token."** `readToken()` returns `nil` for an empty decoded string, not `""`, so callers checking `hasToken` don't get a false positive.

- **Legacy credential migration.** Older releases could leave a separate Slack Keychain item. Current Focusdoro performs a one-time best-effort deletion without reading its value; failure leaves migration pending for retry and never affects Todoist token or timer behavior.
- **Update trust boundary.** Current release artifacts are ad-hoc signed. Digest, bundle, embedded-commit, and structural signature checks detect corruption but do not authenticate publisher identity. Developer ID signing, notarization, and signer pinning are required before treating automatic updates as publisher-authenticated.

## Key types / files

- `Sources/FocusdoroCore/Services/KeychainStore.swift` — `TokenStoring` protocol, `KeychainStore`, `KeychainError`, `InMemoryTokenStore` (test double).
- `Sources/FocusdoroCore/Services/TodoistSync.swift` — `connect(token:)`/`disconnect()`, the only caller of `saveToken`/`deleteToken`.
- `Sources/FocusdoroCore/Services/TodoistClient.swift` — `tokenProvider` closure, `makeRequest` (adds the `Authorization` header), transport-error redaction.
- `Sources/FocusdoroCore/Views/ConnectView.swift` — the token-entry UI; `AppModel.tokenDraft` is cleared immediately after `connect()` returns, success or failure, so the pasted token never lingers in view state longer than the single connect attempt.

## Edge cases

- `SecItemAdd`/`SecItemUpdate`/`SecItemCopyMatching`/`SecItemDelete` returning an unexpected `OSStatus` (e.g. a Keychain access-control prompt denied by the user) surfaces as `KeychainError.unexpectedStatus(status)`, mapped to a user-facing message that includes the raw status code for diagnosis but never the data being written/read.
- `deleteToken()` treats `errSecItemNotFound` as success, not an error — disconnecting when no token was ever stored is a no-op, not a failure.
- The Keychain item's stability is coupled to the app's code signature and bundle id: an ad-hoc-resigned or differently-signed rebuild of `Focusdoro.app` (or renaming the bundle id) can lose access to a previously-stored item, since Keychain ACLs are tied to the requesting app's identity — a known OS-level limitation of this app's ad-hoc signing setup (`Scripts/build-app.sh`'s `codesign --force --deep --sign -`), not a code bug.

## Test coverage

`Tests/FocusdoroCoreTests/KeychainStoreTests.swift`, suite **"Keychain token storage"** (`.serialized`, since Keychain access is a shared system resource and tests must not race each other) — save/read/update/delete round trip, empty-string-as-nil, `errSecItemNotFound` on delete, `InMemoryTokenStore` as the test double used everywhere else in the suite.
