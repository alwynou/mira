import Foundation
import MiraCore
import MiraData
import Testing

@Suite("Task presentation continuity")
@MainActor
struct TaskPresentationTests {
    @Test func reloadUsesWorkspaceScopeAndExcludesGlobalTasks() async throws {
        let fixture = try TaskPresentationFixture()
        defer { fixture.cleanup() }
        let workspace = Workspace(id: .init(), name: "Task workspace", background: "", allowsRemoteSend: false)
        try fixture.store.saveWorkspace(workspace, expectedRevision: nil)
        _ = try await fixture.application.saveTask(
            workspaceID: workspace.id,
            draft: TaskDraft(title: "Scoped task"), status: .open, expectedRevision: nil, operationID: UUID())
        _ = try await fixture.application.saveTask(
            workspaceID: nil,
            draft: TaskDraft(title: "Global task"), status: .open, expectedRevision: nil, operationID: UUID())

        let model = TaskModel(application: fixture.application, workspaceID: workspace.id)
        await model.reload()

        #expect(model.tasks.map(\.draft.title) == ["Scoped task"])
        #expect(model.proposals.isEmpty)
        #expect(model.error == nil)
        #expect(await fixture.application.shutdown())
    }

    @Test(arguments: [true, false])
    func statusActionUsesCurrentRevisionAndRespectsCompletedFilter(includeCompleted: Bool) async throws {
        let fixture = try TaskPresentationFixture()
        defer { fixture.cleanup() }
        let task = try await fixture.application.saveTask(
            workspaceID: nil, draft: TaskDraft(title: "Finish report"), status: .open,
            expectedRevision: nil, operationID: UUID())
        let model = TaskModel(application: fixture.application, workspaceID: nil)
        model.includeCompleted = includeCompleted
        await model.reload()
        await model.select(task.id)

        await model.changeStatus(task, to: .completed)

        let stored = try fixture.store.taskDetail(task.id, workspaceID: nil)
        #expect(stored.status == .completed)
        #expect(stored.revision == task.revision + 1)
        if includeCompleted {
            #expect(model.selectedTask?.status == .completed)
            #expect(model.selectedTask?.revision == stored.revision)
        } else {
            #expect(model.selectedTask == nil)
            #expect(model.tasks.isEmpty)
        }
        #expect(model.error == nil)
        #expect(await fixture.application.shutdown())
    }

    @Test func loadingTasksDoesNotInvokeProvider() async throws {
        let fixture = try TaskPresentationFixture()
        defer { fixture.cleanup() }
        let model = TaskModel(application: fixture.application, workspaceID: nil)

        await model.reload()

        #expect(model.error == nil)
        #expect(fixture.provider.streamCount == 0)
        #expect(await fixture.application.shutdown())
    }
}

@MainActor
private struct TaskPresentationFixture {
    let directory: URL
    let store: SQLiteMiraStore
    let provider: NoTaskPresentationRequests
    let application: MiraApplication

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("MiraTaskPresentation-\(UUID())")
        store = try SQLiteMiraStore(directory: directory)
        provider = NoTaskPresentationRequests()
        application = try MiraApplication(store: store, provider: provider)
    }

    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}

private final class NoTaskPresentationRequests: ModelProviderPort, @unchecked Sendable {
    private(set) var streamCount = 0

    func stream(request: CanonicalModelRequest, route: ResolvedModelRouteSnapshot) -> AsyncThrowingStream<CanonicalStreamEvent, any Error> {
        streamCount += 1
        Issue.record("Task presentation checks must not start model requests.")
        return AsyncThrowingStream { $0.finish(throwing: MiraError(.unsupported, "No model requests are expected.")) }
    }
}
