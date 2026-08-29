import Foundation
import Testing
@testable import FocusdoroCore

// MARK: - Doubles

/// Private stub transport: the shared `StubURLProtocol` queue is process-global, and
/// these suites run alongside the Todoist ones.
final class SlackStubURLProtocol: URLProtocol {
    struct Response {
        var status: Int
        var body: Data
        var headers: [String: String] = [:]
        var error: Error?

        static func json(_ string: String, status: Int = 200, headers: [String: String] = [:]) -> Response {
            Response(status: status, body: Data(string.utf8), headers: headers, error: nil)
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var queue: [Response] = []
    nonisolated(unsafe) private static var recorded: [(URLRequest, Data?)] = []

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        queue = []
        recorded = []
    }

    static func enqueue(_ responses: Response...) {
        lock.lock(); defer { lock.unlock() }
        queue.append(contentsOf: responses)
    }

    static var requests: [(URLRequest, Data?)] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    private static func next(for request: URLRequest, body: Data?) -> Response {
        lock.lock(); defer { lock.unlock() }
        recorded.append((request, body))
        guard !queue.isEmpty else { return .json("{\"ok\":true}") }
        return queue.removeFirst()
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SlackStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // URLProtocol strips the body from the request it hands back, so capture it
        // from the stream the session recorded.
        let body = request.httpBody ?? request.httpBodyStream.map { stream -> Data in
            stream.open()
            defer { stream.close() }
            var data = Data()
            let size = 4096
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: size)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            return data
        }
        let response = Self.next(for: request, body: body)
        if let error = response.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let http = HTTPURLResponse(
            url: request.url!, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers
        )!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func makeSlackClient(token: String? = "xoxp-secret-token", policy: RetryPolicy = .singleAttempt) -> SlackClient {
    SlackClient(
        session: SlackStubURLProtocol.makeSession(),
        policy: policy,
        tokenProvider: { token },
        sleeper: { _ in }
    )
}

final class FakeSlack: SlackAPI, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    private var _statuses: [(String, String, Date?)] = []
    nonisolated(unsafe) var failures: [String: Error] = [:]

    var calls: [String] { lock.withLock { _calls } }
    var statuses: [(String, String, Date?)] { lock.withLock { _statuses } }
    private(set) nonisolated(unsafe) var snoozeMinutes: [Int] = []

    private func record(_ name: String) throws {
        lock.withLock { _calls.append(name) }
        if let error = failures[name] { throw error }
    }

    func setSnooze(minutes: Int) async throws {
        lock.withLock { snoozeMinutes.append(minutes) }
        try record("setSnooze")
    }
    func endSnooze() async throws { try record("endSnooze") }
    func setStatus(text: String, emoji: String, expiresAt: Date?) async throws {
        lock.withLock { _statuses.append((text, emoji, expiresAt)) }
        try record("setStatus")
    }
    func clearStatus() async throws {
        lock.withLock { _statuses.append(("", "", nil)) }
        try record("clearStatus")
    }
    func validateToken() async throws { try record("validateToken") }
}

final class FakeShortcuts: ShortcutRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _ran: [String] = []
    nonisolated(unsafe) var names: [String] = ["Focus On", "Focus Off"]
    nonisolated(unsafe) var failure: Error?

    var ran: [String] { lock.withLock { _ran } }

    func run(named name: String) async throws {
        lock.withLock { _ran.append(name) }
        if let failure { throw failure }
    }

    func availableShortcuts() async -> [String] { names }
}

/// Channel that only records, for coordinator-level tests.
final class RecordingChannel: PresenceChannel, @unchecked Sendable {
    let name: String
    private let lock = NSLock()
    private var _events: [String] = []
    nonisolated(unsafe) var engageError: Error?

    init(name: String) { self.name = name }

    var events: [String] { lock.withLock { _events } }

    func engage(_ context: FocusPresenceContext) async throws {
        lock.withLock { _events.append("engage:\(context.minutes)") }
        if let engageError { throw engageError }
    }

    func release() async throws {
        lock.withLock { _events.append("release") }
    }
}

// MARK: - Slack client

