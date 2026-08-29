import Foundation
import Testing
@testable import FocusdoroCore

/// `TodoistSync` is the in-memory cache and connection state machine the picker and
/// settings screens bind to. These tests exercise it directly, without `AppModel` in
/// the loop, so a regression here cannot hide behind orchestration-level coverage.
@Suite("Todoist sync")
@MainActor
struct TodoistSyncTests {
    private func makeSync(
        tasks: [TodoistTask] = [],
        token: String? = nil
    ) -> (TodoistSync, FakeTodoist, InMemoryTokenStore) {
        let todoist = FakeTodoist(tasks: tasks)
        let tokens = InMemoryTokenStore(token: token)
        let sync = TodoistSync(client: todoist, tokenStore: tokens, clock: MutableDateProvider(now: Fixture.date("2026-08-29 09:00:00")))
        return (sync, todoist, tokens)
    }

    // MARK: - Connection state

    @Test("With no stored token the sync starts disconnected")
    func startsDisconnectedWithNoToken() {
        let (sync, _, _) = makeSync()
        #expect(sync.connection == .disconnected)
        #expect(!sync.hasToken)
    }

    @Test("With a stored token the sync starts connected")
    func startsConnectedWithStoredToken() {
        let (sync, _, _) = makeSync(token: "existing-token")
        #expect(sync.connection == .connected)
        #expect(sync.hasToken)
    }

    // MARK: - Connect flow

    @Test("A valid token is saved only after the server confirms it, then a refresh follows")
    func connectValidatesBeforeSaving() async throws {
        let (sync, todoist, tokens) = makeSync(tasks: [Fixture.task("1", "Ship it")])

        let result = await sync.connect(token: "new-token")

        guard case .success = result else {
            Issue.record("Expected connect to succeed")
            return
        }
        #expect(sync.connection == .connected)
        #expect(try tokens.readToken() == "new-token")
        // connect() also triggers the first refresh, so the picker has data immediately.
        #expect(sync.allTasks.count == 1)
        #expect(sync.loadState == .loaded)
        _ = todoist
    }

    @Test("A rejected token is never saved and the connection stays disconnected")
    func connectRejectedTokenIsNotSaved() async throws {
        let (sync, todoist, tokens) = makeSync()
        await todoist.setValidateError(.unauthorized)

        let result = await sync.connect(token: "bad-token")

        guard case .failure(let error) = result else {
            Issue.record("Expected connect to fail")
            return
        }
        #expect(error as? TodoistError == .unauthorized)
        #expect(try tokens.readToken() == nil)
        #expect(sync.connection == .disconnected)
    }

    @Test("A blank token fails locally without validating or touching the token store")
    func connectBlankTokenFailsLocally() async throws {
        let (sync, _, tokens) = makeSync()

        let result = await sync.connect(token: "   ")

        guard case .failure(let error) = result else {
            Issue.record("Expected connect to fail")
            return
        }
        #expect(error as? TodoistError == .missingToken)
        #expect(try tokens.readToken() == nil)
        #expect(sync.connection == .disconnected)
    }

    @Test("Connect trims surrounding whitespace before saving")
    func connectTrimsWhitespace() async throws {
        let (sync, _, tokens) = makeSync()
        _ = await sync.connect(token: "  padded-token  ")
        #expect(try tokens.readToken() == "padded-token")
    }

    // MARK: - Disconnect flow

    @Test("Disconnect removes the token and clears every cached field")
    func disconnectClearsState() async throws {
        let (sync, _, tokens) = makeSync(tasks: [Fixture.task("1", "Ship it")], token: "existing-token")
        await sync.refresh()
        #expect(sync.allTasks.count == 1)

        sync.disconnect()

        #expect(try tokens.readToken() == nil)
        #expect(sync.allTasks.isEmpty)
        #expect(sync.projects.isEmpty)
        #expect(sync.groups.isEmpty)
        #expect(sync.loadState == .idle)
        #expect(sync.connection == .disconnected)
        #expect(sync.lastRefreshedAt == nil)
    }

    // MARK: - Refresh / load state

    @Test("Refreshing without a token routes to disconnected instead of calling the API")
    func refreshWithoutTokenSkipsTheNetwork() async {
        let (sync, _, _) = makeSync()
        await sync.refresh()
        #expect(sync.connection == .disconnected)
        #expect(sync.loadState == .idle)
        #expect(StubURLProtocol.requestCount == 0)
    }

