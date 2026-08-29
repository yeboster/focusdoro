import Foundation
import Testing
@testable import FocusdoroCore

@Suite("Task filtering and search")
struct TaskFilteringTests {
    private let calendar = Fixture.calendar()
    private let now = Fixture.date("2026-08-29 14:30:00")

    @Test("Today, overdue, upcoming, and undated land in the right groups")
    func grouping() {
        let tasks = [
            Fixture.task("1", "Today task", due: "2026-08-29"),
            Fixture.task("2", "Yesterday task", due: "2026-08-28"),
            Fixture.task("3", "Last month task", due: "2026-07-15"),
            Fixture.task("4", "Tomorrow task", due: "2026-08-30"),
            Fixture.task("5", "No date task"),
        ]

        let groups = TaskFilter.group(tasks: tasks, now: now, calendar: calendar)
        #expect(groups.today.map(\.id) == ["1"])
        // Overdue is sorted oldest first.
        #expect(groups.overdue.map(\.id) == ["3", "2"])
        #expect(groups.upcoming.map(\.id) == ["4"])
        #expect(groups.undated.map(\.id) == ["5"])
    }

    @Test("A timed task earlier today is still today, not overdue")
    func timedTaskEarlierToday() {
        let task = Fixture.task("1", "Standup", due: "2026-08-29", datetime: "2026-08-29T09:00:00Z")
        let groups = TaskFilter.group(tasks: [task], now: now, calendar: calendar)
        #expect(groups.today.map(\.id) == ["1"])
        #expect(groups.overdue.isEmpty)
    }

    @Test("A recurring task is grouped by its next occurrence")
    func recurringTask() {
        let due = TodoistDue(date: "2026-08-29", string: "every day", isRecurring: true)
        let task = TodoistTask(id: "r1", content: "Daily review", due: due)
        let groups = TaskFilter.group(tasks: [task], now: now, calendar: calendar)
        #expect(groups.today.map(\.id) == ["r1"])
    }

    @Test("Day boundaries follow the user's local time zone")
    func timeZoneBoundaries() {
        // 23:30 Lisbon on the 29th is already the 30th in UTC+2.
        let lateNight = Fixture.date("2026-08-29 23:30:00")
        let task = Fixture.task("1", "Late task", due: "2026-08-29")

        let lisbon = TaskFilter.group(tasks: [task], now: lateNight, calendar: Fixture.calendar("Europe/Lisbon"))
        #expect(lisbon.today.map(\.id) == ["1"])

        var berlinCalendar = Calendar(identifier: .gregorian)
        berlinCalendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let berlin = TaskFilter.group(tasks: [task], now: lateNight, calendar: berlinCalendar)
        // Same instant, but the local day has already rolled over.
        #expect(berlin.overdue.map(\.id) == ["1"])
    }

    @Test("A midnight-boundary due date is today, not overdue")
    func midnightBoundary() {
        let justAfterMidnight = Fixture.date("2026-08-29 00:00:01")
        let task = Fixture.task("1", "Midnight task", due: "2026-08-29")
        let groups = TaskFilter.group(tasks: [task], now: justAfterMidnight, calendar: calendar)
        #expect(groups.today.map(\.id) == ["1"])
    }

    @Test("Higher-priority tasks sort first within the same due date")
    func prioritySorting() {
        let tasks = [
            Fixture.task("low", "Low", due: "2026-08-29", priority: 1),
            Fixture.task("high", "High", due: "2026-08-29", priority: 4),
        ]
        let groups = TaskFilter.group(tasks: tasks, now: now, calendar: calendar)
        #expect(groups.today.map(\.id) == ["high", "low"])
    }

    @Test("An unparseable due date falls back to undated instead of vanishing")
    func unparseableDue() {
        let task = TodoistTask(id: "x", content: "Broken", due: TodoistDue(date: "not-a-date"))
        let groups = TaskFilter.group(tasks: [task], now: now, calendar: calendar)
        #expect(groups.undated.map(\.id) == ["x"])
    }

    // MARK: - Search

    @Test("Search spans every active task regardless of due grouping")
    func searchAcrossAll() {
        let tasks = [
            Fixture.task("1", "Write the spec", due: "2026-08-29"),
            Fixture.task("2", "Write the plan", due: "2026-12-01"),
            Fixture.task("3", "Buy milk"),
        ]
        #expect(TaskFilter.search("write", in: tasks).map(\.id) == ["1", "2"])
    }

    @Test("Search is case and diacritic insensitive")
    func searchInsensitive() {
        let tasks = [Fixture.task("1", "Revisão do relatório")]
        #expect(TaskFilter.search("revisao", in: tasks).map(\.id) == ["1"])
        #expect(TaskFilter.search("RELATORIO", in: tasks).map(\.id) == ["1"])
    }

    @Test("Search also matches labels")
    func searchLabels() {
        let tasks = [Fixture.task("1", "Something", labels: ["deepwork"])]
        #expect(TaskFilter.search("deep", in: tasks).map(\.id) == ["1"])
    }

    @Test("An exact word beats an incidental substring")
    func searchRanksWholeWordsFirst() {
        let tasks = [
            Fixture.task("1", "Edit the onboarding copy"),
            Fixture.task("2", "Commit the migration"),
            Fixture.task("3", "Add IT bank account"),
        ]
        // "IT" appears inside "Edit" and "Commit", but only task 3 is *about* IT.
        #expect(TaskFilter.search("IT", in: tasks).first?.id == "3")
        #expect(TaskFilter.search("it", in: tasks).map(\.id) == ["3", "1", "2"])
    }

    @Test("A word prefix outranks a match buried mid-word")
    func searchRanksPrefixesAboveInfixes() {
        let tasks = [
            Fixture.task("1", "Reset the pipeline"),
            Fixture.task("2", "Banking questions"),
            Fixture.task("3", "Add IT bank account"),
        ]
        // Whole word "bank" first, then the prefix in "Banking".
        #expect(TaskFilter.search("bank", in: tasks).map(\.id) == ["3", "2"])
    }

    @Test("A hit in the title outranks the same hit in a label or description")
    func searchWeightsTheTitleHighest() {
        let tasks = [
            Fixture.task("1", "Weekly review", labels: ["bank"]),
            Fixture.task("2", "Something else", description: "call the bank"),
            Fixture.task("3", "Bank transfer"),
        ]
        #expect(TaskFilter.search("bank", in: tasks).map(\.id) == ["3", "1", "2"])
    }

    @Test("Equal-scoring matches keep the order Todoist returned")
    func searchIsStable() {
        let tasks = [
            Fixture.task("1", "Bank one"),
            Fixture.task("2", "Bank two"),
            Fixture.task("3", "Bank three"),
        ]
        #expect(TaskFilter.search("bank", in: tasks).map(\.id) == ["1", "2", "3"])
    }

    @Test("An empty query returns everything")
    func emptyQuery() {
        let tasks = [Fixture.task("1", "A"), Fixture.task("2", "B")]
        #expect(TaskFilter.search("   ", in: tasks).count == 2)
    }

    @Test("A query with no matches returns nothing")
    func noMatches() {
        #expect(TaskFilter.search("zzz", in: [Fixture.task("1", "A")]).isEmpty)
    }
}
