import Foundation
import Testing
@testable import FocusdoroCore

private func session(
    _ endedAt: String,
    minutes: Int,
    status: SessionStatus = .completed,
    projectID: String? = "p1",
    projectName: String? = "Focusdoro",
    kind: TimerPhase = .focus
) -> SessionRecord {
    let ended = Fixture.date(endedAt)
    return SessionRecord(
        id: UUID(),
        taskID: "t-\(endedAt)",
        taskTitleSnapshot: "Task",
        projectID: projectID,
        projectNameSnapshot: projectName,
        startedAt: ended.addingTimeInterval(TimeInterval(-minutes * 60)),
        endedAt: ended,
        plannedDurationSeconds: Int32(minutes * 60),
        elapsedDurationSeconds: Int32(minutes * 60),
        kind: kind,
        status: status,
        createdAt: ended
    )
}

@Suite("Weekly aggregation")
struct WeeklyAggregationTests {
    // 2026-08-24 is a Monday; the week runs to Sunday 2026-08-30.
    private let calendar = Fixture.calendar()
    private var weekStart: Date { Fixture.date("2026-08-24 00:00:00") }

    @Test("A week always has seven days, even when most are empty")
    func sevenDays() {
        let summary = WeeklyStats.summarize(
            sessions: [session("2026-08-26 11:00:00", minutes: 25)],
            weekStart: weekStart,
            calendar: calendar
        )
        #expect(summary.days.count == 7)
        #expect(summary.days.first?.date == weekStart)
        #expect(summary.investedSeconds == 25 * 60)
        #expect(summary.completedFocusSessions == 1)
    }

    @Test("Sessions land on the day they ended")
    func bucketing() {
        let summary = WeeklyStats.summarize(
            sessions: [
                session("2026-08-24 09:00:00", minutes: 25),
                session("2026-08-24 15:00:00", minutes: 50),
                session("2026-08-28 09:00:00", minutes: 25),
            ],
            weekStart: weekStart,
            calendar: calendar
        )
        #expect(summary.days[0].minutes == 75)
        #expect(summary.days[0].completedSessions == 2)
        #expect(summary.days[4].minutes == 25)
        #expect(summary.days[1].seconds == 0)
        #expect(summary.busiestDay?.date == summary.days[0].date)
    }

    @Test("Anything outside the week is ignored")
    func outsideTheWeek() {
        let summary = WeeklyStats.summarize(
            sessions: [
                session("2026-08-23 20:00:00", minutes: 60),
                session("2026-08-31 08:00:00", minutes: 60),
                session("2026-08-26 08:00:00", minutes: 10),
            ],
            weekStart: weekStart,
            calendar: calendar
        )
        // Guards against the fetch predicate and this rollup disagreeing about bounds.
        #expect(summary.investedSeconds == 10 * 60)
    }

    @Test("Stopped time counts as invested but never as a completed session")
    func stoppedTime() {
        let summary = WeeklyStats.summarize(
            sessions: [
                session("2026-08-25 10:00:00", minutes: 25),
                session("2026-08-25 12:00:00", minutes: 7, status: .abandoned),
            ],
            weekStart: weekStart,
            calendar: calendar
        )
        #expect(summary.days[1].minutes == 32)
        #expect(summary.days[1].completedSessions == 1)
        #expect(summary.completedFocusSessions == 1)
        #expect(summary.projects.first?.completedSessions == 1)
    }

    @Test("Breaks never reach the focus totals")
    func breaksExcluded() {
        let summary = WeeklyStats.summarize(
            sessions: [
                session("2026-08-25 10:00:00", minutes: 25),
                session("2026-08-25 10:30:00", minutes: 5, kind: .shortBreak),
            ],
            weekStart: weekStart,
            calendar: calendar
        )
        #expect(summary.investedSeconds == 25 * 60)
    }

