import Foundation
import Testing
@testable import FocusdoroCore

@Suite("Todoist API v1 client", .serialized)
struct TodoistClientTests {
    private func makeClient(
        policy: RetryPolicy = .singleAttempt,
        token: String? = "test-token"
    ) -> TodoistClient {
        TodoistClient(
            session: StubURLProtocol.makeSession(),
            timeout: 5,
            policy: policy,
            tokenProvider: { token },
            // Backoff is exercised for its shape, not its wall-clock duration.
            sleeper: { _ in }
        )
    }

    private static let taskJSON = """
    [
      {"id":"1","content":"Ship the popover","project_id":"p1","priority":4,
       "due":{"date":"2026-08-29","string":"today","is_recurring":false},
       "labels":["work"],"url":"https://todoist.com/showTask?id=1"},
      {"id":"2","content":"Buy oat milk","project_id":"p2","priority":1}
    ]
    """

    @Test("Decodes the task list including due and labels")
    func decodesTasks() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.enqueue(.json(Self.taskJSON))

        let tasks = try await makeClient().listTasks()
        #expect(tasks.count == 2)
        #expect(tasks[0].id == "1")
        #expect(tasks[0].content == "Ship the popover")
        #expect(tasks[0].due?.date == "2026-08-29")
        #expect(tasks[0].labels == ["work"])
        #expect(tasks[1].due == nil)
    }

    @Test("Sends bearer authorization and hits the API v1 base URL")
    func sendsAuthorization() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.enqueue(.json("[]"))

        _ = try await makeClient().listTasks()
        let request = try #require(StubURLProtocol.requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
        #expect(request.url?.absoluteString == "https://api.todoist.com/api/v1/tasks?limit=200")
        #expect(request.httpMethod == "GET")
    }

    @Test("Close accepts 204 No Content")
    func closeAccepts204() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.enqueue(.empty(status: 204))

        try await makeClient().closeTask(id: "1")
        let request = try #require(StubURLProtocol.requests.first)
        #expect(request.url?.absoluteString == "https://api.todoist.com/api/v1/tasks/1/close")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "X-Request-Id") != nil)
    }

    @Test("Comment posts JSON and decodes the 200 response")
    func addsComment() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.enqueue(.json(#"{"id":"c9","task_id":"1","content":"Focusdoro: 25 min"}"#))

        let comment = try await makeClient().addComment(taskID: "1", content: "Focusdoro: 25 min")
        #expect(comment.id == "c9")
        #expect(comment.taskID == "1")

        let request = try #require(StubURLProtocol.requests.first)
        #expect(request.url?.absoluteString == "https://api.todoist.com/api/v1/comments")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    // MARK: - Error mapping

    @Test("401 maps to unauthorized")
    func unauthorized() async {
        StubURLProtocol.reset()
        StubURLProtocol.enqueue(.empty(status: 401))
        await #expect(throws: TodoistError.unauthorized) {
            _ = try await makeClient().listTasks()
        }
    }

    @Test("403 also maps to unauthorized")
    func forbidden() async {
        StubURLProtocol.reset()
        StubURLProtocol.enqueue(.empty(status: 403))
        await #expect(throws: TodoistError.unauthorized) {
            _ = try await makeClient().listTasks()
        }
    }

    @Test("404 maps to notFound")
    func notFound() async {
        StubURLProtocol.reset()
        StubURLProtocol.enqueue(.empty(status: 404))
        await #expect(throws: TodoistError.notFound) {
            try await makeClient().closeTask(id: "gone")
        }
    }

    @Test("429 maps to rateLimited and carries Retry-After")
    func rateLimited() async {
        StubURLProtocol.reset()
        StubURLProtocol.enqueue(.empty(status: 429, headers: ["Retry-After": "3"]))
        await #expect(throws: TodoistError.rateLimited(retryAfter: 3)) {
            _ = try await makeClient().listTasks()
        }
    }

    @Test("5xx maps to server")
    func serverError() async {
        StubURLProtocol.reset()
        StubURLProtocol.enqueue(.empty(status: 503))
        await #expect(throws: TodoistError.server(status: 503)) {
            _ = try await makeClient().listTasks()
        }
    }

    @Test("A transport failure maps to transport")
    func transportError() async {
        StubURLProtocol.reset()
        StubURLProtocol.enqueue(.failure(URLError(.notConnectedToInternet)))
        do {
            _ = try await makeClient().listTasks()
            Issue.record("Expected a transport error")
        } catch let error as TodoistError {
            guard case .transport = error else {
                Issue.record("Expected .transport, got \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    @Test("Undecodable body maps to invalidResponse")
    func invalidBody() async {
        StubURLProtocol.reset()
        StubURLProtocol.enqueue(.json("not json"))
        do {
            _ = try await makeClient().listTasks()
            Issue.record("Expected invalidResponse")
        } catch let error as TodoistError {
            guard case .invalidResponse = error else {
                Issue.record("Expected .invalidResponse, got \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    @Test("A missing token fails before any request is made")
    func missingToken() async {
        StubURLProtocol.reset()
        await #expect(throws: TodoistError.missingToken) {
            _ = try await makeClient(token: nil).listTasks()
        }
        #expect(StubURLProtocol.requestCount == 0)
    }

    // MARK: - Retry policy

    @Test("5xx is retried up to the attempt limit, then surfaces")
    func retriesServerErrors() async {
        StubURLProtocol.reset()
        StubURLProtocol.enqueue(.empty(status: 500), .empty(status: 500), .empty(status: 500))
        await #expect(throws: TodoistError.server(status: 500)) {
            _ = try await makeClient(policy: RetryPolicy(maxAttempts: 3, baseDelay: 0, maxDelay: 0)).listTasks()
        }
        #expect(StubURLProtocol.requestCount == 3)
    }

    @Test("A retried request succeeds once the server recovers")
    func retryThenSucceed() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.enqueue(.empty(status: 502), .json("[]"))
        let tasks = try await makeClient(policy: RetryPolicy(maxAttempts: 3, baseDelay: 0, maxDelay: 0)).listTasks()
        #expect(tasks.isEmpty)
        #expect(StubURLProtocol.requestCount == 2)
    }

    @Test("401 is never retried")
    func neverRetriesUnauthorized() async {
        StubURLProtocol.reset()
        StubURLProtocol.enqueue(.empty(status: 401), .json("[]"))
        await #expect(throws: TodoistError.unauthorized) {
            _ = try await makeClient(policy: RetryPolicy(maxAttempts: 3, baseDelay: 0, maxDelay: 0)).listTasks()
        }
        #expect(StubURLProtocol.requestCount == 1)
    }

    @Test("Backoff is exponential and bounded")
    func backoffShape() {
        let policy = RetryPolicy(maxAttempts: 5, baseDelay: 0.5, maxDelay: 2)
        #expect(policy.delay(forAttempt: 1) == 0.5)
        #expect(policy.delay(forAttempt: 2) == 1.0)
        #expect(policy.delay(forAttempt: 3) == 2.0)
        #expect(policy.delay(forAttempt: 4) == 2.0)
    }

    @Test("Error retryability matches the spec's policy")
    func retryability() {
        #expect(TodoistError.transport("x").isRetryable)
        #expect(TodoistError.server(status: 500).isRetryable)
        #expect(TodoistError.rateLimited(retryAfter: nil).isRetryable)
        #expect(!TodoistError.unauthorized.isRetryable)
        #expect(!TodoistError.notFound.isRetryable)
        #expect(!TodoistError.invalidResponse("x").isRetryable)
        #expect(!TodoistError.missingToken.isRetryable)
    }

    @Test("Token validation uses a single lightweight authenticated request")
    func validateToken() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.enqueue(.json("[]"))
        try await makeClient().validateToken()
        #expect(StubURLProtocol.requestCount == 1)
        #expect(StubURLProtocol.requests[0].url?.absoluteString == "https://api.todoist.com/api/v1/projects?limit=1")
    }
    @Test("Decodes the paginated v1 collection shape")
    func decodesPagedResults() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.enqueue(.json("""
        {"results":[{"id":"6X7rM8997g3RQmvh","content":"Ship the popover","project_id":"p1","priority":4}],
         "next_cursor":null}
        """))

        let tasks = try await makeClient().listTasks()
        #expect(tasks.count == 1)
        #expect(tasks[0].id == "6X7rM8997g3RQmvh")
    }

    @Test("Follows next_cursor until the last page")
    func followsCursor() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.enqueue(.json("""
        {"results":[{"id":"1","content":"First"}],"next_cursor":"cursor-2"}
        """))
        StubURLProtocol.enqueue(.json("""
        {"results":[{"id":"2","content":"Second"}],"next_cursor":null}
        """))

        let tasks = try await makeClient().listTasks()
        #expect(tasks.map(\.id) == ["1", "2"])
        #expect(StubURLProtocol.requests.count == 2)
        #expect(StubURLProtocol.requests[0].url?.query?.contains("cursor") == false)
        #expect(StubURLProtocol.requests[1].url?.query?.contains("cursor=cursor-2") == true)
    }

    @Test("An empty next_cursor ends pagination instead of looping")
    func emptyCursorStops() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.enqueue(.json("""
        {"results":[{"id":"1","content":"First"}],"next_cursor":""}
        """))

        let tasks = try await makeClient().listTasks()
        #expect(tasks.count == 1)
        #expect(StubURLProtocol.requests.count == 1)
    }

    @Test("410 Gone reports a retired endpoint, not a Todoist outage")
    func retiredEndpoint() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.enqueue(.empty(status: 410))

        await #expect(throws: TodoistError.endpointRetired) {
            try await makeClient().listTasks()
        }
        // Retrying a retired endpoint would never succeed.
        #expect(!TodoistError.endpointRetired.isRetryable)
    }

    @Test("Decodes projects, including the inbox flag, across pages")
    func decodesProjects() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.enqueue(.json("""
        {"results":[{"id":"p1","name":"Inbox","color":"grey","is_inbox_project":true}],
         "next_cursor":"cursor-2"}
        """))
        StubURLProtocol.enqueue(.json("""
        {"results":[{"id":"p2","name":"Work","color":"blue"}],"next_cursor":null}
        """))

        let projects = try await makeClient().listProjects()
        #expect(projects.map(\.id) == ["p1", "p2"])
        #expect(projects[0].isInboxProject == true)
        #expect(projects[1].isInboxProject == nil)
        #expect(StubURLProtocol.requests[0].url?.absoluteString == "https://api.todoist.com/api/v1/projects?limit=200")
        #expect(StubURLProtocol.requests[1].url?.query?.contains("cursor=cursor-2") == true)
    }

    @Test("A comment accepted with no body still counts as posted")
    func commentWithEmptyBody() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.enqueue(.empty(status: 204))

        let comment = try await makeClient().addComment(taskID: "1", content: "Focusdoro: 25 min focused on this task (2026-08-29 14:30).")
        #expect(comment.taskID == "1")
        #expect(comment.content.hasPrefix("Focusdoro: 25 min"))
    }

}
