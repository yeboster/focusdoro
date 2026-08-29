import Foundation

public enum SlackError: Error, Equatable {
    case missingToken
    case unauthorized
    case missingScope(String)
    case rateLimited(retryAfter: TimeInterval?)
    case transport(String)
    case server(status: Int)
    case api(String)

    /// Slack answers a throttled call with 429 and transient trouble with 5xx.
    public var isRetryable: Bool {
        switch self {
        case .transport, .server, .rateLimited: return true
        case .missingToken, .unauthorized, .missingScope, .api: return false
        }
    }

    public var userMessage: String {
        switch self {
        case .missingToken:
            return "No Slack token is connected."
        case .unauthorized:
            return "Slack rejected the token. Reconnect with a new user token."
        case .missingScope(let scope):
            return "The Slack token is missing the “\(scope)” scope."
        case .rateLimited:
            return "Slack is rate limiting requests. Try again shortly."
        case .transport:
            return "Couldn't reach Slack. Check your connection."
        case .server(let status):
            return "Slack returned a server error (\(status))."
        case .api(let code):
            return "Slack refused the request (\(code))."
        }
    }
}

public protocol SlackAPI: Sendable {
    func setSnooze(minutes: Int) async throws
    func endSnooze() async throws
    func setStatus(text: String, emoji: String, expiresAt: Date?) async throws
    func clearStatus() async throws
    func validateToken() async throws
}

/// Slack Web API client for the two things a focus session needs: Do Not Disturb and
/// the profile status. Both live behind a *user* token (`xoxp-…`) with the `dnd:write`
/// and `users.profile:write` scopes; the token is read from the Keychain per call and
/// never logged or interpolated into an error.
public final class SlackClient: SlackAPI, @unchecked Sendable {
    public static let baseURL = URL(string: "https://slack.com/api")!
    /// Slack truncates anything longer, and a task title can be a paragraph.
    public static let statusTextLimit = 100

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

    public func setSnooze(minutes: Int) async throws {
        // Slack rejects a zero-minute snooze; one minute is the smallest useful value.
        let bounded = max(1, min(1440, minutes))
        try await post(path: "dnd.setSnooze", form: ["num_minutes": String(bounded)])
    }

    public func endSnooze() async throws {
        try await post(path: "dnd.endSnooze", form: [:])
    }

    public func setStatus(text: String, emoji: String, expiresAt: Date?) async throws {
        let profile: [String: Any] = [
            "status_text": String(text.prefix(Self.statusTextLimit)),
            "status_emoji": emoji,
            "status_expiration": expiresAt.map { Int($0.timeIntervalSince1970) } ?? 0,
        ]
        try await postJSON(path: "users.profile.set", body: ["profile": profile])
    }

    public func clearStatus() async throws {
        try await setStatus(text: "", emoji: "", expiresAt: nil)
    }

    /// `auth.test` is the cheapest authenticated call; it also proves the token is a
    /// user token rather than a bot one.
    public func validateToken() async throws {
        try await post(path: "auth.test", form: [:], policy: .singleAttempt)
    }

    // MARK: - Transport

    private func makeRequest(path: String) throws -> URLRequest {
        guard let token = try tokenProvider(), !token.isEmpty else { throw SlackError.missingToken }
        var request = URLRequest(url: Self.baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func post(path: String, form: [String: String], policy: RetryPolicy? = nil) async throws {
        var request = try makeRequest(path: path)
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        if !form.isEmpty {
            var components = URLComponents()
            components.queryItems = form.keys.sorted().map { URLQueryItem(name: $0, value: form[$0]) }
            request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
        }
        try await perform(request, policy: policy)
    }

    private func postJSON(path: String, body: [String: Any], policy: RetryPolicy? = nil) async throws {
        var request = try makeRequest(path: path)
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        try await perform(request, policy: policy)
    }

    private func perform(_ request: URLRequest, policy overridePolicy: RetryPolicy?) async throws {
        let policy = overridePolicy ?? self.policy
        var lastError = SlackError.transport("unknown")

        for attempt in 1...max(1, policy.maxAttempts) {
            do {
                return try await send(request)
            } catch let error as SlackError {
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

    private func send(_ request: URLRequest) async throws {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            // Redacted: the message never carries the request's Authorization header.
            throw SlackError.transport((error as NSError).localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw SlackError.api("invalid_response")
        }

        switch http.statusCode {
        case 200:
            try Self.check(payload: data)
        case 401, 403:
            throw SlackError.unauthorized
        case 429:
            throw SlackError.rateLimited(retryAfter: http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init))
        case 500...599:
            throw SlackError.server(status: http.statusCode)
        default:
            throw SlackError.api("http_\(http.statusCode)")
        }
    }

    /// Slack reports failures inside a 200 body: `{"ok": false, "error": "invalid_auth"}`.
    static func check(payload: Data) throws {
        guard
            let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
        else { throw SlackError.api("invalid_response") }

        if object["ok"] as? Bool == true { return }
        let code = object["error"] as? String ?? "unknown"
        switch code {
        case "invalid_auth", "not_authed", "token_revoked", "account_inactive":
            throw SlackError.unauthorized
        case "missing_scope", "not_allowed_token_type":
            let needed = object["needed"] as? String ?? "dnd:write"
            throw SlackError.missingScope(needed)
        case "ratelimited", "rate_limited":
            throw SlackError.rateLimited(retryAfter: nil)
        case "snooze_not_active":
            // Ending a snooze that already expired is the state we wanted anyway.
            return
        default:
            throw SlackError.api(code)
        }
    }
}