    @Test("Projects rank by time, with the name breaking ties")
    func projectRanking() {
        let summary = WeeklyStats.summarize(
            sessions: [
                session("2026-08-25 10:00:00", minutes: 25, projectID: "p1", projectName: "Focusdoro"),
                session("2026-08-26 10:00:00", minutes: 50, projectID: "p2", projectName: "Client work"),
                session("2026-08-27 10:00:00", minutes: 25, projectID: "p3", projectName: "Admin"),
            ],
            weekStart: weekStart,
            calendar: calendar
        )
        #expect(summary.projects.map(\.name) == ["Client work", "Admin", "Focusdoro"])
        #expect(summary.projects.first?.minutes == 50)
    }

    @Test("Sessions with no project snapshot still show up")
    func unassigned() {
        let summary = WeeklyStats.summarize(
            sessions: [
                session("2026-08-25 10:00:00", minutes: 30, projectID: nil, projectName: nil),
                session("2026-08-25 11:00:00", minutes: 10, projectID: "p9", projectName: nil),
            ],
            weekStart: weekStart,
            calendar: calendar
        )
        // Records written before the project snapshot existed must not vanish from the
        // breakdown; they land in their own rows instead.
        #expect(summary.projects.count == 2)
        #expect(summary.projects.first?.name == "No project")
        #expect(summary.projects.first?.projectID == nil)
        #expect(summary.projects.last?.name == "Other project")
        #expect(summary.projects.last?.projectID == "p9")
    }

    @Test("A renamed project keeps its newest name")
    func renamedProject() {
        let summary = WeeklyStats.summarize(
            sessions: [
                session("2026-08-25 10:00:00", minutes: 10, projectID: "p1", projectName: "Old name"),
                session("2026-08-26 10:00:00", minutes: 10, projectID: "p1", projectName: "New name"),
            ],
            weekStart: weekStart,
            calendar: calendar
        )
        #expect(summary.projects.count == 1)
        #expect(summary.projects.first?.name == "New name")
        #expect(summary.projects.first?.minutes == 20)
    }

    @Test("The average covers the days that had focus, not all seven")
    func average() {
        let summary = WeeklyStats.summarize(
            sessions: [
                session("2026-08-25 10:00:00", minutes: 30),
                session("2026-08-26 10:00:00", minutes: 60),
            ],
            weekStart: weekStart,
            calendar: calendar
        )
        #expect(summary.averageActiveDayMinutes == 45)
        #expect(WeeklySummary().averageActiveDayMinutes == 0)
    }
}

@Suite("Weekly chart")
struct WeeklyChartTests {
    private let calendar = Fixture.calendar()
    private var weekStart: Date { Fixture.date("2026-08-24 00:00:00") }

    @Test("Bars scale against the busiest day")
    func scaling() {
        let summary = WeeklyStats.summarize(
            sessions: [
                session("2026-08-24 10:00:00", minutes: 60),
                session("2026-08-25 10:00:00", minutes: 30),
            ],
            weekStart: weekStart,
            calendar: calendar
        )
        let heights = WeeklyStats.barHeights(for: summary, maxHeight: 40)
        #expect(heights.count == 7)
        #expect(heights[0] == 40)
        #expect(heights[1] == 20)
        #expect(heights[2] == 0)
    }

    @Test("A tiny day still draws a visible stub")
    func minimumStub() {
        let summary = WeeklyStats.summarize(
            sessions: [
                session("2026-08-24 10:00:00", minutes: 600),
                session("2026-08-25 10:00:00", minutes: 1),
            ],
            weekStart: weekStart,
            calendar: calendar
        )
        let heights = WeeklyStats.barHeights(for: summary, maxHeight: 40)
        // Rounding a one-minute day to nothing would read as "I did not focus at all".
        #expect(heights[1] >= 3)
    }

    @Test("An empty week draws no bars at all")
    func emptyWeek() {
        let summary = WeeklyStats.summarize(sessions: [], weekStart: weekStart, calendar: calendar)
        #expect(summary.isEmpty)
        #expect(WeeklyStats.barHeights(for: summary, maxHeight: 40).allSatisfy { $0 == 0 })
    }

