# Todoist sync

## What it does

Two collaborators talk to Todoist. `TodoistClient` (`Sources/FocusdoroCore/Services/TodoistClient.swift`) is the transport: a `URLSession`-based client for the Todoist **API v1** (`https://api.todoist.com/api/v1`), implementing the `TodoistAPI` protocol (`listTasks`, `listProjects`, `closeTask(id:)`, `addComment(taskID:content:)`, `validateToken`). `TodoistSync` (`Sources/FocusdoroCore/Services/TodoistSync.swift`) is an `@MainActor @Observable` in-memory cache of tasks/projects plus connection state (`ConnectionState`: `.disconnected`/`.connecting`/`.connected`/`.tokenRejected`) and load state (`TaskLoadState`).

`TodoistSync` refreshes only on launch, popover open, manual retry, or a completion conflict check — never on a timer, to keep the app's steady-state network and CPU footprint near zero.

## Rules it upholds

- **API v1 only, never REST v2.** `TodoistClient.baseURL` is `.../api/v1`. A `410` response is mapped to `TodoistError.endpointRetired` with a distinct user message ("this Focusdoro build is calling a Todoist API that has been retired"), instead of falling into the generic server-error case — this exists specifically because the older REST v2 endpoints now return 410 wholesale. **This diverges from the original design spec**, whose §7 specified REST v2 (`/rest/v2/...`) as the integration target; that API is retired, so the shipped client targets v1 exclusively.
- **Cursor pagination, bounded.** `listTasks`/`listProjects` page through `{"results": [...], "next_cursor": ...}` up to `maxPages = 20` (`pageSize = 200`) so a server that never stops handing back a cursor can't loop forever.
- **Bounded retry.** `RetryPolicy.default` = 3 attempts, exponential backoff from a 0.5 s base capped at 4 s (`RetryPolicy.delay(forAttempt:)`). Only `TodoistError.isRetryable` cases retry: `.transport`, `.server`, `.rateLimited` — `.unauthorized`, `.invalidResponse`, `.notFound`, `.missingToken`, `.endpointRetired` never retry. A `429` honors the server's `Retry-After` header when present.
- **Token validated before it is stored.** `TodoistSync.connect(token:)` saves the trimmed token to the Keychain, then calls `client.validateToken()`; on any failure it deletes the token again before returning `.failure`, so an invalid token never lingers in the Keychain.
- **Token never logged.** `TodoistClient.send` catches transport errors via `(error as NSError).localizedDescription` — the request (and its `Authorization` header) is never included in an error's associated value.
- **Priority is wire-inverted.** `TaskPriority: p4=1, p3=2, p2=3, p1=4` (`Sources/FocusdoroCore/Models/TodoistModels.swift`); `label` computes `"P\(5 - rawValue)"` so wire `4` reads as the user-facing "P1". `TaskPriority.init(wireValue:)` defaults a missing/unmapped value to `.p4`.
- **Idempotent writes.** Every `POST` carries a fresh `X-Request-Id` header, which Todoist treats as an idempotency key.
- **Comment posting tolerates an empty success body.** `addComment` accepts `200/201/204`; an empty body still counts as posted, with a comment `id` of `""` (the field is optional downstream).
- **A project-list failure doesn't blank the task list.** `TodoistSync.refresh()` fetches tasks and projects concurrently (`async let`) but only tolerates a project failure (`try?`); a task-list failure still fails the refresh.

## Key types / files

- `Sources/FocusdoroCore/Services/TodoistClient.swift` — `TodoistAPI` protocol, `TodoistClient`, `RetryPolicy`.
- `Sources/FocusdoroCore/Services/TodoistSync.swift` — `TodoistSync`, `ConnectionState`, `TaskLoadState`.
- `Sources/FocusdoroCore/Models/TodoistModels.swift` — `TodoistTask`, `TodoistProject`, `TodoistDue`, `TodoistComment`, `TodoistPage`, `TaskPriority`, `TodoistError`, `TaskGroups`.

## Edge cases

- `410 Gone` on any endpoint → `TodoistError.endpointRetired`, non-retryable, distinct user message from a generic server error.
- `401`/`403` → `.unauthorized`; `TodoistSync.apply(error:)` flips `connection` to `.tokenRejected` specifically on `.unauthorized` (any other error leaves connection state alone and only sets `loadState = .failed`).
- `429` with a `Retry-After` header → the wait is `max(policy delay, retryAfter)`, still capped at `policy.maxDelay`.
- Non-HTTP response (e.g. a mocked transport returning garbage) → `.invalidResponse("Non-HTTP response")`.
- Empty/whitespace-only token passed to `connect(token:)` → short-circuits to `.failure(TodoistError.missingToken)` without touching the Keychain or network.
- Cancellation mid-request is translated to `CancellationError`, not surfaced as a `TodoistError`.

## Test coverage

- `Tests/FocusdoroCoreTests/TodoistClientTests.swift`, suite **"Todoist API v1 client"** (`.serialized`) — covers pagination, retry/backoff, status-code mapping including `410`→`.endpointRetired`, token validation, comment posting including the empty-body success path, and that no mapped error carries the token.
- `Tests/FocusdoroCoreTests/TodoistSyncTests.swift`, suite **"Todoist sync"** — connect validating before saving, rollback of a rejected token, blank-token rejection without a network call, disconnect clearing the cache, unauthorized mapping to `.tokenRejected`, tolerance of a project-listing failure, the refresh cancellation race, and local removal.