@Suite("Slack client", .serialized)
struct SlackClientTests {
    private func formBody(_ index: Int) -> String {
        String(data: SlackStubURLProtocol.requests[index].1 ?? Data(), encoding: .utf8) ?? ""
    }

    @Test("Snoozing posts the bounded minute count with a bearer token")
    func snoozePostsMinutes() async throws {
        SlackStubURLProtocol.reset()
        SlackStubURLProtocol.enqueue(.json("{\"ok\":true,\"snooze_enabled\":true}"))
        try await makeSlackClient().setSnooze(minutes: 25)

        let (request, _) = try #require(SlackStubURLProtocol.requests.first)
        #expect(request.url?.absoluteString == "https://slack.com/api/dnd.setSnooze")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer xoxp-secret-token")
        #expect(formBody(0) == "num_minutes=25")
    }

    @Test("A snooze is clamped to what Slack accepts")
    func snoozeIsClamped() async throws {
        SlackStubURLProtocol.reset()
        SlackStubURLProtocol.enqueue(.json("{\"ok\":true}"), .json("{\"ok\":true}"))
        let client = makeSlackClient()
        try await client.setSnooze(minutes: 0)
        try await client.setSnooze(minutes: 10_000)

        #expect(formBody(0) == "num_minutes=1")
        #expect(formBody(1) == "num_minutes=1440")
    }

    @Test("The status carries the truncated text, the emoji, and an expiry")
    func statusBodyIsWellFormed() async throws {
        SlackStubURLProtocol.reset()
        SlackStubURLProtocol.enqueue(.json("{\"ok\":true}"))
        let expiry = Date(timeIntervalSince1970: 1_800_000_000)
        try await makeSlackClient().setStatus(text: "Focusing on ship it", emoji: ":tomato:", expiresAt: expiry)

        let body = try #require(SlackStubURLProtocol.requests.first?.1)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let profile = try #require(json["profile"] as? [String: Any])
        #expect(profile["status_text"] as? String == "Focusing on ship it")
        #expect(profile["status_emoji"] as? String == ":tomato:")
        #expect(profile["status_expiration"] as? Int == 1_800_000_000)
    }

    @Test("Clearing the status sends empty fields and no expiry")
    func clearingStatusEmptiesFields() async throws {
        SlackStubURLProtocol.reset()
        SlackStubURLProtocol.enqueue(.json("{\"ok\":true}"))
        try await makeSlackClient().clearStatus()

        let body = try #require(SlackStubURLProtocol.requests.first?.1)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let profile = try #require(json["profile"] as? [String: Any])
        #expect(profile["status_text"] as? String == "")
        #expect(profile["status_expiration"] as? Int == 0)
    }

