# Weekly stats

Under the today stats, the popover shows the current calendar week: a seven-bar chart and
the projects the week went into. Like every other number in the history view, it comes
from the local Core Data store with no network round trip.

## Pieces

| Type | File | Role |
| --- | --- | --- |
| `DayTotal` / `ProjectTotal` / `WeeklySummary` | `Models/TimerModels.swift` | Value types the view renders |
| `WeeklyStats` | `Services/WeeklyStats.swift` | Pure bucketing, project rollup, bar heights, weekday initials |
| `SessionStore.weeklySummary(now:calendar:)` | `Services/SessionStore.swift` | Fetches the week and hands it to `WeeklyStats` |
| `AppModel.weeklySummary` | `Services/AppModel.swift` | Refreshed by `reloadHistory()`, alongside the today stats |
| `HistoryView.weekSection` | `Views/HistoryView.swift` | Chart, total line, top three projects |

## The project snapshot

Per-project time needs the project the session ran against, and that cannot be looked up
later: the task may be closed, moved, or the app offline. So the project is captured at
selection time and carried all the way through:

`TodoistTask.selection(projectName:)` → `SelectedTask.projectID/projectName` →
`PersistedTimerState` → `CompletionOrchestrator` → `SessionRecord.projectID` /
`projectNameSnapshot` → the `FocusSession` entity.

Both Core Data attributes are **optional**, and `SessionStore.modelVersion` is now `2`.
The store already opens with `shouldMigrateStoreAutomatically` and
`shouldInferMappingModelAutomatically`, so an existing SQLite store gains two null columns
by lightweight migration with no mapping model. `SelectedTask`'s two new fields are
optional for the matching reason on the `UserDefaults` side: the synthesized decoder uses
`decodeIfPresent`, so a timer state persisted by an older build still restores.

## Aggregation rules

- **The week is the user's calendar week** (`Calendar.dateInterval(of: .weekOfYear)`), so
  it honours their first weekday. `days` always holds seven entries, oldest first, so the
  chart keeps its shape on a Monday.
- **Invested time, not just completed time**: a day's seconds are completed *plus*
  stopped focus sessions, which matches what "Today" reports. Session *counts* stay
  completed-only — stopped time was invested, but it is not a finished session.
- **Breaks never enter the totals.**
- **Sessions outside the week are ignored by the rollup as well as the fetch**, so the
  predicate and the aggregation cannot silently disagree.
- **Sessions with no project snapshot still appear** — as "No project" when there was no
  project at all, "Other project" when only the id survived — so history written before
  this feature does not vanish from the breakdown.
- **Projects rank by time, ties broken by name**, so the order does not flicker between
  reloads. A renamed project keeps its newest name.
- **`averageActiveDayMinutes` averages the days that had focus**, not all seven: dividing
  by seven makes every week look idle.

## Chart

`WeeklyStats.barHeights(for:maxHeight:)` scales against the busiest day and gives any
non-zero day a 3 pt minimum stub, so a one-minute day never renders as nothing. The
busiest bar is drawn in the accent colour, the rest at 45 % of it. `dayInitials` reads
`veryShortStandaloneWeekdaySymbols` in the week's own order.

## Tests

`Tests/FocusdoroCoreTests/WeeklyStatsTests.swift` — bucketing, week bounds, stopped time,
breaks, ranking and ties, renamed and missing projects, averages, bar scaling and the
minimum stub, empty weeks, weekday initials, the store-level fetch, the Core Data
round-trip of the project snapshot, and an end-to-end check that a finished session shows
up in the week view with its project name.
