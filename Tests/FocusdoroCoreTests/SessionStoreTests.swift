import Foundation
import Testing
@testable import FocusdoroCore

@Suite("Session store")
struct SessionStoreTests {
    private let calendar = Fixture.calendar()

    private func record(
        id: UUID = UUID(),
        taskID: String = "task-1",
        started: String = "2026-08-29 09:00:00",
        ended: String? = "2026-08-29 09:25:00",
        elapsed: Int32 = 1500,
        kind: TimerPhase = .focus,
        status: SessionStatus = .completed,
        comment: CommentStatus = .posted
    ) -> SessionRecord {
        SessionRecord(
            id: id,
            taskID: taskID,
            taskTitleSnapshot: "Write the handoff doc",
            startedAt: Fixture.date(started),
            endedAt: ended.map { Fixture.date($0) },
            plannedDurationSeconds: 1500,
            elapsedDurationSeconds: elapsed,
            kind: kind,
            status: status,
            todoistCommentStatus: comment,
            createdAt: Fixture.date(started)
        )
    }

    @Test("Round-trips every attribute of a completed session")
    func roundTrip() throws {
        let store = try Fixture.store()
        let original = record()
        try store.insertSession(original)

        let loaded = try #require(try store.session(id: original.id))
        #expect(loaded == original)
    }

    @Test("Inserting the same session id twice updates rather than duplicating")
    func duplicateIDs() throws {
        let store = try Fixture.store()
        let id = UUID()
        try store.insertSession(record(id: id, elapsed: 1500))
        try store.insertSession(record(id: id, elapsed: 900))

        #expect(try store.recentSessions(limit: 10).count == 1)
        #expect(try store.session(id: id)?.elapsedDurationSeconds == 900)
    }

    @Test("Comment status transitions pending → posted with an id")
    func commentStatusTransition() throws {
        let store = try Fixture.store()
        let session = record(comment: .pending)
        try store.insertSession(session)

        try store.markCommentStatus(sessionID: session.id, status: .posted, commentID: "c-42")
        let loaded = try #require(try store.session(id: session.id))
        #expect(loaded.todoistCommentStatus == .posted)
        #expect(loaded.todoistCommentID == "c-42")
    }