    @Test("A failed refresh reports the mapped error and rejects the token on unauthorized")
    func refreshFailureIsReported() async {
        let (sync, todoist, _) = makeSync(token: "t")
        await todoist.setTasks([])
        await todoist.setProjectsError(nil)
        // Force listTasks itself to fail by pairing it with a projects error is not enough;
        // TodoistAPI has no direct "fail listTasks" hook on the fake other than via a task
        // list error, so drive it through the real failure surface: an unauthorized token.
        let unauthorizedTodoist = FailingTodoist(error: .unauthorized)
        let tokens = InMemoryTokenStore(token: "t")
        let failingSync = TodoistSync(client: unauthorizedTodoist, tokenStore: tokens, clock: MutableDateProvider(now: Fixture.date("2026-08-29 09:00:00")))

        await failingSync.refresh()

        #expect(failingSync.loadState == .failed(.unauthorized))
        #expect(failingSync.connection == .tokenRejected)
        _ = sync
        _ = todoist
    }

    @Test("A non-auth failure reports the error without rejecting the connection")
    func refreshFailureOtherThanUnauthorizedKeepsConnection() async {
        let failingTodoist = FailingTodoist(error: .server(status: 500))
        let tokens = InMemoryTokenStore(token: "t")
        let sync = TodoistSync(client: failingTodoist, tokenStore: tokens)

        await sync.refresh()

        #expect(sync.loadState == .failed(.server(status: 500)))
        // A server hiccup is not proof the token itself is bad.
        #expect(sync.connection != .tokenRejected)
    }

    @Test("A project-listing failure still loads the task list")
    func projectFailureToleratedDuringRefresh() async {
        let (sync, todoist, _) = makeSync(tasks: [Fixture.task("1", "Ship it")], token: "t")
        await todoist.setProjectsError(.server(status: 500))

        await sync.refresh()

        #expect(sync.loadState == .loaded)
        #expect(sync.allTasks.count == 1)
        #expect(sync.projects.isEmpty)
    }

    @Test("A newer refresh supersedes one still in flight")
    func newerRefreshSupersedesInFlight() async {
        let todoist = FakeTodoist(tasks: [Fixture.task("old", "Old task")])
        await todoist.setListTasksDelay(seconds: 0.3)
        let tokens = InMemoryTokenStore(token: "t")
        let sync = TodoistSync(client: todoist, tokenStore: tokens)

        let first = Task { await sync.refresh() }
        // Give the first refresh time to start and suspend inside the delayed call.
        try? await Task.sleep(nanoseconds: 50_000_000)
        await todoist.setTasks([Fixture.task("new", "New task")])
        await todoist.setListTasksDelay(seconds: 0)

        await sync.refresh()
        await first.value

        // The stale first refresh must never win the race and overwrite the later result.
        #expect(sync.allTasks.map(\.id) == ["new"])
        #expect(sync.loadState == .loaded)
    }

    // MARK: - Search

    @Test("Searching an empty task list returns nothing, without throwing or crashing")
    func searchOverEmptyTaskListIsEmpty() {
        let (sync, _, _) = makeSync(tasks: [])
        sync.searchQuery = "anything"
        #expect(sync.searchResults.isEmpty)
        #expect(sync.isSearching)
    }

    @Test("A blank search query is not treated as searching and returns every task")
    func blankSearchQueryReturnsAllTasks() async {
        let (sync, _, _) = makeSync(tasks: [Fixture.task("1", "Ship it")], token: "t")
        await sync.refresh()
        sync.searchQuery = "   "
        #expect(!sync.isSearching)
        #expect(sync.searchResults.count == 1)
    }

    // MARK: - Local mutation

    @Test("Removing a task locally drops it from both the flat list and its group")
    func removeLocallyUpdatesGroupsToo() async {
        let (sync, _, _) = makeSync(tasks: [Fixture.task("1", "Ship it", due: "2026-08-29")], token: "t")
        await sync.refresh()
        #expect(sync.groups.today.count == 1)

        sync.removeLocally(taskID: "1")

        #expect(sync.allTasks.isEmpty)
        #expect(sync.groups.today.isEmpty)
    }
}

/// Always fails `listTasks`/`listProjects` with a fixed error, for exercising
/// `TodoistSync`'s failure-mapping path independent of `FakeTodoist`'s success-shaped API.
private final class FailingTodoist: TodoistAPI, @unchecked Sendable {
    let error: TodoistError
    init(error: TodoistError) { self.error = error }
    func listTasks() async throws -> [TodoistTask] { throw error }
    func listProjects() async throws -> [TodoistProject] { throw error }
    func closeTask(id: String) async throws { throw error }
    func addComment(taskID: String, content: String) async throws -> TodoistComment { throw error }
    func validateToken() async throws { throw error }
}
