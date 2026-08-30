import Foundation

// MARK: - Clock injection

/// Injectable time source. Production uses the system clock; tests drive it manually.
public protocol DateProviding: Sendable {
    var now: Date { get }
}

public struct SystemDateProvider: DateProviding {
    public init() {}
    public var now: Date { Date() }
}

/// Test clock. Advancing it is the only way time moves.
public final class MutableDateProvider: DateProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    public init(now: Date) { self.current = now }

    public var now: Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    public func advance(by seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        current = current.addingTimeInterval(seconds)
    }

    public func set(_ date: Date) {
        lock.lock(); defer { lock.unlock() }
        current = date
    }
}

// MARK: - Phases and states

public enum TimerPhase: String, Codable, Sendable, CaseIterable {
    case focus
    case shortBreak
    case longBreak

    public var isBreak: Bool { self != .focus }

    public var displayName: String {
        switch self {
        case .focus: return "Focus"
        case .shortBreak: return "Short break"
        case .longBreak: return "Long break"
        }
    }
}

/// Spec §4. `abandoned` and `completed` are terminal record states that the engine
/// passes through before returning to `idle` / `breakPrompt`.
public enum TimerState: Equatable, Sendable {
    case idle
    case focusing
    case focusCompletionPending
    case breakPrompt(next: TimerPhase)
    case shortBreaking
    case longBreaking

    public var isFocusing: Bool { self == .focusing }

    public var activePhase: TimerPhase? {
        switch self {
        case .focusing, .focusCompletionPending: return .focus
        case .shortBreaking: return .shortBreak
        case .longBreaking: return .longBreak
        case .idle, .breakPrompt: return nil
        }
    }
}

public enum SessionStatus: String, Codable, Sendable {
    case completed
    case abandoned
    case interrupted
    case failed
}

public enum CommentStatus: String, Codable, Sendable {
    case notApplicable
    case pending
    case posted
    case failed
}

// MARK: - Task identity

/// The engine never keeps a full cached Todoist task. Only identity plus a title
/// snapshot, so stale cache data can never be treated as authoritative (spec §7).
public struct SelectedTask: Equatable, Codable, Sendable {
    public let id: String
    public let title: String
    /// Project snapshot taken at selection time. Optional on the wire so a timer state
    /// persisted by an earlier build still decodes, and so history keeps the project
    /// even after the task is closed or moved.
    public let projectID: String?
    public let projectName: String?

    public init(id: String, title: String, projectID: String? = nil, projectName: String? = nil) {
        self.id = id
        self.title = title
        self.projectID = projectID
        self.projectName = projectName
    }
}

// MARK: - Session record

/// Value-type mirror of the Core Data `FocusSession` entity.
public struct SessionRecord: Equatable, Sendable {
    public var id: UUID
    public var taskID: String
    public var taskTitleSnapshot: String
    /// Project the task belonged to when the session ran. Kept as a snapshot so the
    /// weekly breakdown survives the task being closed, moved, or the project renamed.
    public var projectID: String?
    public var projectNameSnapshot: String?
    public var startedAt: Date
    public var endedAt: Date?
    public var plannedDurationSeconds: Int32
    public var elapsedDurationSeconds: Int32
    public var kind: TimerPhase
    public var status: SessionStatus
    public var todoistCommentStatus: CommentStatus
    public var todoistCommentID: String?
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        taskID: String,
        taskTitleSnapshot: String,
        projectID: String? = nil,
        projectNameSnapshot: String? = nil,
        startedAt: Date,
        endedAt: Date? = nil,
        plannedDurationSeconds: Int32,
        elapsedDurationSeconds: Int32 = 0,
        kind: TimerPhase,
        status: SessionStatus,
        todoistCommentStatus: CommentStatus = .notApplicable,
        todoistCommentID: String? = nil,
        createdAt: Date
    ) {
        self.id = id
        self.taskID = taskID
        self.taskTitleSnapshot = taskTitleSnapshot
        self.projectID = projectID
        self.projectNameSnapshot = projectNameSnapshot
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.plannedDurationSeconds = plannedDurationSeconds
        self.elapsedDurationSeconds = elapsedDurationSeconds
        self.kind = kind
        self.status = status
        self.todoistCommentStatus = todoistCommentStatus
        self.todoistCommentID = todoistCommentID
        self.createdAt = createdAt
    }
}

public struct TodaySummary: Equatable, Sendable {
    /// Focus time from sessions that ran to completion.
    public var focusedSeconds: Int
    /// Focus time from sessions the user stopped early. Still time invested, so it is
    /// reported, but it never counts as a completed session or feeds the streak.
    public var partialSeconds: Int
    public var completedFocusSessions: Int
    public var abandonedFocusSessions: Int
    public var streakDays: Int

    public init(
        focusedSeconds: Int = 0,
        partialSeconds: Int = 0,
        completedFocusSessions: Int = 0,
        abandonedFocusSessions: Int = 0,
        streakDays: Int = 0
    ) {
        self.focusedSeconds = focusedSeconds
        self.partialSeconds = partialSeconds
        self.completedFocusSessions = completedFocusSessions
        self.abandonedFocusSessions = abandonedFocusSessions
        self.streakDays = streakDays
    }

