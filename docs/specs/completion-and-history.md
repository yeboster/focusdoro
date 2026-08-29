# Completion and history

## What it does

When a focus or break phase ends — by deadline, by "Complete task", or by user-confirmed abandon — `CompletionOrchestrator` (`actor`, `Sources/FocusdoroCore/Services/CompletionOrchestrator.swift`) persists the session locally, then performs whatever Todoist side effect applies (post a "minutes focused" comment, optionally close the task). `SessionStore` (`Sources/FocusdoroCore/Services/SessionStore.swift`) is the local record: a Core Data stack built from a **programmatic** `NSManagedObjectModel` (no `.xcdatamodeld`, since compiling one needs Xcode's `momc`). `HistoryView`/`CompletionOverlayView` read from it to render today's stats, streak, and recent sessions, entirely offline.

## Rules it upholds

- **Local write before any network call.** Every `finishFocus` path calls `store.insertSession` before touching Todoist, so a network failure can never lose measured focus time — the record just stays `todoistCommentStatus == .pending`/`.failed` and is retried later.
- **Session id is the idempotency key, everywhere.** `CompletionOrchestrator` checks `existing.todoistCommentStatus == .posted` before doing any work for a given `sessionID` and returns the already-`.posted` outcome untouched if so. `SessionStore.insertSession` upserts by `id` (`fetchObject(id:)` then update-or-insert), and the Core Data entity has a store-level `uniquenessConstraints = [[id]]` on top (SQLite store only — `NSInMemoryStoreType` rejects uniqueness constraints, so `SessionStore.makeModel(uniqueByID:)` omits it for in-memory/test stores; the fetch-before-insert path still prevents duplicates there).
- **Abandon never closes the task**, and only comments if the user opted in. `CompletionOrchestrator.finishFocus(reason: .abandoned)` logs a comment only when `logsPartialTime` (from `AppPreferences.logsAbandonedTime`, default `true`) is on, the task id is non-empty, and at least one whole minute (`CommentFormatter.minutes(...) >= 1`) was measured.
- **The local record survives a failed Todoist close.** If `reason == .taskCompleted` and `todoist.closeTask` throws, the session is still recorded `status: .completed` locally with the comment attempted separately — the UI exposes a retry rather than losing the session.
- **Comment format is deterministic and auditable.** `CommentFormatter.comment`: `"Focusdoro: \(minutes) min focused on this task\(tail)."`, where `tail` is `" (stopped early, yyyy-MM-dd HH:mm)"` for a partial/abandoned session or `" (yyyy-MM-dd HH:mm)"` otherwise, formatted with `en_US_POSIX` locale and the caller's timezone (default `.current`). `minutes(forElapsedSeconds:)` rounds to the nearest minute with a floor of 1 for any positive duration.
- **Retry is idempotent and selective.** `retryComment` only re-posts when `todoistCommentStatus` is `.pending` or `.failed` **and** `status` is `.completed` or `.abandoned` **and** `kind == .focus` — a break record (`todoistCommentStatus == .notApplicable`) or an already-`.posted` record is left alone. `retryPendingComments()` (called on launch, via `AppModel.start()`) sweeps every session matching that same condition.
- **"Today" and streaks are calendar-day, not rolling-24h.** `SessionStore.todaySummary(now:calendar:)` uses `calendar.startOfDay(for:)` boundaries; the streak walks backward one day at a time from today (or from yesterday if today has no completed session yet), counting consecutive days with at least one `status == .completed, kind == .focus` session.
- **Abandoned/partial time is invested time, not a completed session.** `TodaySummary` tracks `focusedSeconds` (completed) and `partialSeconds` (abandoned) separately; `investedMinutes` (shown as "Today" in `HistoryView`) sums both, but only completed sessions count toward `completedFocusSessions` or the streak.

## Key types / files

- `Sources/FocusdoroCore/Services/CompletionOrchestrator.swift` — `CompletionOrchestrator`, `FocusFinishReason`, `CompletionOutcome`, `CommentFormatter`.
- `Sources/FocusdoroCore/Services/SessionStore.swift` — `SessionStore`, `SessionStoring` protocol, `SessionStoreError`, the programmatic `NSManagedObjectModel` (`makeModel(uniqueByID:)`).
- `Sources/FocusdoroCore/Models/TimerModels.swift` — `SessionRecord`, `SessionStatus`, `CommentStatus`, `TodaySummary`.
- `Sources/FocusdoroCore/AppLifecycleCoordinator.swift` — `NullSessionStore` fallback when Core Data fails to load at all.
- `Sources/FocusdoroCore/Views/HistoryView.swift`, `Sources/FocusdoroCore/Views/CompletionOverlayView.swift`, `Sources/FocusdoroCore/Services/CompletionOverlayController.swift` — the AppKit/SwiftUI presentation. `CompletionOverlayController` shows a non-activating, borderless `NSPanel` (`.canJoinAllSpaces, .fullScreenAuxiliary`) that floats over most spaces without stealing focus, auto-starting the next break after `AppPreferences.breakAutoStartDelaySeconds` (default 10s) unless the user acts first; on a full-screen space owned by another app macOS can still refuse to place it, in which case the completion notification is the fallback.

## Edge cases

- A session with zero measurable elapsed time (task selected and immediately abandoned) never posts a comment even with partial logging on — `CommentFormatter.minutes(...) >= 1` gates it.
- `retryComment` on a session that was never meant to comment (`todoistCommentStatus == .notApplicable`, e.g. a break, or a task-less/partial-logging-off abandon) is a no-op that returns the existing status unchanged.
- Core Data failing to load at launch (e.g. a corrupt store file) degrades to an in-memory store, then `NullSessionStore`, with a banner — the timer keeps working, history just doesn't persist.
- `updateSession(_:)` and `insertSession(_:)` are the same operation (`updateSession` just calls `insertSession`), since both are id-keyed upserts.

## Test coverage

- `Tests/FocusdoroCoreTests/CompletionOrchestratorTests.swift`, suites **"Completion orchestration"** and **"Abandoned time accounting"** — finish/abandon/complete flows, comment idempotency, retry semantics, Todoist-close failure handling.
- `Tests/FocusdoroCoreTests/SessionStoreTests.swift`, suites **"Session store"** and **"Null session store"** (the degraded fallback used when Core Data cannot load) — Core Data upsert/uniqueness, today-summary calendar-day boundaries, streak calculation, comment-retry queries.
