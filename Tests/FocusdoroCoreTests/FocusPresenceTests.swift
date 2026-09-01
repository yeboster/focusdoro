import Foundation
import Testing
@testable import FocusdoroCore

// MARK: - Doubles

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

private enum PresenceTestError: Error {
    case failed
}

private final class FailingDeleteTokenStore: TokenStoring, @unchecked Sendable {
    func saveToken(_ token: String) throws {}
    func readToken() throws -> String? { nil }
    func deleteToken() throws { throw PresenceTestError.failed }
}

// MARK: - Channels

@Suite("Focus presence channels")
struct PresenceChannelTests {
    private let context = FocusPresenceContext(
        taskTitle: "Ship CI", minutes: 25, endsAt: Date(timeIntervalSince1970: 1_800_000_000)
    )

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
        let broken = RecordingChannel(name: "Broken shortcut")
        broken.engageError = PresenceTestError.failed
        let working = RecordingChannel(name: "macOS Focus")
        let coordinator = PresenceCoordinator(channels: [broken, working])

        let failures = await coordinator.engage(context)
        #expect(failures == [PresenceFailure(channel: "Broken shortcut", message: "Something went wrong.")])
        #expect(working.events == ["engage:25"])
    }

    @Test("Releasing without a session in flight does nothing")
    func releaseWithoutEngageIsInert() async {
        let channel = RecordingChannel(name: "macOS Focus")
        let coordinator = PresenceCoordinator(channels: [channel])
        _ = await coordinator.release()
        #expect(channel.events.isEmpty)
    }

    @Test("A second release after a session is inert too")
    func releaseIsIdempotent() async {
        let channel = RecordingChannel(name: "macOS Focus")
        let coordinator = PresenceCoordinator(channels: [channel])
        _ = await coordinator.engage(context)
        _ = await coordinator.release()
        _ = await coordinator.release()
        #expect(channel.events == ["engage:25", "release"])
    }

    @Test("The banner names one failing channel and summarises several")
    func bannerWording() {
        let first = PresenceFailure(channel: "First", message: "Could not run.")
        let focus = PresenceFailure(channel: "macOS Focus", message: "The shortcut did not run.")
        #expect(PresenceMessage.banner(for: []) == nil)
        #expect(PresenceMessage.banner(for: [first]) == "First: Could not run.")
        #expect(PresenceMessage.banner(for: [first, focus]) == "First and macOS Focus could not be updated for this session.")
    }
}

// MARK: - Legacy credential cleanup

@Suite("Legacy Slack credential cleanup")
struct LegacySlackCredentialMigrationTests {
    @Test("Legacy Slack cleanup deletes only the old Slack entry")
    func removesOnlyLegacyCredential() throws {
        var preferences = AppPreferences.default
        let todoist = InMemoryTokenStore(token: "todoist-token")
        let legacySlack = InMemoryTokenStore(token: "legacy-slack-token")

        try LegacyCredentialMigrator.migrateIfNeeded(
            preferences: &preferences,
            legacySlackTokens: legacySlack
        )

        #expect(try todoist.readToken() == "todoist-token")
        #expect(try legacySlack.readToken() == nil)
        #expect(preferences.legacySlackCredentialRemoved)
    }

    @Test("Failed legacy cleanup remains pending for a future launch")
    func failureDoesNotMarkMigrationComplete() throws {
        var preferences = AppPreferences.default

        #expect(throws: PresenceTestError.failed) {
            try LegacyCredentialMigrator.migrateIfNeeded(
                preferences: &preferences,
                legacySlackTokens: FailingDeleteTokenStore()
            )
        }

        #expect(!preferences.legacySlackCredentialRemoved)
    }

    @Test("Completed legacy cleanup is idempotent")
    func completedCleanupDoesNotTouchLegacyStoreAgain() throws {
        var preferences = AppPreferences.default
        let todoist = InMemoryTokenStore(token: "todoist-token")
        let legacySlack = InMemoryTokenStore(token: "legacy-slack-token")
        try LegacyCredentialMigrator.migrateIfNeeded(
            preferences: &preferences,
            legacySlackTokens: legacySlack
        )
        try legacySlack.saveToken("must-not-be-deleted")

        try LegacyCredentialMigrator.migrateIfNeeded(
            preferences: &preferences,
            legacySlackTokens: legacySlack
        )

        #expect(try legacySlack.readToken() == "must-not-be-deleted")
        #expect(try todoist.readToken() == "todoist-token")
    }
}

// MARK: - App model integration

@MainActor
private struct PresenceHarness {
    let clock = MutableDateProvider(now: Fixture.date("2026-08-29 14:00:00"))
    let todoist = FakeTodoist()
    let tokens = InMemoryTokenStore()
    let shortcuts = FakeShortcuts()
    let preferences = InMemoryPreferencesStore()
    let channel = RecordingChannel(name: "macOS Focus")
    let model: AppModel

    init() throws {
        try tokens.saveToken("todoist-token")
        let store = try Fixture.store()
        let engine = TimerEngine(clock: clock, persistence: InMemoryTimerStateStore(), preferences: preferences)
        let sync = TodoistSync(client: todoist, tokenStore: tokens, clock: clock, calendar: Fixture.calendar())
        let services = PresenceServices(coordinator: PresenceCoordinator(channels: [channel]))
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
            presence: services,
            shortcuts: shortcuts
        )
    }

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
    }

    @Test("Historical Slack fields are ignored while macOS Focus survives")
    func historicalSlackFieldsAreIgnored() throws {
        let historical = """
        {"focusDurationSeconds":1500,"shortBreakDurationSeconds":300,"longBreakDurationSeconds":900,
         "longBreakCadence":4,"soundEnabled":true,"soundIdentifier":"Glass","notificationsEnabled":true,
         "bindings":[],"breakAutoStartDelaySeconds":10,
         "focusPresenceSettings":{"macFocusEnabled":true,"startShortcutName":"On","endShortcutName":"Off",
         "slackEnabled":true,"slackStatusEnabled":true,"slackStatusTemplate":"Focusing on {task}","slackStatusEmoji":":tomato:"}}
        """
        let decoded = try JSONDecoder().decode(AppPreferences.self, from: Data(historical.utf8))
        #expect(decoded.presence.macFocusEnabled)
        #expect(decoded.presence.startShortcutName == "On")
        #expect(decoded.presence.endShortcutName == "Off")
    }

    @Test("Focus mode settings survive a round trip")
    func settingsRoundTrip() throws {
        var preferences = AppPreferences.default
        preferences.presence.macFocusEnabled = true
        preferences.presence.startShortcutName = "Focus On"
        preferences.presence.endShortcutName = "Focus Off"

        let data = try JSONEncoder().encode(preferences)
        let decoded = try JSONDecoder().decode(AppPreferences.self, from: data)
        #expect(decoded.presence.startShortcutName == "Focus On")
        #expect(decoded.presence.endShortcutName == "Focus Off")
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