    public var focusedMinutes: Int { focusedSeconds / 60 }
    /// Everything the user actually spent focusing today, finished or not.
    public var investedSeconds: Int { focusedSeconds + partialSeconds }
    public var investedMinutes: Int { investedSeconds / 60 }
    public var partialMinutes: Int { partialSeconds / 60 }
}

// MARK: - Weekly stats

/// One calendar day of the week view. `seconds` is invested time — completed plus
/// stopped — so the chart matches what "Today" already reports.
public struct DayTotal: Equatable, Sendable, Identifiable {
    public var date: Date
    public var seconds: Int
    public var completedSessions: Int

    public init(date: Date, seconds: Int = 0, completedSessions: Int = 0) {
        self.date = date
        self.seconds = seconds
        self.completedSessions = completedSessions
    }

    public var id: Date { date }
    public var minutes: Int { seconds / 60 }
}

/// Per-project totals for the week. `id` is nil for sessions recorded before the
/// project snapshot existed, or for a task with no project.
public struct ProjectTotal: Equatable, Sendable, Identifiable {
    public var projectID: String?
    public var name: String
    public var seconds: Int
    public var completedSessions: Int

    public init(projectID: String?, name: String, seconds: Int, completedSessions: Int = 0) {
        self.projectID = projectID
        self.name = name
        self.seconds = seconds
        self.completedSessions = completedSessions
    }

    public var id: String { projectID ?? "__none__" }
    public var minutes: Int { seconds / 60 }
}

public struct WeeklySummary: Equatable, Sendable {
    /// The week the numbers cover, oldest day first, always seven entries so the chart
    /// has a stable shape even on a Monday.
    public var days: [DayTotal]
    /// Highest first; the view shows the top few.
    public var projects: [ProjectTotal]
    public var startOfWeek: Date?

    public init(days: [DayTotal] = [], projects: [ProjectTotal] = [], startOfWeek: Date? = nil) {
        self.days = days
        self.projects = projects
        self.startOfWeek = startOfWeek
    }

    public var investedSeconds: Int { days.reduce(0) { $0 + $1.seconds } }
    public var investedMinutes: Int { investedSeconds / 60 }
    public var completedFocusSessions: Int { days.reduce(0) { $0 + $1.completedSessions } }
    public var busiestDay: DayTotal? { days.filter { $0.seconds > 0 }.max { $0.seconds < $1.seconds } }
    public var isEmpty: Bool { investedSeconds == 0 }

    /// Average across the days that had any focus at all — averaging over seven days
    /// makes every week look idle.
    public var averageActiveDayMinutes: Int {
        let active = days.filter { $0.seconds > 0 }
        guard !active.isEmpty else { return 0 }
        return active.reduce(0) { $0 + $1.seconds } / active.count / 60
    }
}

// MARK: - Snapshot presented to the UI

public struct TimerSnapshot: Equatable, Sendable {
    public var state: TimerState
    public var task: SelectedTask?
    public var phase: TimerPhase?
    public var remainingSeconds: Int
    public var elapsedSeconds: Int
    public var plannedSeconds: Int
    public var completedFocusCount: Int
    public var nextBreakPhase: TimerPhase
    public var sessionID: UUID?

    public init(
        state: TimerState,
        task: SelectedTask? = nil,
        phase: TimerPhase? = nil,
        remainingSeconds: Int = 0,
        elapsedSeconds: Int = 0,
        plannedSeconds: Int = 0,
        completedFocusCount: Int = 0,
        nextBreakPhase: TimerPhase = .shortBreak,
        sessionID: UUID? = nil
    ) {
        self.state = state
        self.task = task
        self.phase = phase
        self.remainingSeconds = remainingSeconds
        self.elapsedSeconds = elapsedSeconds
        self.plannedSeconds = plannedSeconds
        self.completedFocusCount = completedFocusCount
        self.nextBreakPhase = nextBreakPhase
        self.sessionID = sessionID
    }

    /// `MM:SS`, and `H:MM:SS` past an hour so long custom durations stay readable.
    public var formattedRemaining: String {
        Self.format(seconds: max(0, remainingSeconds))
    }

    public var formattedElapsed: String {
        Self.format(seconds: max(0, elapsedSeconds))
    }

    public var progress: Double {
        guard plannedSeconds > 0 else { return 0 }
        return min(1, max(0, Double(elapsedSeconds) / Double(plannedSeconds)))
    }

    public static func format(seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }
}

// MARK: - Engine events

/// Emitted exactly once per session id, per spec Task 5.
public enum TimerEvent: Equatable, Sendable {
    case focusFinished(sessionID: UUID, task: SelectedTask, elapsedSeconds: Int, plannedSeconds: Int)
    case breakFinished(sessionID: UUID, phase: TimerPhase)
    case sessionAbandoned(sessionID: UUID, task: SelectedTask, elapsedSeconds: Int, plannedSeconds: Int, phase: TimerPhase)
    case taskCompletionRequested(sessionID: UUID, task: SelectedTask, elapsedSeconds: Int, plannedSeconds: Int)
}
