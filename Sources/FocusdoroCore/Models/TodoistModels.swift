import Foundation

// MARK: - Todoist API v1 wire types

public struct TodoistDue: Codable, Equatable, Sendable {
    /// `YYYY-MM-DD` for all-day items, RFC3339 when a time is attached.
    public let date: String
    public let string: String?
    public let isRecurring: Bool?
    public let datetime: String?
    public let timezone: String?

    enum CodingKeys: String, CodingKey {
        case date, string, datetime, timezone
        case isRecurring = "is_recurring"
    }

    public init(date: String, string: String? = nil, isRecurring: Bool? = nil, datetime: String? = nil, timezone: String? = nil) {
        self.date = date
        self.string = string
        self.isRecurring = isRecurring
        self.datetime = datetime
        self.timezone = timezone
    }
}

public struct TodoistTask: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let content: String
    public let description: String?
    public let projectID: String?
    public let priority: Int?
    public let due: TodoistDue?
    public let url: String?
    public let labels: [String]?

    enum CodingKeys: String, CodingKey {
        case id, content, description, priority, due, url, labels
        case projectID = "project_id"
    }

    public init(
        id: String,
        content: String,
        description: String? = nil,
        projectID: String? = nil,
        priority: Int? = nil,
        due: TodoistDue? = nil,
        url: String? = nil,
        labels: [String]? = nil
    ) {
        self.id = id
        self.content = content
        self.description = description
        self.projectID = projectID
        self.priority = priority
        self.due = due
        self.url = url
        self.labels = labels
    }

    public var selection: SelectedTask { SelectedTask(id: id, title: content) }
}

public struct TodoistComment: Codable, Equatable, Sendable {
    public let id: String
    public let taskID: String?
    public let content: String
    public let postedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, content
        case taskID = "task_id"
        case postedAt = "posted_at"
    }

    public init(id: String, taskID: String? = nil, content: String, postedAt: String? = nil) {
        self.id = id
        self.taskID = taskID
        self.content = content
        self.postedAt = postedAt
    }
}

/// v1 collection responses are cursor paginated. Kept tolerant of a bare array so a
/// single-object endpoint or an older response shape still decodes.
public struct TodoistPage<Element: Codable & Sendable>: Codable, Sendable {
    public let results: [Element]
    public let nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case results
        case nextCursor = "next_cursor"
    }

    public init(results: [Element], nextCursor: String? = nil) {
        self.results = results
        self.nextCursor = nextCursor
    }

    public init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: CodingKeys.self),
           let results = try? container.decode([Element].self, forKey: .results) {
            self.results = results
            self.nextCursor = try? container.decodeIfPresent(String.self, forKey: .nextCursor)
            return
        }
        let single = try decoder.singleValueContainer()
        self.results = try single.decode([Element].self)
        self.nextCursor = nil
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(results, forKey: .results)
        try container.encodeIfPresent(nextCursor, forKey: .nextCursor)
    }
}

public struct TodoistProject: Codable, Equatable, Sendable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let color: String?
    public let isInboxProject: Bool?

    enum CodingKeys: String, CodingKey {
        case id, name, color
        case isInboxProject = "is_inbox_project"
    }

    public init(id: String, name: String, color: String? = nil, isInboxProject: Bool? = nil) {
        self.id = id
        self.name = name
        self.color = color
        self.isInboxProject = isInboxProject
    }
}

// MARK: - Priority

/// Todoist stores priority inverted: wire value 4 is the user's P1.
public enum TaskPriority: Int, CaseIterable, Codable, Sendable, Identifiable {
    case p4 = 1
    case p3 = 2
    case p2 = 3
    case p1 = 4

    public var id: Int { rawValue }

    public init(wireValue: Int?) {
        self = TaskPriority(rawValue: wireValue ?? 1) ?? .p4
    }

    public var label: String { "P\(5 - rawValue)" }

    /// P4 is Todoist's "no priority" default and is not worth a badge.
    public var isFlagged: Bool { self != .p4 }
}

// MARK: - Typed errors

public enum TodoistError: Error, Equatable, Sendable {
    case unauthorized
    case rateLimited(retryAfter: TimeInterval?)
    case transport(String)
    case server(status: Int)
    case invalidResponse(String)
    case notFound
    case missingToken
    /// The endpoint itself is gone (HTTP 410), not the resource.
    case endpointRetired

    /// Only transport failures and 5xx are safe to retry (spec §7).
    public var isRetryable: Bool {
        switch self {
        case .transport, .server: return true
        case .rateLimited: return true
        case .unauthorized, .invalidResponse, .notFound, .missingToken, .endpointRetired: return false
        }
    }

    public var userMessage: String {
        switch self {
        case .unauthorized:
            return "Todoist rejected the token. Reconnect with a new personal API token."
        case .rateLimited:
            return "Todoist is rate limiting requests. Try again shortly."
        case .transport:
            return "Couldn't reach Todoist. Check your connection."
        case .server(let status):
            return "Todoist returned a server error (\(status)). Try again shortly."
        case .invalidResponse:
            return "Todoist returned an unexpected response."
        case .notFound:
            return "That task no longer exists in Todoist."
        case .missingToken:
            return "No Todoist token is connected."
        case .endpointRetired:
            return "This Focusdoro build is calling a Todoist API that has been retired. Update Focusdoro."
        }
    }
}

// MARK: - Task grouping

public struct TaskGroups: Equatable, Sendable {
    public var overdue: [TodoistTask]
    public var today: [TodoistTask]
    public var upcoming: [TodoistTask]
    public var undated: [TodoistTask]

    public init(overdue: [TodoistTask] = [], today: [TodoistTask] = [], upcoming: [TodoistTask] = [], undated: [TodoistTask] = []) {
        self.overdue = overdue
        self.today = today
        self.upcoming = upcoming
        self.undated = undated
    }

    public var isEmpty: Bool {
        overdue.isEmpty && today.isEmpty && upcoming.isEmpty && undated.isEmpty
    }
}
