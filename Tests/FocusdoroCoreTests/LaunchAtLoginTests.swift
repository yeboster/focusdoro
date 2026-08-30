import Foundation
import Testing
@testable import FocusdoroCore

@MainActor
private struct Harness {
    let clock = MutableDateProvider(now: Fixture.date("2026-08-29 14:00:00"))
    let todoist = FakeTodoist()
    let tokens = InMemoryTokenStore()
    let preferences = InMemoryPreferencesStore()
    let loginItem: InMemoryLoginItemService
    let model: AppModel

    init(loginItem: InMemoryLoginItemService? = InMemoryLoginItemService()) throws {
        self.loginItem = loginItem ?? InMemoryLoginItemService()
        try tokens.saveToken("test-token")
        let store = try Fixture.store()
        let engine = TimerEngine(clock: clock, persistence: InMemoryTimerStateStore(), preferences: preferences)
        model = AppModel(
            sync: TodoistSync(client: todoist, tokenStore: tokens, clock: clock, calendar: Fixture.calendar()),
            engine: engine,
            orchestrator: CompletionOrchestrator(store: store, todoist: todoist, clock: clock),
            store: store,
            preferencesStore: preferences,
            notifications: PreviewNotifications(),
            clock: clock,
            calendar: Fixture.calendar(),
            loginItem: loginItem
        )
    }
}

@Suite("Login item service")
struct LoginItemServiceTests {
    @Test("An unbundled process has no login item to register")
    func unbundled() throws {
        // `SMAppService.mainApp` needs a bundle identifier; a raw binary has none, and
        // registering there fails with an opaque plist error rather than doing anything.
        let service = LoginItemService(service: nil)
        #expect(service.status() == .unavailable)
        #expect(throws: LoginItemError.unavailable) { try service.setEnabled(true) }
    }

    @Test("Requires-approval still counts as switched on")
    func approvalIsOn() {
        // The user flipped the switch; macOS is waiting for them in System Settings.
        #expect(LoginItemStatus.requiresApproval.isOn)
        #expect(LoginItemStatus.enabled.isOn)
        #expect(!LoginItemStatus.disabled.isOn)
        #expect(!LoginItemStatus.unavailable.isOn)
    }

    @Test("The double records every write")
    func doubleRecords() throws {
        let service = InMemoryLoginItemService()
        try service.setEnabled(true)
        #expect(service.status() == .enabled)
        try service.setEnabled(false)
        #expect(service.status() == .disabled)
        #expect(service.writes == [true, false])
    }
}

@Suite("Launch at login in the app model")
@MainActor
struct LaunchAtLoginModelTests {
    @Test("Turning it on registers the login item")
    func enable() throws {
        let harness = try Harness()
        harness.model.refreshLoginItemStatus()
        #expect(harness.model.loginItemStatus == .disabled)

        harness.model.setLaunchAtLogin(true)
        #expect(harness.loginItem.writes == [true])
        #expect(harness.model.loginItemStatus == .enabled)
        #expect(harness.model.banner == nil)
    }

    @Test("Approval pending is explained, not reported as a failure")
    func requiresApproval() throws {
        let harness = try Harness(loginItem: InMemoryLoginItemService(status: .requiresApproval))
        harness.model.setLaunchAtLogin(true)
        // The double leaves the status it was built with untouched only on failure, so
        // read what the model surfaced rather than the service.
        #expect(harness.model.banner?.kind == .info)
        #expect(harness.model.banner?.text.contains("Login Items") == true)
    }

    @Test("A refused registration warns and keeps the real status")
    func failure() throws {
        let service = InMemoryLoginItemService(status: .disabled, failure: .failed("Operation not permitted"))
        let harness = try Harness(loginItem: service)
        harness.model.setLaunchAtLogin(true)
        #expect(harness.model.loginItemStatus == .disabled)
        #expect(harness.model.banner?.kind == .warning)
        #expect(harness.model.banner?.text.contains("Operation not permitted") == true)
    }

    @Test("Without a login item the toggle explains itself instead of failing silently")
    func unavailable() throws {
        let harness = try Harness()
        let model = harness.model
        // Same graph, no login item injected: the unbundled `swift run` case.
        let bare = AppModel(
            sync: model.sync,
            engine: model.engine,
            orchestrator: CompletionOrchestrator(store: try Fixture.store(), todoist: harness.todoist, clock: harness.clock),
            store: try Fixture.store(),
            preferencesStore: harness.preferences,
            notifications: PreviewNotifications(),
            clock: harness.clock,
            calendar: Fixture.calendar()
        )
        bare.refreshLoginItemStatus()
        #expect(bare.loginItemStatus == .unavailable)
        bare.setLaunchAtLogin(true)
        #expect(bare.banner?.kind == .warning)
    }

    @Test("Status is re-read on start, because System Settings can revoke it")
    func startReadsStatus() async throws {
        let harness = try Harness(loginItem: InMemoryLoginItemService(status: .enabled))
        await harness.model.start()
        #expect(harness.model.loginItemStatus == .enabled)
        harness.model.shutdown()
    }
}
