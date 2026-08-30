import Foundation
import Testing
@testable import FocusdoroCore

@Suite("Task highlight maths")
struct TaskHighlightTests {
    private let ids = ["a", "b", "c"]

    @Test("An empty list has nothing to highlight")
    func empty() {
        #expect(TaskHighlight.next(.down, in: [], from: nil) == nil)
        #expect(TaskHighlight.resolve(current: "a", in: []) == nil)
    }

    @Test("The first arrow press enters the list from the end it points at")
    func firstPress() {
        #expect(TaskHighlight.next(.down, in: ids, from: nil) == "a")
        #expect(TaskHighlight.next(.up, in: ids, from: nil) == "c")
        // A highlight that no longer exists behaves like no highlight at all.
        #expect(TaskHighlight.next(.down, in: ids, from: "gone") == "a")
    }

    @Test("Moving wraps at both ends")
    func wraps() {
        #expect(TaskHighlight.next(.down, in: ids, from: "a") == "b")
        #expect(TaskHighlight.next(.down, in: ids, from: "c") == "a")
        #expect(TaskHighlight.next(.up, in: ids, from: "a") == "c")
        #expect(TaskHighlight.next(.up, in: ids, from: "b") == "a")
    }

    @Test("First and last jump straight to the ends")
    func ends() {
        #expect(TaskHighlight.next(.first, in: ids, from: "b") == "a")
        #expect(TaskHighlight.next(.last, in: ids, from: "b") == "c")
    }

    @Test("A dropped highlight falls back to the top of the list")
    func resolve() {
        #expect(TaskHighlight.resolve(current: "b", in: ids) == "b")
        // Typing a search can filter the highlighted task away mid-keystroke.
        #expect(TaskHighlight.resolve(current: "z", in: ids) == "a")
        #expect(TaskHighlight.resolve(current: nil, in: ids) == "a")
    }
}

@MainActor
private struct PickerHarness {
    let clock = MutableDateProvider(now: Fixture.date("2026-08-29 14:00:00"))
    let todoist = FakeTodoist()
    let tokens = InMemoryTokenStore()
    let preferences = InMemoryPreferencesStore()
    let sync: TodoistSync
    let model: AppModel

    init(tasks: [TodoistTask], scope: TaskDateScope = .all) async throws {
        try tokens.saveToken("test-token")
        await todoist.setTasks(tasks)
        await todoist.setProjects([TodoistProject(id: "p1", name: "Focusdoro", isInboxProject: false)])
        let store = try Fixture.store()
        sync = TodoistSync(client: todoist, tokenStore: tokens, clock: clock, calendar: Fixture.calendar())
        model = AppModel(
            sync: sync,
            engine: TimerEngine(clock: clock, persistence: InMemoryTimerStateStore(), preferences: preferences),
            orchestrator: CompletionOrchestrator(store: store, todoist: todoist, clock: clock),
            store: store,
            preferencesStore: preferences,
            notifications: PreviewNotifications(),
            clock: clock,
            calendar: Fixture.calendar()
        )
        model.taskDateScope = scope
        await sync.refresh()
    }
}

@Suite("Keyboard picking")
@MainActor
struct KeyboardPickingTests {
    private static let tasks = [
        Fixture.task("t1", "Ship CI", due: "2026-08-29"),
        Fixture.task("t2", "Write the spec", due: "2026-08-29"),
        Fixture.task("t3", "Review the PR", due: "2026-08-31"),
    ]

    @Test("The visible order is exactly what the list renders")
    func visibleOrder() async throws {
        let harness = try await PickerHarness(tasks: Self.tasks)
        let rendered = harness.sync.sections.flatMap { $0.tasks.map(\.id) }
        #expect(harness.model.visibleTaskIDs == rendered)
        #expect(Set(harness.model.visibleTaskIDs) == ["t1", "t2", "t3"])
    }

    @Test("While searching, the arrows walk the results")
    func searchOrder() async throws {
        let harness = try await PickerHarness(tasks: Self.tasks)
        harness.sync.searchQuery = "spec"
        #expect(harness.model.visibleTaskIDs == ["t2"])

        harness.model.moveHighlight(.down)
        #expect(harness.model.highlightedTaskID == "t2")
    }

    @Test("Arrowing moves through the list and wraps")
    func moving() async throws {
        let harness = try await PickerHarness(tasks: Self.tasks)
        let order = harness.model.visibleTaskIDs

        harness.model.moveHighlight(.down)
        #expect(harness.model.highlightedTaskID == order.first)
        harness.model.moveHighlight(.down)
        #expect(harness.model.highlightedTaskID == order[1])
        harness.model.moveHighlight(.up)
        #expect(harness.model.highlightedTaskID == order.first)
        harness.model.moveHighlight(.up)
        #expect(harness.model.highlightedTaskID == order.last)
    }

    @Test("A search that hides the highlight moves it back to the first result")
    func highlightFollowsTheList() async throws {
        let harness = try await PickerHarness(tasks: Self.tasks)
        harness.model.moveHighlight(.down)
        harness.model.moveHighlight(.down)
        let second = harness.model.highlightedTaskID

        harness.sync.searchQuery = "review"
        harness.model.moveHighlight(.down)
        #expect(harness.model.highlightedTaskID == "t3")
        #expect(harness.model.highlightedTaskID != second)
    }

    @Test("Return starts a focus session on the highlighted task")
    func activate() async throws {
        let harness = try await PickerHarness(tasks: Self.tasks)
        harness.sync.searchQuery = "review"
        await harness.model.activateHighlighted()

        #expect(harness.model.snapshot.task?.id == "t3")
        #expect(harness.model.snapshot.state == .focusing)
        #expect(harness.model.route == .timer)
        harness.model.shutdown()
    }

    @Test("Return with nothing highlighted takes the first row")
    func activateWithoutMoving() async throws {
        let harness = try await PickerHarness(tasks: Self.tasks)
        let first = harness.model.visibleTaskIDs.first
        await harness.model.activateHighlighted()
        #expect(harness.model.snapshot.task?.id == first)
        harness.model.shutdown()
    }

    @Test("Selecting without starting leaves the timer idle")
    func selectOnly() async throws {
        let harness = try await PickerHarness(tasks: Self.tasks)
        await harness.model.activateHighlighted(start: false)
        #expect(harness.model.snapshot.task != nil)
        #expect(harness.model.snapshot.state == .idle)
    }

    @Test("An empty list ignores Return")
    func activateEmpty() async throws {
        let harness = try await PickerHarness(tasks: [])
        await harness.model.activateHighlighted()
        #expect(harness.model.snapshot.task == nil)
        #expect(harness.model.snapshot.state == .idle)
    }

    @Test("Clicking a task highlights it too, so the keyboard resumes from there")
    func clickSetsTheHighlight() async throws {
        let harness = try await PickerHarness(tasks: Self.tasks)
        await harness.model.select(task: Self.tasks[2])
        #expect(harness.model.highlightedTaskID == "t3")

        harness.model.clearHighlight()
        #expect(harness.model.highlightedTaskID == nil)
    }

    @Test("A selected task carries its project into the session")
    func selectionSnapshotsTheProject() async throws {
        let harness = try await PickerHarness(tasks: Self.tasks)
        await harness.model.select(task: Self.tasks[0])
        // Recorded now, while the sync cache still knows the name: history has to keep
        // reading after the task is closed.
        #expect(harness.model.snapshot.task?.projectID == "p1")
        #expect(harness.model.snapshot.task?.projectName == "Focusdoro")
    }
}