    @Test("Slack reports failures inside a 200 body")
    func okFalseIsAnError() async throws {
        SlackStubURLProtocol.reset()
        SlackStubURLProtocol.enqueue(.json("{\"ok\":false,\"error\":\"invalid_auth\"}"))
        await #expect(throws: SlackError.unauthorized) {
            try await makeSlackClient().setSnooze(minutes: 25)
        }
    }

    @Test("A missing scope names the scope the token needs")
    func missingScopeIsNamed() async throws {
        SlackStubURLProtocol.reset()
        SlackStubURLProtocol.enqueue(.json("{\"ok\":false,\"error\":\"missing_scope\",\"needed\":\"users.profile:write\"}"))
        await #expect(throws: SlackError.missingScope("users.profile:write")) {
            try await makeSlackClient().setStatus(text: "x", emoji: "", expiresAt: nil)
        }
    }

    @Test("Ending a snooze that already lapsed is the state we wanted")
    func snoozeNotActiveIsSuccess() async throws {
        SlackStubURLProtocol.reset()
        SlackStubURLProtocol.enqueue(.json("{\"ok\":false,\"error\":\"snooze_not_active\"}"))
        try await makeSlackClient().endSnooze()
    }

    @Test("A 429 is retried once the Retry-After has passed")
    func rateLimitIsRetried() async throws {
        SlackStubURLProtocol.reset()
        SlackStubURLProtocol.enqueue(
            .json("", status: 429, headers: ["Retry-After": "1"]),
            .json("{\"ok\":true}")
        )
        try await makeSlackClient(policy: RetryPolicy(maxAttempts: 2, baseDelay: 0, maxDelay: 0)).endSnooze()
        #expect(SlackStubURLProtocol.requests.count == 2)
    }

    @Test("Without a token nothing is sent")
    func missingTokenSendsNothing() async throws {
        SlackStubURLProtocol.reset()
        await #expect(throws: SlackError.missingToken) {
            try await makeSlackClient(token: nil).setSnooze(minutes: 25)
        }
        #expect(SlackStubURLProtocol.requests.isEmpty)
    }

    @Test("No Slack error ever carries the token, across every failure path")
    func errorsNeverLeakTheToken() async throws {
        let secret = "xoxp-super-secret"
        let responses: [SlackStubURLProtocol.Response] = [
            .json("{\"ok\":false,\"error\":\"invalid_auth\"}"),
            .json("{\"ok\":false,\"error\":\"missing_scope\",\"needed\":\"dnd:write\"}"),
            .json("{\"ok\":false,\"error\":\"user_not_found\"}"),
            .json("", status: 401),
            .json("", status: 500),
            .json("not json", status: 200),
        ]
        for response in responses {
            SlackStubURLProtocol.reset()
            SlackStubURLProtocol.enqueue(response)
            let client = SlackClient(
                session: SlackStubURLProtocol.makeSession(),
                policy: .singleAttempt,
                tokenProvider: { secret },
                sleeper: { _ in }
            )
            do {
                try await client.setSnooze(minutes: 25)
                Issue.record("expected the call to fail")
            } catch let error as SlackError {
                #expect(!error.userMessage.contains(secret))
                #expect(!"\(error)".contains(secret))
            }
        }
    }
}

// MARK: - Status text

@Suite("Slack status text")
struct SlackStatusFormatterTests {
    @Test("The task title replaces the placeholder")
    func placeholderIsReplaced() {
        #expect(SlackStatusFormatter.text(template: "Focusing on {task}", taskTitle: "Ship CI") == "Focusing on Ship CI")
    }

    @Test("An empty title still reads as a sentence")
    func emptyTitleFallsBack() {
        #expect(SlackStatusFormatter.text(template: "Focusing on {task}", taskTitle: "   ") == "Focusing on a task")
    }

    @Test("An empty template never sets a blank status")
    func emptyTemplateFallsBack() {
        #expect(SlackStatusFormatter.text(template: "  ", taskTitle: "Ship CI") == "Focusing")
    }

    @Test("A long status is cut to Slack's limit with an ellipsis")
    func longStatusIsTruncated() {
        let text = SlackStatusFormatter.text(template: "{task}", taskTitle: String(repeating: "a", count: 200))
        #expect(text.count == SlackClient.statusTextLimit)
        #expect(text.hasSuffix("…"))
    }
}

// MARK: - Channels

@Suite("Focus presence channels")
struct PresenceChannelTests {
    private let context = FocusPresenceContext(
        taskTitle: "Ship CI", minutes: 25, endsAt: Date(timeIntervalSince1970: 1_800_000_000)
    )

    private func slackChannel(
        _ slack: FakeSlack, settings: FocusPresenceSettings, hasToken: Bool = true
    ) -> SlackPresenceChannel {
        SlackPresenceChannel(client: slack, settings: { settings }, hasToken: { hasToken })
    }

    @Test("Slack switched off touches nothing")
    func slackDisabledDoesNothing() async throws {
        let slack = FakeSlack()
        try await slackChannel(slack, settings: FocusPresenceSettings(slackEnabled: false)).engage(context)
        #expect(slack.calls.isEmpty)
    }

    @Test("Slack enabled without a token says so instead of failing silently")
    func slackWithoutTokenThrows() async {
        let slack = FakeSlack()
        let channel = slackChannel(slack, settings: FocusPresenceSettings(slackEnabled: true), hasToken: false)
        await #expect(throws: SlackError.missingToken) { try await channel.engage(context) }
        #expect(slack.calls.isEmpty)
    }

