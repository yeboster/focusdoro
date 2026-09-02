import Testing
import CoreGraphics
import Foundation
@testable import FocusdoroCore

// MARK: - URLProtocol stub

/// Intercepts every request so the Todoist client can be tested without a network.
final class StubURLProtocol: URLProtocol {
    struct Response {
        var status: Int
        var body: Data
        var headers: [String: String]
        var error: Error?

        static func json(_ string: String, status: Int = 200, headers: [String: String] = [:]) -> Response {
            Response(status: status, body: Data(string.utf8), headers: headers, error: nil)
        }

        static func empty(status: Int, headers: [String: String] = [:]) -> Response {
            Response(status: status, body: Data(), headers: headers, error: nil)
        }

        static func failure(_ error: Error) -> Response {
            Response(status: 0, body: Data(), headers: [:], error: error)
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var queue: [Response] = []
    nonisolated(unsafe) private static var recorded: [URLRequest] = []

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        queue = []
        recorded = []
    }

    static func enqueue(_ responses: Response...) {
        lock.lock(); defer { lock.unlock() }
        queue.append(contentsOf: responses)
    }

    static var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    static var requestCount: Int { requests.count }

    /// URLSession may convert HTTP bodies into streams before handing requests to a
    /// URLProtocol, so tests inspect either representation.
    static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 1_024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: bufferSize)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }

    private static func next(for request: URLRequest) -> Response {
        lock.lock(); defer { lock.unlock() }
        recorded.append(request)
        guard !queue.isEmpty else { return .empty(status: 500) }
        return queue.removeFirst()
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = Self.next(for: request)
        if let error = response.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let http = HTTPURLResponse(
            url: request.url!,
            statusCode: response.status,
            httpVersion: "HTTP/1.1",
            headerFields: response.headers
        )!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        if !response.body.isEmpty { client?.urlProtocol(self, didLoad: response.body) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - Todoist fake

/// Records calls and replays scripted outcomes, so orchestration tests can assert
/// exactly-once behaviour without HTTP.
actor FakeTodoist: TodoistAPI {
    private(set) var closedTaskIDs: [String] = []
    private(set) var createdContents: [String] = []
    private(set) var createdDueDatetimes: [Date?] = []
    private(set) var createdDurationMinutes: [Int?] = []
    private(set) var commentedTaskIDs: [String] = []
    private(set) var commentContents: [String] = []
    private var tasks: [TodoistTask] = []
    private var createdTask: TodoistTask?
    private var createError: TodoistError?
    private var closeError: TodoistError?
    private var commentError: TodoistError?
    private var validateError: TodoistError?
    private var projectsError: TodoistError?
    /// Artificial delay before `listTasks` returns, so a test can force one refresh to
    /// still be in flight when a second one starts (cancellation races).
    private var listTasksDelayNanoseconds: UInt64 = 0
    /// Keeps task creation in flight while tests exercise model intent reentry.
    private var createTaskDelayNanoseconds: UInt64 = 0

    init(tasks: [TodoistTask] = []) { self.tasks = tasks }

    func setTasks(_ value: [TodoistTask]) { tasks = value }
    func setCreatedTask(_ value: TodoistTask?) { createdTask = value }
    func setCreateError(_ value: TodoistError?) { createError = value }
    func setCloseError(_ value: TodoistError?) { closeError = value }
    func setCommentError(_ value: TodoistError?) { commentError = value }
    func setValidateError(_ value: TodoistError?) { validateError = value }
    func setListTasksDelay(seconds: Double) { listTasksDelayNanoseconds = UInt64(seconds * 1_000_000_000) }
    func setCreateTaskDelay(seconds: Double) { createTaskDelayNanoseconds = UInt64(seconds * 1_000_000_000) }

    private(set) var listTasksCount = 0

    func listTasks() async throws -> [TodoistTask] {
        listTasksCount += 1
        if listTasksDelayNanoseconds > 0 { try? await Task.sleep(nanoseconds: listTasksDelayNanoseconds) }
        return tasks
    }

    func createTask(content: String, dueDatetime: Date?, durationMinutes: Int?) async throws -> TodoistTask {
        createdContents.append(content)
        createdDueDatetimes.append(dueDatetime)
        createdDurationMinutes.append(durationMinutes)
        if createTaskDelayNanoseconds > 0 { try? await Task.sleep(nanoseconds: createTaskDelayNanoseconds) }
        if let createError { throw createError }
        return createdTask ?? TodoistTask(id: "created-\(createdContents.count)", content: content)
    }

    func closeTask(id: String) async throws {
        closedTaskIDs.append(id)
        if let closeError { throw closeError }
    }

    func addComment(taskID: String, content: String) async throws -> TodoistComment {
        commentAttempts += 1
        if let commentError { throw commentError }
        // Recorded only once the call actually lands, so `commentCount` means
        // "comments Todoist accepted", not "times we tried".
        commentedTaskIDs.append(taskID)
        commentContents.append(content)
        return TodoistComment(id: "comment-\(commentedTaskIDs.count)", taskID: taskID, content: content)
    }

    private(set) var commentAttempts = 0

    private(set) var projects: [TodoistProject] = []

    func setProjects(_ value: [TodoistProject]) { projects = value }
    func setProjectsError(_ value: TodoistError?) { projectsError = value }

    func listProjects() async throws -> [TodoistProject] {
        if let projectsError { throw projectsError }
        return projects
    }

    func validateToken() async throws {
        if let validateError { throw validateError }
    }

    var commentCount: Int { commentedTaskIDs.count }
    var closeCount: Int { closedTaskIDs.count }
}

// MARK: - Fixtures

enum Fixture {
    static func date(_ string: String, timeZone: TimeZone = TimeZone(identifier: "Europe/Lisbon")!) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: string)!
    }

    static func calendar(_ identifier: String = "Europe/Lisbon") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier)!
        return calendar
    }

    static func task(_ id: String, _ content: String, due: String? = nil, datetime: String? = nil, priority: Int = 1, labels: [String] = [], projectID: String = "p1", description: String? = nil) -> TodoistTask {
        TodoistTask(
            id: id,
            content: content,
            description: description,
            projectID: projectID,
            priority: priority,
            due: due.map { TodoistDue(date: $0, string: $0, isRecurring: false, datetime: datetime) },
            labels: labels
        )
    }

    static let task = SelectedTask(id: "task-1", title: "Write the handoff doc")

    static func store() throws -> SessionStore {
        try SessionStore(inMemory: true)
    }
}

