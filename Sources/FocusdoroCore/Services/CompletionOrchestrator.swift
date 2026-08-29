import Foundation

public enum FocusFinishReason: Equatable, Sendable {
    /// Deadline reached naturally.
    case timerCompleted
    /// User pressed "Complete task", which also closes the Todoist task.
    case taskCompleted
    /// User confirmed abandon. The task is never closed; the measured time is still
    /// logged when `logsPartialTime` says so.
    case abandoned
}

public struct CompletionOutcome: Equatable, Sendable {
    public var sessionID: UUID
    public var commentStatus: CommentStatus
    public var taskClosed: Bool
    public var error: TodoistError?

    public init(sessionID: UUID, commentStatus: CommentStatus, taskClosed: Bool, error: TodoistError? = nil) {
        self.sessionID = sessionID
        self.commentStatus = commentStatus
        self.taskClosed = taskClosed
        self.error = error
    }
}

/// Formats the Todoist duration comment. Deterministic and plain, so a human reading
/// the task history can audit it (spec §7).
public enum CommentFormatter {
    public static func minutes(forElapsedSeconds seconds: Int) -> Int {
        guard seconds > 0 else { return 0 }
        return max(1, Int((Double(seconds) / 60).rounded()))
    }

    public static func comment(
        elapsedSeconds: Int,
        at date: Date,
        timeZone: TimeZone = .current,
        locale: Locale = Locale(identifier: "en_US_POSIX"),
        partial: Bool = false
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let stamp = formatter.string(from: date)
        let minutes = minutes(forElapsedSeconds: elapsedSeconds)
        // A stopped session says so, so the Todoist history is not read as a full one.
        let tail = partial ? " (stopped early, \(stamp))." : " (\(stamp))."
        return "Focusdoro: \(minutes) min focused on this task\(tail)"
    }
}