    @Test("A session snoozes Slack and sets the status for exactly its length")
    func slackEngageSnoozesAndSetsStatus() async throws {
        let slack = FakeSlack()
        let settings = FocusPresenceSettings(slackEnabled: true, slackStatusEnabled: true)
        try await slackChannel(slack, settings: settings).engage(context)

        #expect(slack.calls == ["setSnooze", "setStatus"])
        #expect(slack.snoozeMinutes == [25])
        let status = try #require(slack.statuses.first)
        #expect(status.0 == "Focusing on Ship CI")
        #expect(status.2 == context.endsAt)
    }

    @Test("With the status switched off only the snooze is sent")
    func slackStatusCanBeSkipped() async throws {
        let slack = FakeSlack()
        let settings = FocusPresenceSettings(slackEnabled: true, slackStatusEnabled: false)
        try await slackChannel(slack, settings: settings).engage(context)
        #expect(slack.calls == ["setSnooze"])
    }

    @Test("Ending a session lifts the snooze and clears the status")
    func slackReleaseUndoesBoth() async throws {
        let slack = FakeSlack()
        try await slackChannel(slack, settings: FocusPresenceSettings(slackEnabled: true)).release()
        #expect(slack.calls == ["endSnooze", "clearStatus"])
    }

    @Test("A failed snooze lift still clears the status")
    func slackReleaseClearsStatusAfterFailure() async {
        let slack = FakeSlack()
        slack.failures["endSnooze"] = SlackError.server(status: 503)
        let channel = slackChannel(slack, settings: FocusPresenceSettings(slackEnabled: true))
        await #expect(throws: SlackError.server(status: 503)) { try await channel.release() }
        #expect(slack.calls == ["endSnooze", "clearStatus"])
    }

    @Test("macOS Focus runs the chosen shortcuts")
    func macFocusRunsShortcuts() async throws {
        let shortcuts = FakeShortcuts()
        let settings = FocusPresenceSettings(
            macFocusEnabled: true, startShortcutName: "Focus On", endShortcutName: "Focus Off"
        )
        let channel = MacFocusChannel(runner: shortcuts, settings: { settings })
        try await channel.engage(context)
        try await channel.release()
        #expect(shortcuts.ran == ["Focus On", "Focus Off"])
    }

    @Test("macOS Focus without a chosen shortcut asks the user to pick one")
    func macFocusNeedsConfiguration() async {
        let shortcuts = FakeShortcuts()
        let channel = MacFocusChannel(runner: shortcuts, settings: { FocusPresenceSettings(macFocusEnabled: true) })
        await #expect(throws: ShortcutError.notConfigured) { try await channel.engage(context) }
        #expect(shortcuts.ran.isEmpty)
    }

    @Test("macOS Focus switched off runs nothing")
    func macFocusDisabledRunsNothing() async throws {
        let shortcuts = FakeShortcuts()
        let settings = FocusPresenceSettings(
            macFocusEnabled: false, startShortcutName: "Focus On", endShortcutName: "Focus Off"
        )
        try await MacFocusChannel(runner: shortcuts, settings: { settings }).engage(context)
        #expect(shortcuts.ran.isEmpty)
    }
}

// MARK: - Coordinator

@Suite("Focus presence coordinator")
struct PresenceCoordinatorTests {
    private let context = FocusPresenceContext(taskTitle: "Ship CI", minutes: 25, endsAt: .distantFuture)

    @Test("One failing channel does not stop the others")
    func failuresAreIsolated() async {
        let broken = RecordingChannel(name: "Slack")
        broken.engageError = SlackError.unauthorized
        let working = RecordingChannel(name: "macOS Focus")
        let coordinator = PresenceCoordinator(channels: [broken, working])

        let failures = await coordinator.engage(context)
        #expect(failures == [PresenceFailure(channel: "Slack", message: SlackError.unauthorized.userMessage)])
        #expect(working.events == ["engage:25"])
    }

