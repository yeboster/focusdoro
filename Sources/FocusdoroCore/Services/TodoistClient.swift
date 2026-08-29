import Foundation

public protocol TodoistAPI: Sendable {
    func listTasks() async throws -> [TodoistTask]
    func listProjects() async throws -> [TodoistProject]
    func closeTask(id: String) async throws
    func addComment(taskID: String, content: String) async throws -> TodoistComment
    func validateToken() async throws
}

public struct RetryPolicy: Sendable {
    public var maxAttempts: Int
    public var baseDelay: TimeInterval
    public var maxDelay: TimeInterval

    public static let `default` = RetryPolicy(maxAttempts: 3, baseDelay: 0.5, maxDelay: 4)
    public static let singleAttempt = RetryPolicy(maxAttempts: 1, baseDelay: 0, maxDelay: 0)

    public init(maxAttempts: Int, baseDelay: TimeInterval, maxDelay: TimeInterval) {
        self.maxAttempts = maxAttempts
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
    }

    /// Bounded exponential backoff. Attempt is 1-based.
    public func delay(forAttempt attempt: Int) -> TimeInterval {
        guard attempt > 0 else { return 0 }
        return min(maxDelay, baseDelay * pow(2, Double(attempt - 1)))
    }
}

/// Todoist API v1 client. One injected `URLSession`, bearer auth, bounded timeout,
/// typed errors, and retries limited to transport/5xx/429 (spec §7).
///
/// REST v2 (`/rest/v2`) is sunset and answers every request with `410 Gone`, so all
/// paths here target the unified v1 API, whose collection endpoints are cursor
/// paginated: `{"results": [...], "next_cursor": "..."}`.
public final class TodoistClient: TodoistAPI, @unchecked Sendable {
    public static let baseURL = URL(string: "https://api.todoist.com/api/v1")!
    /// Guards against a server that keeps handing back a cursor.
    private static let maxPages = 20
    private static let pageSize = 200

    private let session: URLSession
    private let tokenProvider: @Sendable () throws -> String?
    private let policy: RetryPolicy
    private let timeout: TimeInterval
    private let sleeper: @Sendable (TimeInterval) async throws -> Void

    public init(
        session: URLSession = .shared,
        timeout: TimeInterval = 15,
        policy: RetryPolicy = .default,
        tokenProvider: @escaping @Sendable () throws -> String?,
        sleeper: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    ) {
        self.session = session
        self.timeout = timeout
        self.policy = policy
        self.tokenProvider = tokenProvider
        self.sleeper = sleeper
    }

    // MARK: - API surface

    public func listTasks() async throws -> [TodoistTask] {
        var tasks: [TodoistTask] = []
        var cursor: String?

        for _ in 0..<Self.maxPages {
            var query = [URLQueryItem(name: "limit", value: String(Self.pageSize))]
            if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
            let request = try makeRequest(path: "tasks", method: "GET", query: query)
            let (data, _) = try await perform(request, expecting: [200])
            let page = try decode(TodoistPage<TodoistTask>.self, from: data)
            tasks.append(contentsOf: page.results)
            guard let next = page.nextCursor, !next.isEmpty else { return tasks }
            cursor = next
        }
        return tasks
    }

    public func listProjects() async throws -> [TodoistProject] {
        var projects: [TodoistProject] = []
        var cursor: String?

        for _ in 0..<Self.maxPages {
            var query = [URLQueryItem(name: "limit", value: String(Self.pageSize))]
            if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
            let request = try makeRequest(path: "projects", method: "GET", query: query)
            let (data, _) = try await perform(request, expecting: [200])
            let page = try decode(TodoistPage<TodoistProject>.self, from: data)
            projects.append(contentsOf: page.results)
            guard let next = page.nextCursor, !next.isEmpty else { return projects }
            cursor = next
        }
        return projects
    }

    public func closeTask(id: String) async throws {
        guard let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed), !encoded.isEmpty else {
            throw TodoistError.invalidResponse("Invalid task id")
        }
        let request = try makeRequest(path: "tasks/\(encoded)/close", method: "POST")
        _ = try await perform(request, expecting: [204])
    }

    public func addComment(taskID: String, content: String) async throws -> TodoistComment {
        var request = try makeRequest(path: "comments", method: "POST")
        let body: [String: String] = ["task_id": taskID, "content": content]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, _) = try await perform(request, expecting: [200, 201, 204])
        // A 204 (or an empty 200) still means the comment landed; the only thing lost is
        // the server-assigned id, which is optional in the local record.
        guard !data.isEmpty else {
            return TodoistComment(id: "", taskID: taskID, content: content)
        }
        return try decode(TodoistComment.self, from: data)
    }

    /// Lightweight authenticated request used to validate a pasted token.
    public func validateToken() async throws {
        var request = try makeRequest(path: "projects", method: "GET", query: [URLQueryItem(name: "limit", value: "1")])
        request.timeoutInterval = min(timeout, 10)
        _ = try await perform(request, expecting: [200], policy: .singleAttempt)
    }

    // MARK: - Transport

    private func makeRequest(path: String, method: String, query: [URLQueryItem] = []) throws -> URLRequest {
        guard let token = try tokenProvider(), !token.isEmpty else { throw TodoistError.missingToken }
        var url = Self.baseURL.appendingPathComponent(path)
        if !query.isEmpty, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.queryItems = query
            url = components.url ?? url
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // Todoist treats X-Request-Id as an idempotency key for POST writes.
        if method == "POST" {
            request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Request-Id")
        }
        return request
    }

    private func perform(
        _ request: URLRequest,
        expecting acceptable: Set<Int>,
        policy overridePolicy: RetryPolicy? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        let policy = overridePolicy ?? self.policy
        var lastError: TodoistError = .transport("unknown")

        for attempt in 1...max(1, policy.maxAttempts) {
            do {
                return try await send(request, expecting: acceptable)
            } catch let error as TodoistError {
                lastError = error
                guard error.isRetryable, attempt < policy.maxAttempts else { throw error }
                try Task.checkCancellation()
                var wait = policy.delay(forAttempt: attempt)
                if case .rateLimited(let retryAfter) = error, let retryAfter {
                    wait = min(policy.maxDelay, max(wait, retryAfter))
                }
                try await sleeper(wait)
            }
        }
        throw lastError
    }

    private func send(_ request: URLRequest, expecting acceptable: Set<Int>) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            // Redacted: the message never carries the request's Authorization header.
            throw TodoistError.transport((error as NSError).localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw TodoistError.invalidResponse("Non-HTTP response")
        }

        if acceptable.contains(http.statusCode) { return (data, http) }

        switch http.statusCode {
        case 401, 403:
            throw TodoistError.unauthorized
        case 404:
            throw TodoistError.notFound
        case 410:
            // The old REST v2 host answers this way. Surfacing it as its own case keeps
            // "your Focusdoro build is too old" from reading like a Todoist outage.
            throw TodoistError.endpointRetired
        case 429:
            let header = http.value(forHTTPHeaderField: "Retry-After")
            throw TodoistError.rateLimited(retryAfter: header.flatMap(TimeInterval.init))
        case 500...599:
            throw TodoistError.server(status: http.statusCode)
        default:
            throw TodoistError.invalidResponse("Unexpected status \(http.statusCode)")
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw TodoistError.invalidResponse("Could not decode \(String(describing: type))")
        }
    }
}