/// Polls until `condition` holds. The timer engine delivers events through an
/// `AsyncStream` consumed by a detached task, so tests must wait for delivery rather
/// than assume it happened by the time the triggering call returned.
@MainActor
func waitUntil(
    _ description: String,
    timeoutSeconds: Double = 3,
    _ condition: () -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
        if condition() { return }
        try await Task.sleep(nanoseconds: 2_000_000)
    }
    Issue.record("Timed out waiting for: \(description)")
}


/// Anything that draws — `NSHostingView`, `NSStatusItem`, `NSSound` — needs a window
/// server. A headless CI runner has none, and touching AppKit there does not throw:
/// it trips an assertion inside `CGSConnectionByID` and takes the whole test process
/// down. These suites are therefore skipped where no session exists, and the manual
/// checklist in `docs/testing-checklist.md` covers that ground on a real desktop.
enum TestEnvironment {
    /// AppKit traps in `CGSConnectionByID` when there is no window server, which takes
    /// the whole test process down rather than failing one test. GitHub's macOS runners
    /// report a session dictionary but are not attached to a console, so the AppKit
    /// suites are local-only and the checklist in docs/testing-checklist.md covers them.
    static let hasWindowServer: Bool = {
        let environment = ProcessInfo.processInfo.environment
        if environment["FOCUSDORO_HEADLESS"] == "1" { return false }
        if environment["CI"] != nil { return false }
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["kCGSSessionOnConsoleKey"] as? Bool == true
    }()
}