    @Test("Releasing without a session in flight does nothing")
    func releaseWithoutEngageIsInert() async {
        let channel = RecordingChannel(name: "Slack")
        let coordinator = PresenceCoordinator(channels: [channel])
        _ = await coordinator.release()
        #expect(channel.events.isEmpty)
    }

    @Test("A second release after a session is inert too")
    func releaseIsIdempotent() async {
        let channel = RecordingChannel(name: "Slack")
        let coordinator = PresenceCoordinator(channels: [channel])
        _ = await coordinator.engage(context)
        _ = await coordinator.release()
        _ = await coordinator.release()
        #expect(channel.events == ["engage:25", "release"])
    }

    @Test("The banner names one failing channel and summarises several")
    func bannerWording() {
        let slack = PresenceFailure(channel: "Slack", message: "Slack rejected the token.")
        let focus = PresenceFailure(channel: "macOS Focus", message: "The shortcut did not run.")
        #expect(PresenceMessage.banner(for: []) == nil)
        #expect(PresenceMessage.banner(for: [slack]) == "Slack: Slack rejected the token.")
        #expect(PresenceMessage.banner(for: [slack, focus]) == "Slack and macOS Focus could not be updated for this session.")
    }
}

// MARK: - App model integration

@MainActor
private struct PresenceHarness {
    let clock = MutableDateProvider(now: Fixture.date("2026-08-29 14:00:00"))
    let todoist = FakeTodoist()
    let tokens = InMemoryTokenStore()
    let slackTokens = InMemoryTokenStore()
    let slack = FakeSlack()
    let shortcuts = FakeShortcuts()
    let preferences = InMemoryPreferencesStore()
    let channel = RecordingChannel(name: "Slack")
    let model: AppModel

    init() throws {
        try tokens.saveToken("todoist-token")
        let store = try Fixture.store()
        let engine = TimerEngine(clock: clock, persistence: InMemoryTimerStateStore(), preferences: preferences)
        let sync = TodoistSync(client: todoist, tokenStore: tokens, clock: clock, calendar: Fixture.calendar())
        let services = PresenceServices(
            coordinator: PresenceCoordinator(channels: [channel]),
            slack: slack,
            slackTokens: slackTokens,
            shortcuts: shortcuts
        )
        model = AppModel(
            sync: sync,
            engine: engine,
            orchestrator: CompletionOrchestrator(
                store: store, todoist: todoist, clock: clock, timeZone: Fixture.calendar().timeZone
            ),
            store: store,
            preferencesStore: preferences,
            notifications: PreviewNotifications(),
            clock: clock,
            calendar: Fixture.calendar(),
            presence: services
        )
    }

    /// `start()` is what subscribes to the engine's event stream, so a test that waits
    /// on a terminal event has to go through it.
    func startFocus() async {
        await model.start()
        await model.select(task: Fixture.task("t1", "Ship CI"))
        await model.startFocus()
    }
}

@Suite("Focus mode in the app model")
@MainActor
struct AppModelPresenceTests {
    @Test("Starting a focus session announces it for the session's length")
    func startingFocusEngages() async throws {
        let harness = try PresenceHarness()
        harness.model.preferences.focusDurationSeconds = 1500
        await harness.startFocus()
        #expect(harness.channel.events == ["engage:25"])
    }

    @Test("Finishing the session lifts it again")
    func finishingReleases() async throws {
        let harness = try PresenceHarness()
        await harness.startFocus()
        harness.clock.advance(by: 1500)
        await harness.model.engine.tick()
        try await waitUntil("the finished session releases focus mode") {
            harness.channel.events.contains("release")
        }
    }

    @Test("Stopping the session early lifts it too")
    func abandoningReleases() async throws {
        let harness = try PresenceHarness()
        await harness.startFocus()
        harness.clock.advance(by: 300)
        await harness.model.confirmAbandon()
        try await waitUntil("the stopped session releases focus mode") {
            harness.channel.events.contains("release")
        }
    }

    @Test("A break is time away from the desk, so notifications come back")
    func breakReleases() async throws {
        let harness = try PresenceHarness()
        await harness.startFocus()
        await harness.model.startBreak(.shortBreak)
        #expect(harness.channel.events == ["engage:25", "release"])
    }