    @Test("Marking an unknown session reports notFound")
    func markUnknownSession() throws {
        let store = try Fixture.store()
        let id = UUID()
        #expect(throws: SessionStoreError.notFound(id)) {
            try store.markCommentStatus(sessionID: id, status: .posted, commentID: nil)
        }
    }

    @Test("Pending and failed comments are surfaced for retry, posted ones are not")
    func retryQueue() throws {
        let store = try Fixture.store()
        let pending = record(id: UUID(), comment: .pending)
        let failed = record(id: UUID(), comment: .failed)
        let posted = record(id: UUID(), comment: .posted)
        try store.insertSession(pending)
        try store.insertSession(failed)
        try store.insertSession(posted)

        let queue = try store.sessionsNeedingCommentRetry()
        #expect(Set(queue.map(\.id)) == Set([pending.id, failed.id]))
    }

    // MARK: - Today summary

    @Test("Today summary separates completed focus time from stopped-session time")
    func todaySummary() throws {
        let store = try Fixture.store()
        try store.insertSession(record(id: UUID(), ended: "2026-08-29 09:25:00", elapsed: 1500))
        try store.insertSession(record(id: UUID(), ended: "2026-08-29 10:25:00", elapsed: 1200))
        // Excluded: abandoned, a break, and yesterday's session.
        try store.insertSession(record(id: UUID(), ended: "2026-08-29 11:00:00", elapsed: 400, status: .abandoned, comment: .notApplicable))
        try store.insertSession(record(id: UUID(), ended: "2026-08-29 11:30:00", elapsed: 300, kind: .shortBreak, comment: .notApplicable))
        try store.insertSession(record(id: UUID(), started: "2026-08-28 09:00:00", ended: "2026-08-28 09:25:00", elapsed: 1500))

        let summary = try store.todaySummary(now: Fixture.date("2026-08-29 18:00:00"), calendar: calendar)
        #expect(summary.completedFocusSessions == 2)
        #expect(summary.focusedSeconds == 2700)
        #expect(summary.focusedMinutes == 45)
        // The abandoned 400 s lands in the partial bucket, not in focused time.
        #expect(summary.partialSeconds == 400)
        #expect(summary.abandonedFocusSessions == 1)
        #expect(summary.investedSeconds == 3100)
        #expect(summary.investedMinutes == 51)
    }

    @Test("A session that ended just before midnight is not counted the next day")
    func dayBoundary() throws {
        let store = try Fixture.store()
        try store.insertSession(record(id: UUID(), started: "2026-08-28 23:30:00", ended: "2026-08-28 23:55:00"))
        let summary = try store.todaySummary(now: Fixture.date("2026-08-29 00:10:00"), calendar: calendar)
        #expect(summary.completedFocusSessions == 0)
        #expect(summary.focusedSeconds == 0)
    }

    @Test("Streak counts consecutive days ending today")
    func streakToday() throws {
        let store = try Fixture.store()
        for day in ["2026-08-27", "2026-08-28", "2026-08-29"] {
            try store.insertSession(record(id: UUID(), started: "\(day) 09:00:00", ended: "\(day) 09:25:00"))
        }
        let summary = try store.todaySummary(now: Fixture.date("2026-08-29 18:00:00"), calendar: calendar)
        #expect(summary.streakDays == 3)
    }

    @Test("A streak that ran through yesterday survives until today's first session")
    func streakYesterday() throws {
        let store = try Fixture.store()
        for day in ["2026-08-27", "2026-08-28"] {
            try store.insertSession(record(id: UUID(), started: "\(day) 09:00:00", ended: "\(day) 09:25:00"))
        }
        let summary = try store.todaySummary(now: Fixture.date("2026-08-29 08:00:00"), calendar: calendar)
        #expect(summary.streakDays == 2)
        #expect(summary.completedFocusSessions == 0)
    }

    @Test("A gap breaks the streak")
    func streakGap() throws {
        let store = try Fixture.store()
        for day in ["2026-08-25", "2026-08-29"] {
            try store.insertSession(record(id: UUID(), started: "\(day) 09:00:00", ended: "\(day) 09:25:00"))
        }
        let summary = try store.todaySummary(now: Fixture.date("2026-08-29 18:00:00"), calendar: calendar)
        #expect(summary.streakDays == 1)
    }

    @Test("An empty store reports zeros without throwing")
    func emptyStore() throws {
        let store = try Fixture.store()
        let summary = try store.todaySummary(now: Fixture.date("2026-08-29 18:00:00"), calendar: calendar)
        #expect(summary == TodaySummary())
        #expect(try store.recentSessions(limit: 5).isEmpty)
    }

    // MARK: - Recent sessions

    @Test("Recent sessions come back newest first and honour the limit")
    func recentSessions() throws {
        let store = try Fixture.store()
        for hour in 9...13 {
            try store.insertSession(
                record(id: UUID(), started: "2026-08-29 \(hour):00:00", ended: "2026-08-29 \(hour):25:00")
            )
        }
        let recent = try store.recentSessions(limit: 3)
        #expect(recent.count == 3)
        #expect(recent[0].endedAt == Fixture.date("2026-08-29 13:25:00"))
        #expect(recent[2].endedAt == Fixture.date("2026-08-29 11:25:00"))
    }

    @Test("An unfinished session is excluded from recent history")
    func excludesUnfinished() throws {
        let store = try Fixture.store()
        try store.insertSession(record(id: UUID(), ended: nil, status: .interrupted, comment: .notApplicable))
        #expect(try store.recentSessions(limit: 5).isEmpty)
    }

    @Test("Abandoned sessions are kept in history and reported as invested time")
    func abandonedKept() throws {
        let store = try Fixture.store()
        let abandoned = record(id: UUID(), elapsed: 320, status: .abandoned, comment: .notApplicable)
        try store.insertSession(abandoned)

        #expect(try store.recentSessions(limit: 5).count == 1)
        let summary = try store.todaySummary(now: Fixture.date("2026-08-29 18:00:00"), calendar: calendar)
        #expect(summary.focusedSeconds == 0)
        #expect(summary.completedFocusSessions == 0)
        #expect(summary.streakDays == 0)
        // The time invested is still reported, separately from completed focus time.
        #expect(summary.partialSeconds == 320)
        #expect(summary.abandonedFocusSessions == 1)
        #expect(summary.investedSeconds == 320)
    }

    @Test("The schema declares every attribute the spec lists")
    func schemaShape() {
        let model = SessionStore.makeModel()
        let entity = try! #require(model.entitiesByName["FocusSession"])
        let names = Set(entity.attributesByName.keys)
        #expect(names == [
            "id", "taskID", "taskTitleSnapshot", "startedAt", "endedAt",
            "plannedDurationSeconds", "elapsedDurationSeconds", "kind", "status",
            "todoistCommentStatus", "todoistCommentID", "createdAt",
            // Model version 2: the project snapshot behind the weekly breakdown.
            "projectID", "projectNameSnapshot",
        ])
        #expect(entity.attributesByName["projectID"]?.isOptional == true)
        #expect(entity.attributesByName["projectNameSnapshot"]?.isOptional == true)
        #expect(entity.attributesByName["endedAt"]?.isOptional == true)
        #expect(entity.attributesByName["todoistCommentID"]?.isOptional == true)
        #expect(entity.attributesByName["id"]?.isOptional == false)
        #expect(model.versionIdentifiers.contains(String(SessionStore.modelVersion)))
    }
}

// MARK: - NullSessionStore

/// Last-resort store used when Core Data itself fails to load (see
/// `AppLifecycleCoordinator.buildGraph`). Every method must be a harmless no-op so the
/// rest of the app can keep running with degraded history instead of crashing.
@Suite("Null session store")
struct NullSessionStoreTests {
    @Test("Writes silently succeed and reads report nothing, so the app never crashes on a degraded store")
    func actsAsAHarmlessSink() throws {
        let store = NullSessionStore()
        let record = SessionRecord(
            taskID: "task-1",
            taskTitleSnapshot: "Write the handoff doc",
            startedAt: Fixture.date("2026-08-29 09:00:00"),
            endedAt: Fixture.date("2026-08-29 09:25:00"),
            plannedDurationSeconds: 1500,
            elapsedDurationSeconds: 1500,
            kind: .focus,
            status: .completed,
            createdAt: Fixture.date("2026-08-29 09:00:00")
        )

        try store.insertSession(record)
        try store.updateSession(record)
        #expect(try store.session(id: record.id) == nil)
        try store.markCommentStatus(sessionID: record.id, status: .posted, commentID: "c-1")
        #expect(try store.recentSessions(limit: 10).isEmpty)
        #expect(try store.sessionsNeedingCommentRetry().isEmpty)
        #expect(try store.todaySummary(now: Fixture.date("2026-08-29 18:00:00"), calendar: Fixture.calendar()) == TodaySummary())
        #expect(try store.weeklySummary(now: Fixture.date("2026-08-29 18:00:00"), calendar: Fixture.calendar()) == WeeklySummary())
    }
}
