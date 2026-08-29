# Task picker

## What it does

Turns `TodoistSync`'s cached task list into what the popover's task picker shows: grouped/sorted sections, a filter, and ranked search. All of the logic is in two pure enums so it's testable with no view and no network — `TaskFilter` (grouping by due date, search ranking) and `TaskOrganizer` (sectioning by the user's chosen sort order, filter application). `TaskPickerView` (`Sources/FocusdoroCore/Views/TaskPickerView.swift`) is the dumb renderer on top.

## Rules it upholds

- **Grouping is local-calendar-aware.** `TaskFilter.group` buckets each task into `overdue`/`today`/`upcoming`/`undated` by comparing `due.date`'s calendar day (`calendar.startOfDay`) against `today`, not by naive UTC-string comparison. A timed `due.datetime` is converted to the instant it represents, then reduced to a local day; an all-day `due.date` (`YYYY-MM-DD`) is parsed as a local calendar day, not a UTC instant. A floating datetime (no trailing `Z`/offset) is treated as a local wall-clock time in the task's declared timezone, falling back to `.current`.
- **Search is ranked, not a plain substring match.** `TaskFilter.matchScore` scores per field — title (`content`) weighted ×4, labels ×2, description ×1 — and per match quality within a field: whole-word match = 3, word-prefix = 2, bare substring = 1. This exists because a flat substring match on a short query like "IT" buries the obvious task ("Add IT bank account") under every task containing "ed**it**" or "w**it**h". Ties fall back to the caller's original order.
- **Search and the picker's filter compose, they don't replace each other.** `TodoistSync.searchResults` computes `TaskOrganizer.apply(filter, to: TaskFilter.search(query, in: allTasks), calendar:)` — search runs over every active task first, then the active project/priority/undated filter narrows that result further. A task matching the search text can still be excluded by an active filter; there is no "search ignores the filter" mode.
- **Filtering.** `TaskOrganizer.apply(_:to:calendar:)`: a `projectID` filter is exact-match; `minimumPriority` excludes anything below it (`TaskPriority(wireValue:).rawValue < criteria.minimumPriority.rawValue`); `hidesUndated` drops any task without a resolvable due day.
- **`TaskFilterCriteria.none`** (`projectID: nil, minimumPriority: .p4, hidesUndated: false`) is the inactive filter — `.p4` is Todoist's lowest/default priority, so "minimum P4" means "show everything."
- **Sort orders each build their own section shape**, not just a flat re-sort: `.dueDate` reuses the four `TaskFilter.group` buckets; `.priority` produces one section per priority level, highest first, skipping empty levels, with "No priority" as the label for `.p4`; `.project` groups by project (Inbox first, then alphabetical `localizedStandardCompare`), with an "Other" section for tasks whose project id isn't in the known project list; `.name` is a single flat alphabetical section.

## Key types / files

- `Sources/FocusdoroCore/Services/TaskFilter.swift` — `group(tasks:now:calendar:)`, `search(_:in:)`, `matchScore`, date parsing helpers (`startOfDueDay`, `parseDateOnly`, `parseDateTime`).
- `Sources/FocusdoroCore/Services/TaskOrganizer.swift` — `sections(tasks:projects:criteria:sort:now:calendar:)`, `apply(_:to:calendar:)`, `TaskSortOrder`, `TaskFilterCriteria`, `TaskSection`.
- `Sources/FocusdoroCore/Views/TaskPickerView.swift` — renders sections/search/filter menu; has no filtering logic of its own.
- `Sources/FocusdoroCore/Services/TodoistSync.swift` — `searchResults`, `sections`, `sortOrder`/`filter` (persisted via `AppModel.taskSortOrder`/`taskFilter` write-through to `AppPreferences`).

## Edge cases

- A recurring task's `due` always describes only its next occurrence, so the same single-occurrence grouping rule applies without special-casing recurrence.
- `due.date` that is itself an RFC3339 timestamp (some API responses put a full timestamp there instead of a bare date) is handled by `parseDateOnly`'s fallback to `parseDateTime`.
- Empty/whitespace-only search query returns the unfiltered task list unchanged (`TaskFilter.search` trims and short-circuits).
- A task whose `projectID` isn't in the fetched `projects` list still renders, under "Other" in project sort, rather than being dropped silently.
- `ScrollView` in `TaskPickerView` needs both `minHeight` and `maxHeight` (see the `CLAUDE.md` gotcha) — it has no intrinsic height and a long or short section list must not blow out the popover.

## Test coverage

- `Tests/FocusdoroCoreTests/TaskOrganizerTests.swift`, suite **"Task sorting and filtering"** — section building per sort order, filter application.
- `Tests/FocusdoroCoreTests/TaskFilteringTests.swift`, suite **"Task filtering and search"** — due-date grouping, timezone/floating-datetime parsing, search ranking.