    @Test("Weekday initials follow the week's own order")
    func initials() {
        let summary = WeeklyStats.summarize(sessions: [], weekStart: weekStart, calendar: calendar)
        let initials = WeeklyStats.dayInitials(for: summary, calendar: calendar)
        #expect(initials.count == 7)
        #expect(initials.allSatisfy { !$0.isEmpty })
    }
}

@Suite("Weekly summary from the store")
struct WeeklyStoreTests {
    @Test("The store reports the calendar week the date falls in")
    func weekFromStore() throws {
        let store = try Fixture.store()
        let calendar = Fixture.calendar()
        try store.insertSession(session("2026-08-25 10:00:00", minutes: 25))
        try store.insertSession(session("2026-08-27 10:00:00", minutes: 15, status: .abandoned))
        // Last week: must not leak into this one.
        try store.insertSession(session("2026-08-20 10:00:00", minutes: 90))

        let summary = try store.weeklySummary(now: Fixture.date("2026-08-29 18:00:00"), calendar: calendar)
        #expect(summary.investedSeconds == 40 * 60)
        #expect(summary.completedFocusSessions == 1)
        #expect(summary.projects.first?.name == "Focusdoro")
    }

    @Test("The project snapshot round-trips through Core Data")
    func projectRoundTrip() throws {
        let store = try Fixture.store()
        let record = session("2026-08-25 10:00:00", minutes: 25, projectID: "p7", projectName: "Deep work")
        try store.insertSession(record)

        let read = try #require(try store.session(id: record.id))
        #expect(read.projectID == "p7")
        #expect(read.projectNameSnapshot == "Deep work")
    }

    @Test("A session written without a project still reads back")
    func missingProject() throws {
        let store = try Fixture.store()
        let record = session("2026-08-25 10:00:00", minutes: 25, projectID: nil, projectName: nil)
        try store.insertSession(record)

        let read = try #require(try store.session(id: record.id))
        #expect(read.projectID == nil)
        #expect(read.projectNameSnapshot == nil)
    }
}

@Suite("Weekly stats in the app model")
@MainActor
struct WeeklyModelTests {
    /// End to end: a session the timer finished has to appear in the week view with the
    /// project it ran against, with no network round trip.
    @Test("A finished session lands in the week with its project")
    func finishedSessionAppears() async throws {
        let clock = MutableDateProvider(now: Fixture.date("2026-08-29 14:00:00"))
        let todoist = FakeTodoist()
        let tokens = InMemoryTokenStore()
        try tokens.saveToken("test-token")
        let task = Fixture.task("t1", "Ship CI", due: "2026-08-29", projectID: "p1")
        await todoist.setTasks([task])
        await todoist.setProjects([TodoistProject(id: "p1", name: "Focusdoro")])

        let preferences = InMemoryPreferencesStore()
        var prefs = preferences.preferences
        prefs.focusDurationSeconds = 60
        preferences.preferences = prefs

        let store = try Fixture.store()
        let sync = TodoistSync(client: todoist, tokenStore: tokens, clock: clock, calendar: Fixture.calendar())
        let model = AppModel(
            sync: sync,
            engine: TimerEngine(clock: clock, persistence: InMemoryTimerStateStore(), preferences: preferences),
            orchestrator: CompletionOrchestrator(store: store, todoist: todoist, clock: clock),
            store: store,
            preferencesStore: preferences,
            notifications: PreviewNotifications(),
            clock: clock,
            calendar: Fixture.calendar()
        )
        await model.start()
        await model.select(task: task)
        await model.startFocus()
        clock.advance(by: 61)
        await model.engine.tick()

        try await waitUntil("the week view picks up the finished session") {
            !model.weeklySummary.isEmpty
        }
        #expect(model.weeklySummary.projects.first?.name == "Focusdoro")
        #expect(model.weeklySummary.completedFocusSessions == 1)
        model.shutdown()
    }
}
