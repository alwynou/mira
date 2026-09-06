import Foundation
import Testing
import MiraCore
import MiraData

struct MemoryApplicationTests {
    @Test func aNewConversationUsesOnlyCurrentAuthorizedMemories() async throws {
        let fixture = try MemoryApplicationFixture()
        defer { fixture.cleanup() }
        let provider = MemoryCaptureProvider()
        let app = try MiraApplication(store: fixture.store, provider: provider)
        let workspace = try await app.createWorkspace(name: "Project A", background: "", allowsRemoteSend: true)
        let otherWorkspace = try await app.createWorkspace(name: "Project B", background: "", allowsRemoteSend: true)
        let global = try await fixture.create(app, "My preferred editor is Aurora.", scope: .global)
        let own = try await fixture.create(app, "This editor uses four spaces.", scope: .workspace(workspace))
        _ = try await fixture.create(app, "The secret editor is NeverLeak.", scope: .workspace(otherWorkspace))
        _ = try await fixture.create(app, "The local editor is PrivateOnly.", scope: .global, allowsRemoteUse: false)
        let candidate = try await fixture.create(app, "The candidate editor is NotConfirmed.", scope: .global)
        _ = try await app.changeMemoryState(candidate.id, workspaceID: nil, state: .candidate, expectedRevision: 1)

        let conversation = try await app.createConversation(workspaceID: workspace)
        let executionID = try await app.send(conversationID: conversation, text: "Which editor should I use?", routeID: fixture.route.id)
        try await memoryEventually { try fixture.store.execution(executionID)?.status.isTerminal == true }
        let request = try #require(provider.requests.first)
        let memoryReferences = request.contextInfo?.references.filter { $0.kind == "memory" } ?? []
        #expect(Set(memoryReferences.map(\.id)) == Set([global.id, own.id].map { $0.rawValue.uuidString }))
        #expect((request.system + request.messages.map(\.text).joined()).contains("Aurora"))
        #expect(!(request.system + request.messages.map(\.text).joined()).contains("NeverLeak"))
        #expect(!(request.system + request.messages.map(\.text).joined()).contains("PrivateOnly"))
        #expect(!(request.system + request.messages.map(\.text).joined()).contains("NotConfirmed"))
        #expect(try fixture.store.execution(executionID)?.status == .completed)
        _ = await app.shutdown()
    }

    @Test func forgettingDuringGenerationClearsDerivedBodiesAndPreventsLaterRecall() async throws {
        let fixture = try MemoryApplicationFixture()
        defer { fixture.cleanup() }
        let provider = MemoryCaptureProvider(keepsStreaming: true)
        let app = try MiraApplication(store: fixture.store, provider: provider)
        let memory = try await fixture.create(app, "The editor secret is AuroraPrivate.", scope: .global)
        let conversation = try await app.createConversation(workspaceID: nil)
        let executionID = try await app.send(conversationID: conversation, text: "Tell me about my editor.", routeID: fixture.route.id)
        try await memoryEventually { provider.requests.count == 1 }
        #expect((provider.requests[0].system + provider.requests[0].messages.map(\.text).joined()).contains("AuroraPrivate"))
        let receipt = try await app.forgetMemory(memory.id, workspaceID: nil, expectedRevision: memory.revision)
        #expect(receipt.redactedExecutionIDs.contains(executionID))
        _ = await app.shutdown()

        let detail = try fixture.store.memoryDetail(memory.id, workspaceID: nil)
        #expect(detail.memory.draft == nil)
        #expect(detail.evidence.allSatisfy { $0.excerpt == nil && $0.sourceHash == nil && $0.bodyPurgedAt != nil })
        #expect(detail.revisions.allSatisfy { $0.draft == nil && $0.bodyPurgedAt != nil })
        #expect(try fixture.store.attempts(for: executionID).allSatisfy { $0.request == nil && $0.output == nil && $0.bodyPurgedAt != nil })
        #expect(try fixture.store.execution(executionID)?.bodyPurgedAt != nil)
        #expect(try fixture.store.messages(in: conversation).contains { $0.role == .user && $0.text == "Tell me about my editor." })
        #expect(try fixture.store.messages(in: conversation).filter { $0.role == .assistant }.allSatisfy { $0.text.isEmpty })

        let secondProvider = MemoryCaptureProvider()
        let reopened = try MiraApplication(store: fixture.store, provider: secondProvider)
        let secondConversation = try await reopened.createConversation(workspaceID: nil)
        let secondExecution = try await reopened.send(conversationID: secondConversation, text: "Tell me about my editor.", routeID: fixture.route.id)
        try await memoryEventually { try fixture.store.execution(secondExecution)?.status.isTerminal == true }
        #expect(secondProvider.requests.count == 1)
        #expect(!(secondProvider.requests[0].system + secondProvider.requests[0].messages.map(\.text).joined()).contains("AuroraPrivate"))
        _ = await reopened.shutdown()
    }
}

private struct MemoryApplicationFixture {
    let directory: URL
    let store: SQLiteMiraStore
    let route: ResolvedModelRouteSnapshot
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("MiraMemoryApplication-\(UUID())")
        store = try SQLiteMiraStore(directory: directory)
        route = .init(name: "Memory fixture", providerKind: .openAICompatible, baseURL: "https://example.invalid/v1", modelID: "synthetic", credentialReference: "no-key", contextWindow: 65_536)
        try StoredRouteFixture(route).install(in: store)
    }
    func create(_ app: MiraApplication, _ content: String, scope: MemoryScope, allowsRemoteUse: Bool = true) async throws -> Memory {
        try await app.createMemory(draft: .init(content: content, scope: scope, allowsRemoteUse: allowsRemoteUse), source: .manualEntry(id: UUID(), statement: content), operationID: UUID()).memory
    }
    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}

private final class MemoryCaptureProvider: ModelProviderPort, @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [CanonicalModelRequest] = []
    private let keepsStreaming: Bool
    init(keepsStreaming: Bool = false) { self.keepsStreaming = keepsStreaming }
    var requests: [CanonicalModelRequest] { lock.withLock { captured } }
    func stream(request: CanonicalModelRequest, route: ResolvedModelRouteSnapshot) -> AsyncThrowingStream<CanonicalStreamEvent, any Error> {
        lock.withLock { captured.append(request) }
        return AsyncThrowingStream { continuation in
            continuation.yield(.textDelta("Synthetic answer about the editor."))
            if !keepsStreaming {
                continuation.yield(.finished(.stop))
                continuation.finish()
            }
        }
    }
}

private func memoryEventually(_ condition: () throws -> Bool) async throws {
    for _ in 0..<200 {
        if try condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw MiraError(.timeout, "Synthetic memory application condition was not reached.")
}
