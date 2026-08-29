import Foundation
import Testing
@testable import FocusdoroCore

@Suite("Completion orchestration")
struct CompletionOrchestratorTests {
    private let now = Fixture.date("2026-08-29 14:30:00")

    private func makeOrchestrator(
        store: SessionStoring,
        todoist: FakeTodoist
    ) -> CompletionOrchestrator {
        CompletionOrchestrator(
            store: store,
            todoist: todoist,
            clock: MutableDateProvider(now: now),
            timeZone: TimeZone(identifier: "Europe/Lisbon")!
        )
    }

    // MARK: - Comment format

    @Test("Comment matches the exact format the spec prescribes")
    func commentFormat() {
        let text = CommentFormatter.comment(
            elapsedSeconds: 1500,
            at: now,
            timeZone: TimeZone(identifier: "Europe/Lisbon")!
        )
        #expect(text == "Focusdoro: 25 min focused on this task (2026-08-29 14:30).")
    }

    @Test("Elapsed time rounds to the nearest minute with a floor of one")
    func minuteRounding() {
        #expect(CommentFormatter.minutes(forElapsedSeconds: 0) == 0)
        #expect(CommentFormatter.minutes(forElapsedSeconds: 1) == 1)
        #expect(CommentFormatter.minutes(forElapsedSeconds: 29) == 1)
        #expect(CommentFormatter.minutes(forElapsedSeconds: 30) == 1)
        #expect(CommentFormatter.minutes(forElapsedSeconds: 89) == 1)
        #expect(CommentFormatter.minutes(forElapsedSeconds: 90) == 2)
        #expect(CommentFormatter.minutes(forElapsedSeconds: 1500) == 25)
    }

    // MARK: - Timer completion

    @Test("Timer completion persists the session and posts exactly one comment")
    func timerCompletion() async throws {
        let store = try Fixture.store()
        let todoist = FakeTodoist()
        let orchestrator = makeOrchestrator(store: store, todoist: todoist)
        let sessionID = UUID()

        let outcome = await orchestrator.finishFocus(
            sessionID: sessionID, task: Fixture.task,
            elapsedSeconds: 1500, plannedSeconds: 1500, reason: .timerCompleted
        )

        #expect(outcome.commentStatus == .posted)
        #expect(await todoist.commentCount == 1)
        #expect(await todoist.closeCount == 0)
        #expect(await todoist.commentContents.first == "Focusdoro: 25 min focused on this task (2026-08-29 14:30).")

        let saved = try #require(try store.session(id: sessionID))
        #expect(saved.status == .completed)
        #expect(saved.todoistCommentStatus == .posted)
        #expect(saved.todoistCommentID == "comment-1")
        #expect(saved.elapsedDurationSeconds == 1500)
    }

    @Test("A duplicate completion event does not post a second comment")
    func duplicateEventIsIdempotent() async throws {
        let store = try Fixture.store()
        let todoist = FakeTodoist()
        let orchestrator = makeOrchestrator(store: store, todoist: todoist)
        let sessionID = UUID()

        for _ in 0..<3 {
            _ = await orchestrator.finishFocus(
                sessionID: sessionID, task: Fixture.task,
                elapsedSeconds: 1500, plannedSeconds: 1500, reason: .timerCompleted
            )
        }

        #expect(await todoist.commentCount == 1)
        #expect(try store.recentSessions(limit: 10).count == 1)
    }

    // MARK: - Complete task

    @Test("Complete task closes the Todoist task and posts one comment")
    func completeTaskClosesAndComments() async throws {
        let store = try Fixture.store()
        let todoist = FakeTodoist()
        let orchestrator = makeOrchestrator(store: store, todoist: todoist)
        let sessionID = UUID()

        let outcome = await orchestrator.finishFocus(
            sessionID: sessionID, task: Fixture.task,
            elapsedSeconds: 700, plannedSeconds: 1500, reason: .taskCompleted
        )

        #expect(outcome.taskClosed)
        #expect(outcome.commentStatus == .posted)
        #expect(await todoist.closedTaskIDs == ["task-1"])
        #expect(await todoist.commentCount == 1)
        // Rounded from 700 s.
        #expect(await todoist.commentContents.first?.contains("12 min") == true)
    }

