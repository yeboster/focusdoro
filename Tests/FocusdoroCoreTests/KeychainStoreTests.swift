import Foundation
import Testing
@testable import FocusdoroCore

/// Uses a per-run service key so the tests never touch the real app's Keychain entry.
@Suite("Keychain token storage", .serialized)
struct KeychainStoreTests {
    private func makeStore() -> KeychainStore {
        KeychainStore(service: "com.focusdoro.tests.\(UUID().uuidString)", account: "todoist-api-token")
    }

    @Test("A missing token reads back as nil rather than throwing")
    func missingTokenIsNil() throws {
        let store = makeStore()
        #expect(try store.readToken() == nil)
    }

    @Test("Save then read round-trips the token")
    func saveAndRead() throws {
        let store = makeStore()
        defer { try? store.deleteToken() }
        try store.saveToken("abc123")
        #expect(try store.readToken() == "abc123")
    }

    @Test("Saving twice overwrites instead of duplicating the entry")
    func overwrite() throws {
        let store = makeStore()
        defer { try? store.deleteToken() }
        try store.saveToken("first")
        try store.saveToken("second")
        #expect(try store.readToken() == "second")
    }

    @Test("Delete removes the token")
    func delete() throws {
        let store = makeStore()
        try store.saveToken("abc123")
        try store.deleteToken()
        #expect(try store.readToken() == nil)
    }

    @Test("Deleting a token that is not there is not an error")
    func deleteMissingIsNoop() throws {
        let store = makeStore()
        try store.deleteToken()
        try store.deleteToken()
    }

    @Test("Two stores with different services do not see each other's tokens")
    func serviceIsolation() throws {
        let first = makeStore()
        let second = makeStore()
        defer { try? first.deleteToken(); try? second.deleteToken() }
        try first.saveToken("first-token")
        #expect(try second.readToken() == nil)
    }

    @Test("An empty stored value reads as no token")
    func emptyTokenIsNil() throws {
        let store = makeStore()
        defer { try? store.deleteToken() }
        try store.saveToken("")
        #expect(try store.readToken() == nil)
    }

    @Test("The default service is scoped to the bundle identifier")
    func defaultServiceScoped() {
        #expect(KeychainStore.defaultService.hasSuffix(".todoist"))
    }

    @Test("The in-memory double behaves like the real store")
    func inMemoryDouble() throws {
        let store = InMemoryTokenStore()
        #expect(try store.readToken() == nil)
        try store.saveToken("t")
        #expect(try store.readToken() == "t")
        try store.deleteToken()
        #expect(try store.readToken() == nil)
    }

    @Test("Preferences never carry the token")
    func preferencesHaveNoTokenField() throws {
        var preferences = AppPreferences.default
        preferences.lastSelectedTaskID = "task-1"
        let encoded = try JSONEncoder().encode(preferences)
        let json = try #require(String(data: encoded, encoding: .utf8)).lowercased()
        #expect(!json.contains("token"))
        #expect(!json.contains("secret"))
    }
}

@Suite("App preferences")
struct AppPreferencesTests {
    @Test("Defaults match the spec exactly")
    func defaults() {
        let preferences = AppPreferences.default
        #expect(preferences.focusDurationSeconds == 1500)
        #expect(preferences.shortBreakDurationSeconds == 300)
        #expect(preferences.longBreakDurationSeconds == 900)
        #expect(preferences.longBreakCadence == 4)
        #expect(preferences.soundEnabled)
        #expect(preferences.notificationsEnabled)
        #expect(preferences.bindings[.togglePopover] != nil)
        #expect(preferences.bindings[.startStopTimer] != nil)
        #expect(preferences.lastSelectedTaskID == nil)
    }

    @Test("Break cadence returns a long break only on the cadence multiple")
    func breakCadence() {
        let preferences = AppPreferences.default
        #expect(preferences.breakPhase(afterCompletedFocusCount: 0) == .shortBreak)
        #expect(preferences.breakPhase(afterCompletedFocusCount: 1) == .shortBreak)
        #expect(preferences.breakPhase(afterCompletedFocusCount: 3) == .shortBreak)
        #expect(preferences.breakPhase(afterCompletedFocusCount: 4) == .longBreak)
        #expect(preferences.breakPhase(afterCompletedFocusCount: 8) == .longBreak)
    }

    @Test("A zero cadence degrades to short breaks instead of dividing by zero")
    func zeroCadence() {
        var preferences = AppPreferences.default
        preferences.longBreakCadence = 0
        #expect(preferences.breakPhase(afterCompletedFocusCount: 4) == .shortBreak)
    }

    @Test("Preferences survive a UserDefaults round trip")
    func userDefaultsRoundTrip() throws {
        let suiteName = "focusdoro.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = UserDefaultsPreferencesStore(defaults: defaults)
        var preferences = store.preferences
        preferences.focusDurationSeconds = 3000
        preferences.soundIdentifier = "Ping"
        store.preferences = preferences

        let reloaded = UserDefaultsPreferencesStore(defaults: defaults)
        #expect(reloaded.preferences.focusDurationSeconds == 3000)
        #expect(reloaded.preferences.soundIdentifier == "Ping")
    }

    @Test("Duration lookup covers every phase")
    func durationLookup() {
        let preferences = AppPreferences.default
        #expect(preferences.duration(for: .focus) == 1500)
        #expect(preferences.duration(for: .shortBreak) == 300)
        #expect(preferences.duration(for: .longBreak) == 900)
    }

    @Test("Preferences written by an older build, missing the newer optional fields, still decode")
    func decodesOlderPreferencesFormat() throws {
        // Simulates a JSON blob from before taskSortOrderID / taskFilterCriteria /
        // logsAbandonedTimeFlag existed: the three keys are absent entirely, not null.
        let encoded = try JSONEncoder().encode(AppPreferences.default)
        var dict = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        dict.removeValue(forKey: "taskSortOrderID")
        dict.removeValue(forKey: "taskFilterCriteria")
        dict.removeValue(forKey: "logsAbandonedTimeFlag")
        let olderData = try JSONSerialization.data(withJSONObject: dict)

        let decoded = try JSONDecoder().decode(AppPreferences.self, from: olderData)

        #expect(decoded.focusDurationSeconds == AppPreferences.default.focusDurationSeconds)
        // Every field the older build never wrote falls back to its documented default.
        #expect(decoded.taskSortOrder == .dueDate)
        #expect(decoded.taskFilter == .none)
        #expect(decoded.logsAbandonedTime == true)
    }

    @Test("A cadence of one means every completed focus session is a long break")
    func cadenceOfOne() {
        var preferences = AppPreferences.default
        preferences.longBreakCadence = 1
        #expect(preferences.breakPhase(afterCompletedFocusCount: 1) == .longBreak)
        #expect(preferences.breakPhase(afterCompletedFocusCount: 2) == .longBreak)
    }

    @Test("A negative cadence degrades to short breaks instead of a nonsensical modulus")
    func negativeCadence() {
        var preferences = AppPreferences.default
        preferences.longBreakCadence = -1
        #expect(preferences.breakPhase(afterCompletedFocusCount: 4) == .shortBreak)
    }
}
