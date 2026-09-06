import Foundation
import MiraCore
import MiraData
import Testing

@Suite("Memory presentation continuity")
@MainActor
struct MemoryPresentationTests {
    @Test func deepLinkClearsSearchKeepsDetailOutsideBoundedListAndClearsOnFilterChange() async throws {
        let fixture = try MemoryPresentationFixture()
        defer { fixture.cleanup() }
        for index in 0..<101 {
            let content = "Synthetic memory \(index)"
            let draft = MemoryDraft(content: content, scope: .global)
            _ = try fixture.store.createMemory(draft: draft, source: .manualEntry(id: UUID(), statement: content),
                                                operationID: UUID(), replacing: nil, expectedRevision: nil, at: Date())
        }
        let all = try fixture.store.memoryList(workspaceID: nil, states: [.active], query: "", limit: 200)
        let target = try #require(all.memories.last)
        let model = MemoryModel(application: fixture.application, workspaceID: nil)
        model.query = "stale search"
        model.selectInitialMemory(target.id)

        await model.reload()

        #expect(model.query.isEmpty)
        #expect(model.filter == .all)
        #expect(model.selectedID == target.id)
        #expect(model.selectedDetail?.memory.id == target.id)
        #expect(!model.memories.contains(where: { $0.id == target.id }))
        #expect(model.error == nil)

        model.filter = .active
        await model.reload()
        #expect(model.selectedID == nil)
        #expect(model.selectedDetail == nil)
        #expect(await fixture.application.shutdown())
    }

    @Test func failedDeepLinkClearsSelectionAndLeavesAnActionableError() async throws {
        let fixture = try MemoryPresentationFixture()
        defer { fixture.cleanup() }
        let model = MemoryModel(application: fixture.application, workspaceID: nil)
        model.selectInitialMemory(MemoryID())

        await model.reload()

        #expect(model.selectedID == nil)
        #expect(model.selectedDetail == nil)
        #expect(model.error?.code == .notFound)
        await model.reload()
        #expect(model.error?.code == .notFound, "Background refresh must preserve the failed navigation error until it is dismissed.")
        model.error = nil
        #expect(model.selectedID == nil && model.selectedDetail == nil)
        #expect(await fixture.application.shutdown())
    }

    @Test func deepLinkOutsideSelectedWorkspaceIsDenied() async throws {
        let fixture = try MemoryPresentationFixture()
        defer { fixture.cleanup() }
        let workspace = Workspace(id: .init(), name: "Private workspace")
        try fixture.store.saveWorkspace(workspace, expectedRevision: nil)
        let memory = try fixture.store.createMemory(
            draft: .init(content: "Workspace-only memory", scope: .workspace(workspace.id)),
            source: .manualEntry(id: UUID(), statement: "Workspace-only memory"), operationID: UUID(), replacing: nil,
            expectedRevision: nil, at: .now).memory
        let model = MemoryModel(application: fixture.application, workspaceID: nil)
        model.selectInitialMemory(memory.id)

        await model.reload()

        #expect(model.selectedID == nil)
        #expect(model.selectedDetail == nil)
        #expect(model.error?.code == .notFound)
        #expect(await fixture.application.shutdown())
    }

    @Test func statusAndForgetMutationsRefreshThePresentedMemory() async throws {
        let fixture = try MemoryPresentationFixture()
        defer { fixture.cleanup() }
        let memory = try fixture.store.createMemory(
            draft: .init(content: "Mutable memory", scope: .global),
            source: .manualEntry(id: UUID(), statement: "Mutable memory"), operationID: UUID(), replacing: nil,
            expectedRevision: nil, at: .now).memory
        let model = MemoryModel(application: fixture.application, workspaceID: nil)
        model.selectInitialMemory(memory.id)
        await model.reload()
        #expect(model.selectedDetail?.memory.state == .active)

        let archived = try await fixture.application.changeMemoryState(memory.id, workspaceID: nil, state: .archived,
                                                                        expectedRevision: memory.revision)
        await model.refreshAfterMutation()
        #expect(model.selectedDetail?.memory.state == .archived)
        #expect(model.selectedDetail?.memory.revision == archived.revision)

        _ = try await fixture.application.forgetMemory(memory.id, workspaceID: nil, expectedRevision: archived.revision)
        await model.refreshAfterMutation()
        #expect(model.selectedDetail?.memory.draft == nil)
        #expect(model.selectedDetail?.memory.forgottenAt != nil)
        #expect(await fixture.application.shutdown())
    }
}

@MainActor
private struct MemoryPresentationFixture {
    let directory: URL
    let store: SQLiteMiraStore
    let application: MiraApplication

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("MiraMemoryPresentation-\(UUID())")
        store = try SQLiteMiraStore(directory: directory)
        application = try MiraApplication(store: store, provider: NoMemoryPresentationRequests())
    }

    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}

private struct NoMemoryPresentationRequests: ModelProviderPort {
    func stream(request: CanonicalModelRequest, route: ResolvedModelRouteSnapshot) -> AsyncThrowingStream<CanonicalStreamEvent, any Error> {
        Issue.record("Memory presentation checks must not start model requests.")
        return AsyncThrowingStream { $0.finish(throwing: MiraError(.unsupported, "No model requests are expected.")) }
    }
}