    @Test("A close failure keeps the local session and reports the error")
    func closeFailure() async throws {
        let store = try Fixture.store()
        let todoist = FakeTodoist()
        await todoist.setCloseError(.server(status: 500))
        let orchestrator = makeOrchestrator(store: store, todoist: todoist)
        let sessionID = UUID()

        let outcome = await orchestrator.finishFocus(
            sessionID: sessionID, task: Fixture.task,
            elapsedSeconds: 900, plannedSeconds: 1500, reason: .taskCompleted
        )

        #expect(!outcome.taskClosed)
        #expect(outcome.error == .server(status: 500))
        let saved = try #require(try store.session(id: sessionID))
        #expect(saved.status == .completed)
        #expect(saved.elapsedDurationSeconds == 900)
    }

    @Test("Close succeeding but comment failing leaves the session completed and retryable")
    func commentFailureAfterClose() async throws {
        let store = try Fixture.store()
        let todoist = FakeTodoist()
        await todoist.setCommentError(.transport("offline"))
        let orchestrator = makeOrchestrator(store: store, todoist: todoist)
        let sessionID = UUID()

        let outcome = await orchestrator.finishFocus(
            sessionID: sessionID, task: Fixture.task,
            elapsedSeconds: 1500, plannedSeconds: 1500, reason: .taskCompleted
        )

        #expect(outcome.taskClosed)
        #expect(outcome.commentStatus == .failed)
        let saved = try #require(try store.session(id: sessionID))
        #expect(saved.status == .completed)
        #expect(saved.todoistCommentStatus == .failed)
        // The Todoist completion is never reversed.
        #expect(await todoist.closedTaskIDs == ["task-1"])
    }

    // MARK: - Abandon

    @Test("Abandon persists locally and sends nothing to Todoist")
    func abandonSendsNothing() async throws {
        let store = try Fixture.store()
        let todoist = FakeTodoist()
        let orchestrator = makeOrchestrator(store: store, todoist: todoist)
        let sessionID = UUID()

        let outcome = await orchestrator.finishFocus(
            sessionID: sessionID, task: Fixture.task,
            elapsedSeconds: 240, plannedSeconds: 1500, reason: .abandoned
        )

        #expect(outcome.commentStatus == .notApplicable)
        #expect(!outcome.taskClosed)
        #expect(await todoist.commentCount == 0)
        #expect(await todoist.closeCount == 0)

        let saved = try #require(try store.session(id: sessionID))
        #expect(saved.status == .abandoned)
        #expect(saved.todoistCommentStatus == .notApplicable)
        #expect(saved.elapsedDurationSeconds == 240)
    }

    // MARK: - Retry

    @Test("Retry posts the comment for a previously failed session, once")
    func retrySucceeds() async throws {
        let store = try Fixture.store()
        let todoist = FakeTodoist()
        await todoist.setCommentError(.transport("offline"))
        let orchestrator = makeOrchestrator(store: store, todoist: todoist)
        let sessionID = UUID()

        _ = await orchestrator.finishFocus(
            sessionID: sessionID, task: Fixture.task,
            elapsedSeconds: 1500, plannedSeconds: 1500, reason: .timerCompleted
        )
        #expect(try store.session(id: sessionID)?.todoistCommentStatus == .failed)

        await todoist.setCommentError(nil)
        let retried = await orchestrator.retryComment(sessionID: sessionID)
        #expect(retried.commentStatus == .posted)
        #expect(try store.session(id: sessionID)?.todoistCommentStatus == .posted)

        // A second retry is a no-op once posted: exactly one comment ever lands, and the
        // only extra call Todoist saw was the attempt that failed offline.
        _ = await orchestrator.retryComment(sessionID: sessionID)
        #expect(await todoist.commentCount == 1)
        #expect(await todoist.commentAttempts == 2)
    }