    @Test("Connecting Slack validates the token, stores it, and turns the channel on")
    func connectingSlackStoresTheToken() async throws {
        let harness = try PresenceHarness()
        harness.model.slackTokenDraft = "xoxp-valid"
        await harness.model.connectSlack()

        #expect(harness.slack.calls == ["validateToken"])
        #expect(try harness.slackTokens.readToken() == "xoxp-valid")
        #expect(harness.model.slackIsConnected)
        #expect(harness.model.preferences.presence.slackEnabled)
        // The draft never keeps the token around for the next render.
        #expect(harness.model.slackTokenDraft.isEmpty)
    }

    @Test("A rejected Slack token is never kept")
    func rejectedSlackTokenIsDiscarded() async throws {
        let harness = try PresenceHarness()
        harness.slack.failures["validateToken"] = SlackError.unauthorized
        harness.model.slackTokenDraft = "xoxp-bad"
        await harness.model.connectSlack()

        #expect(try harness.slackTokens.readToken() == nil)
        #expect(!harness.model.slackIsConnected)
        #expect(!harness.model.preferences.presence.slackEnabled)
        let banner = try #require(harness.model.banner)
        #expect(banner.text == SlackError.unauthorized.userMessage)
        #expect(!banner.text.contains("xoxp-bad"))
    }

    @Test("Removing Slack drops the token and switches the channel off")
    func disconnectingSlackClearsEverything() async throws {
        let harness = try PresenceHarness()
        harness.model.slackTokenDraft = "xoxp-valid"
        await harness.model.connectSlack()
        harness.model.disconnectSlack()

        #expect(try harness.slackTokens.readToken() == nil)
        #expect(!harness.model.slackIsConnected)
        #expect(!harness.model.preferences.presence.slackEnabled)
    }

    @Test("Settings offers the shortcuts the Shortcuts app knows about")
    func shortcutNamesAreOffered() async throws {
        let harness = try PresenceHarness()
        harness.shortcuts.names = ["Deep Work On", "Deep Work Off"]
        await harness.model.loadAvailableShortcuts()
        #expect(harness.model.availableShortcuts == ["Deep Work On", "Deep Work Off"])
    }
}

@Suite("Focus mode preferences")
struct FocusPresencePreferencesTests {
    @Test("Preferences written before focus mode existed still decode")
    func olderPreferencesDecode() throws {
        let legacy = """
        {"focusDurationSeconds":1500,"shortBreakDurationSeconds":300,"longBreakDurationSeconds":900,
         "longBreakCadence":4,"soundEnabled":true,"soundIdentifier":"Glass","notificationsEnabled":true,
         "bindings":[],"breakAutoStartDelaySeconds":10}
        """
        let decoded = try JSONDecoder().decode(AppPreferences.self, from: Data(legacy.utf8))
        #expect(decoded.focusPresenceSettings == nil)
        #expect(decoded.presence == .default)
        #expect(!decoded.presence.macFocusEnabled)
        #expect(!decoded.presence.slackEnabled)
    }

    @Test("Focus mode settings survive a round trip")
    func settingsRoundTrip() throws {
        var preferences = AppPreferences.default
        preferences.presence.macFocusEnabled = true
        preferences.presence.startShortcutName = "Focus On"
        preferences.presence.slackStatusEmoji = ":dart:"

        let data = try JSONEncoder().encode(preferences)
        let decoded = try JSONDecoder().decode(AppPreferences.self, from: data)
        #expect(decoded.presence.startShortcutName == "Focus On")
        #expect(decoded.presence.slackStatusEmoji == ":dart:")
        #expect(decoded == preferences)
    }

    @Test("macOS Focus is only usable once both shortcuts are picked")
    func macFocusUsability() {
        var settings = FocusPresenceSettings(macFocusEnabled: true, startShortcutName: "On")
        #expect(!settings.macFocusIsUsable)
        settings.endShortcutName = "Off"
        #expect(settings.macFocusIsUsable)
        settings.macFocusEnabled = false
        #expect(!settings.macFocusIsUsable)
    }
}