/// Persists the session, then performs Todoist side effects.
///
/// Ordering matters: the local record is written first so a network failure can never
/// lose measured focus time, and the record's `todoistCommentStatus` is the idempotency
/// guard that makes a duplicate event or a retry incapable of posting twice.
public actor CompletionOrchestrator {
    private let store: SessionStoring
    private let todoist: TodoistAPI
    private let clock: DateProviding
    private let timeZone: TimeZone

    public init(store: SessionStoring, todoist: TodoistAPI, clock: DateProviding = SystemDateProvider(), timeZone: TimeZone = .current) {
        self.store = store
        self.todoist = todoist
        self.clock = clock
        self.timeZone = timeZone
    }

    // MARK: - Focus outcomes

    @discardableResult
    public func finishFocus(
        sessionID: UUID,
        task: SelectedTask,
        elapsedSeconds: Int,
        plannedSeconds: Int,
        startedAt: Date? = nil,
        reason: FocusFinishReason,
        logsPartialTime: Bool = false
    ) async -> CompletionOutcome {
        let now = clock.now
        let started = startedAt ?? now.addingTimeInterval(-TimeInterval(elapsedSeconds))

        if reason == .abandoned {
            // Nothing is closed, but the minutes already spent are real. They are logged
            // when the user asked for it and the session lasted at least a minute.
            let logs = logsPartialTime
                && !task.id.isEmpty
                && CommentFormatter.minutes(forElapsedSeconds: elapsedSeconds) >= 1
            if let existing = try? store.session(id: sessionID), existing.todoistCommentStatus == .posted {
                return CompletionOutcome(sessionID: sessionID, commentStatus: .posted, taskClosed: false)
            }
            let record = SessionRecord(
                id: sessionID,
                taskID: task.id,
                taskTitleSnapshot: task.title,
                startedAt: started,
                endedAt: now,
                plannedDurationSeconds: Int32(plannedSeconds),
                elapsedDurationSeconds: Int32(elapsedSeconds),
                kind: .focus,
                status: .abandoned,
                todoistCommentStatus: logs ? .pending : .notApplicable,
                createdAt: now
            )
            try? store.insertSession(record)
            guard logs else {
                return CompletionOutcome(sessionID: sessionID, commentStatus: .notApplicable, taskClosed: false)
            }
            let outcome = await postComment(
                sessionID: sessionID, taskID: task.id,
                elapsedSeconds: elapsedSeconds, at: now, partial: true
            )
            return CompletionOutcome(
                sessionID: sessionID, commentStatus: outcome.0, taskClosed: false, error: outcome.1
            )
        }

        // Already handled? A duplicate event must not produce a second comment.
        if let existing = try? store.session(id: sessionID), existing.todoistCommentStatus == .posted {
            return CompletionOutcome(sessionID: sessionID, commentStatus: .posted, taskClosed: reason == .taskCompleted)
        }

        let record = SessionRecord(
            id: sessionID,
            taskID: task.id,
            taskTitleSnapshot: task.title,
            startedAt: started,
            endedAt: now,
            plannedDurationSeconds: Int32(plannedSeconds),
            elapsedDurationSeconds: Int32(elapsedSeconds),
            kind: .focus,
            status: .completed,
            todoistCommentStatus: .pending,
            createdAt: now
        )
        try? store.insertSession(record)

        var closed = false
        var closeError: TodoistError?
        if reason == .taskCompleted {
            do {
                try await todoist.closeTask(id: task.id)
                closed = true
            } catch let error as TodoistError {
                closeError = error
            } catch {
                closeError = .transport("\(error)")
            }
        }

        // The local session stays completed even when Todoist closing failed: the
        // measured time is real, and the UI exposes a retry (spec §3).
        let commentOutcome = await postComment(sessionID: sessionID, taskID: task.id, elapsedSeconds: elapsedSeconds, at: now)
        return CompletionOutcome(
            sessionID: sessionID,
            commentStatus: commentOutcome.0,
            taskClosed: closed,
            error: closeError ?? commentOutcome.1
        )
    }

    public func recordBreak(sessionID: UUID, phase: TimerPhase, plannedSeconds: Int, elapsedSeconds: Int, startedAt: Date) {
        let now = clock.now
        let record = SessionRecord(
            id: sessionID,
            taskID: "",
            taskTitleSnapshot: phase.displayName,
            startedAt: startedAt,
            endedAt: now,
            plannedDurationSeconds: Int32(plannedSeconds),
            elapsedDurationSeconds: Int32(elapsedSeconds),
            kind: phase,
            status: .completed,
            todoistCommentStatus: .notApplicable,
            createdAt: now
        )
        try? store.insertSession(record)
    }

    // MARK: - Comment posting and retry

    @discardableResult
    public func retryComment(sessionID: UUID) async -> CompletionOutcome {
        guard let record = try? store.session(id: sessionID) else {
            return CompletionOutcome(sessionID: sessionID, commentStatus: .failed, taskClosed: false, error: .notFound)
        }
        // An abandoned session only reaches here with a pending/failed status when the
        // user had partial logging on, so retrying it is exactly what they asked for.
        // `notApplicable` means the session was never meant to comment (partial logging
        // off, or a break), so a retry must leave it alone.
        guard record.todoistCommentStatus == .pending || record.todoistCommentStatus == .failed,
              record.status == .completed || record.status == .abandoned,
              record.kind == .focus else {
            return CompletionOutcome(sessionID: sessionID, commentStatus: record.todoistCommentStatus, taskClosed: false)
        }
        let stamp = record.endedAt ?? clock.now
        let outcome = await postComment(
            sessionID: sessionID,
            taskID: record.taskID,
            elapsedSeconds: Int(record.elapsedDurationSeconds),
            at: stamp,
            partial: record.status == .abandoned
        )
        return CompletionOutcome(sessionID: sessionID, commentStatus: outcome.0, taskClosed: false, error: outcome.1)
    }

    /// Posts every session still marked pending or failed. Safe to call on launch.
    public func retryPendingComments() async {
        guard let pending = try? store.sessionsNeedingCommentRetry() else { return }
        for record in pending where record.kind == .focus
            && (record.status == .completed || record.status == .abandoned) {
            _ = await retryComment(sessionID: record.id)
        }
    }

    private func postComment(
        sessionID: UUID, taskID: String, elapsedSeconds: Int, at date: Date, partial: Bool = false
    ) async -> (CommentStatus, TodoistError?) {
        guard !taskID.isEmpty else {
            try? store.markCommentStatus(sessionID: sessionID, status: .notApplicable, commentID: nil)
            return (.notApplicable, nil)
        }
        let content = CommentFormatter.comment(
            elapsedSeconds: elapsedSeconds, at: date, timeZone: timeZone, partial: partial
        )
        do {
            let comment = try await todoist.addComment(taskID: taskID, content: content)
            try? store.markCommentStatus(sessionID: sessionID, status: .posted, commentID: comment.id)
            return (.posted, nil)
        } catch let error as TodoistError {
            try? store.markCommentStatus(sessionID: sessionID, status: .failed, commentID: nil)
            return (.failed, error)
        } catch {
            try? store.markCommentStatus(sessionID: sessionID, status: .failed, commentID: nil)
            return (.failed, .transport("\(error)"))
        }
    }
}