    @Test("Retry uses the recorded elapsed time, not the retry moment")
    func retryUsesRecordedDuration() async throws {
        let store = try Fixture.store()
        let todoist = FakeTodoist()
        await todoist.setCommentError(.transport("offline"))
        let orchestrator = makeOrchestrator(store: store, todoist: todoist)
        let sessionID = UUID()

        _ = await orchestrator.finishFocus(
            sessionID: sessionID, task: Fixture.task,
            elapsedSeconds: 300, plannedSeconds: 1500, reason: .timerCompleted
        )
        await todoist.setCommentError(nil)
        _ = await orchestrator.retryComment(sessionID: sessionID)

        #expect(await todoist.commentContents.last?.contains("5 min") == true)
    }

    @Test("Retrying every pending comment drains the queue")
    func retryPendingQueue() async throws {
        let store = try Fixture.store()
        let todoist = FakeTodoist()
        await todoist.setCommentError(.transport("offline"))
        let orchestrator = makeOrchestrator(store: store, todoist: todoist)

        let ids = [UUID(), UUID()]
        for id in ids {
            _ = await orchestrator.finishFocus(
                sessionID: id, task: Fixture.task,
                elapsedSeconds: 600, plannedSeconds: 1500, reason: .timerCompleted
            )
        }
        #expect(try store.sessionsNeedingCommentRetry().count == 2)

        await todoist.setCommentError(nil)
        await orchestrator.retryPendingComments()
        #expect(try store.sessionsNeedingCommentRetry().isEmpty)
    }

    @Test("Retrying an abandoned session posts nothing")
    func retryIgnoresAbandoned() async throws {
        let store = try Fixture.store()
        let todoist = FakeTodoist()
        let orchestrator = makeOrchestrator(store: store, todoist: todoist)
        let sessionID = UUID()

        _ = await orchestrator.finishFocus(
            sessionID: sessionID, task: Fixture.task,
            elapsedSeconds: 100, plannedSeconds: 1500, reason: .abandoned
        )
        _ = await orchestrator.retryComment(sessionID: sessionID)
        #expect(await todoist.commentCount == 0)
    }

    @Test("Breaks are recorded locally and never commented")
    func breakRecording() async throws {
        let store = try Fixture.store()
        let todoist = FakeTodoist()
        let orchestrator = makeOrchestrator(store: store, todoist: todoist)

        await orchestrator.recordBreak(
            sessionID: UUID(), phase: .shortBreak,
            plannedSeconds: 300, elapsedSeconds: 300,
            startedAt: Fixture.date("2026-08-29 14:25:00")
        )

        let recent = try store.recentSessions(limit: 5)
        #expect(recent.count == 1)
        #expect(recent[0].kind == .shortBreak)
        #expect(recent[0].todoistCommentStatus == .notApplicable)
        #expect(await todoist.commentCount == 0)
    }
}

@Suite("Abandoned time accounting")
struct AbandonedTimeTests {
    private let now = Fixture.date("2026-08-29 14:30:00")

    private func makeOrchestrator(store: SessionStoring, todoist: FakeTodoist) -> CompletionOrchestrator {
        CompletionOrchestrator(
            store: store,
            todoist: todoist,
            clock: MutableDateProvider(now: now),
            timeZone: TimeZone(identifier: "Europe/Lisbon")!
        )
    }

    @Test("A stopped session logs the minutes already invested when logging is on")
    func abandonLogsPartialTime() async throws {
        let store = try Fixture.store()
        let todoist = FakeTodoist()
        let orchestrator = makeOrchestrator(store: store, todoist: todoist)
        let sessionID = UUID()

        let outcome = await orchestrator.finishFocus(
            sessionID: sessionID, task: Fixture.task,
            elapsedSeconds: 720, plannedSeconds: 1500, reason: .abandoned,
            logsPartialTime: true
        )

        #expect(outcome.commentStatus == .posted)
        #expect(!outcome.taskClosed)
        // Stopping a session never closes the Todoist task.
        #expect(await todoist.closeCount == 0)
        #expect(
            await todoist.commentContents.first
                == "Focusdoro: 12 min focused on this task (stopped early, 2026-08-29 14:30)."
        )

        let saved = try #require(try store.session(id: sessionID))
        #expect(saved.status == .abandoned)
        #expect(saved.elapsedDurationSeconds == 720)
        #expect(saved.todoistCommentStatus == .posted)
    }

    @Test("Logging off keeps the abandoned time local")
    func abandonWithoutLogging() async throws {
        let store = try Fixture.store()
        let todoist = FakeTodoist()
        let orchestrator = makeOrchestrator(store: store, todoist: todoist)
        let sessionID = UUID()

        let outcome = await orchestrator.finishFocus(
            sessionID: sessionID, task: Fixture.task,
            elapsedSeconds: 720, plannedSeconds: 1500, reason: .abandoned,
            logsPartialTime: false
        )

        #expect(outcome.commentStatus == .notApplicable)
        #expect(await todoist.commentCount == 0)
        #expect(try store.session(id: sessionID)?.elapsedDurationSeconds == 720)
    }

    @Test("A session shorter than a minute posts nothing")
    func abandonUnderOneMinute() async throws {
        let store = try Fixture.store()
        let todoist = FakeTodoist()
        let orchestrator = makeOrchestrator(store: store, todoist: todoist)
        let sessionID = UUID()

        let outcome = await orchestrator.finishFocus(
            sessionID: sessionID, task: Fixture.task,
            elapsedSeconds: 0, plannedSeconds: 1500, reason: .abandoned,
            logsPartialTime: true
        )

        #expect(outcome.commentStatus == .notApplicable)
        #expect(await todoist.commentCount == 0)
    }

    @Test("A failed partial comment is retried with the same recorded time")
    func abandonCommentRetries() async throws {
        let store = try Fixture.store()
        let todoist = FakeTodoist()
        await todoist.setCommentError(.transport("offline"))
        let orchestrator = makeOrchestrator(store: store, todoist: todoist)
        let sessionID = UUID()

        let outcome = await orchestrator.finishFocus(
            sessionID: sessionID, task: Fixture.task,
            elapsedSeconds: 300, plannedSeconds: 1500, reason: .abandoned,
            logsPartialTime: true
        )
        #expect(outcome.commentStatus == .failed)
        #expect(try store.sessionsNeedingCommentRetry().count == 1)

        await todoist.setCommentError(nil)
        await orchestrator.retryPendingComments()

        #expect(await todoist.commentContents.last?.contains("5 min") == true)
        #expect(await todoist.commentContents.last?.contains("stopped early") == true)
        #expect(try store.session(id: sessionID)?.todoistCommentStatus == .posted)
        #expect(try store.sessionsNeedingCommentRetry().isEmpty)
    }

    @Test("A duplicate abandon event posts only one comment")
    func abandonIsIdempotent() async throws {
        let store = try Fixture.store()
        let todoist = FakeTodoist()
        let orchestrator = makeOrchestrator(store: store, todoist: todoist)
        let sessionID = UUID()

        for _ in 0..<3 {
            _ = await orchestrator.finishFocus(
                sessionID: sessionID, task: Fixture.task,
                elapsedSeconds: 300, plannedSeconds: 1500, reason: .abandoned,
                logsPartialTime: true
            )
        }

        #expect(await todoist.commentCount == 1)
        #expect(try store.recentSessions(limit: 10).count == 1)
    }

    @Test("The banner names where the invested time went")
    @MainActor
    func bannerWording() {
        let posted = AppModel.abandonBannerText(
            elapsedSeconds: 720,
            outcome: CompletionOutcome(sessionID: UUID(), commentStatus: .posted, taskClosed: false)
        )
        #expect(posted.contains("12 min kept in your history"))
        #expect(posted.contains("logged on the Todoist task"))

        let local = AppModel.abandonBannerText(
            elapsedSeconds: 720,
            outcome: CompletionOutcome(sessionID: UUID(), commentStatus: .notApplicable, taskClosed: false)
        )
        #expect(local.contains("Nothing was sent to Todoist"))

        let failed = AppModel.abandonBannerText(
            elapsedSeconds: 720,
            outcome: CompletionOutcome(sessionID: UUID(), commentStatus: .failed, taskClosed: false)
        )
        #expect(failed.contains("retry"))
    }
}
