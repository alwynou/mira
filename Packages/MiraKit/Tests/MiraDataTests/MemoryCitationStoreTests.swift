import Foundation
import MiraCore
import MiraData
import Testing

struct MemoryCitationStoreTests {
    @Test func referencesRequireUsageAndResolveTheExactHistoricalRevision() throws {
        let fixture = try CitationFixture()
        defer { fixture.cleanup() }
        let original = try fixture.createMemory("Preferred editor is Aurora.")
        let reference = MemoryCitationReference(memoryID: original.id, revision: original.revision)
        #expect(throws: MiraError.self) { try fixture.resolve(reference) }
        try fixture.store.recordMemoryUsage([.init(memoryID: original.id, revision: 1)], executionID: fixture.execution.id, at: .now)
        #expect(try fixture.resolve(reference).revision.draft?.content == original.draft?.content)

        var current = original
        // The ordinary detail history is bounded. Citations must still resolve older exact revisions.
        for index in 1...205 {
            var draft = try #require(current.draft)
            draft.content = "Editor revision \(index)"
            current = try fixture.store.reviseMemory(current.id, workspaceID: nil, draft: draft, expectedRevision: current.revision, at: .now)
        }
        let historic = try fixture.resolve(reference)
        #expect(historic.revision.revision == 1)
        #expect(historic.revision.draft?.content == original.draft?.content)
        #expect(historic.memory.revision == 206)
        #expect(throws: MiraError.self) { try fixture.resolve(.init(memoryID: original.id, revision: 2)) }
        #expect(throws: MiraError.self) {
            try fixture.store.memoryCitation(reference, executionID: fixture.execution.id, conversationID: ConversationID())
        }
        _ = try fixture.store.forgetMemory(current.id, workspaceID: nil, expectedRevision: current.revision, at: .now)
        #expect(throws: MiraError.self) { try fixture.resolve(reference) }
    }

    @Test func anotherExecutionCannotOpenAGuessedMemoryReference() throws {
        let fixture = try CitationFixture()
        defer { fixture.cleanup() }
        let memory = try fixture.createMemory("An authorized fact")
        try fixture.store.recordMemoryUsage([.init(memoryID: memory.id, revision: 1)], executionID: fixture.execution.id, at: .now)
        let other = Conversation(id: .init(), workspaceID: nil, title: "Other", createdAt: .now, updatedAt: .now)
        try fixture.store.createConversation(other)
        let execution = try fixture.store.enqueue(conversationID: other.id, text: "A different request", route: fixture.execution.route, executionID: .init(), messageID: .init(), at: .now)
        #expect(throws: MiraError.self) {
            try fixture.store.memoryCitation(.init(memoryID: memory.id, revision: 1), executionID: execution.id, conversationID: other.id)
        }
    }
}

private struct CitationFixture {
    let directory: URL
    let store: SQLiteMiraStore
    let execution: Execution
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("MiraCitation-\(UUID())")
        store = try SQLiteMiraStore(directory: directory)
        let connection = ProviderConnection(name: "Synthetic", providerKind: .openAICompatible, baseURL: "https://example.invalid/v1", credentialReference: "no-key")
        try store.saveConnection(connection, expectedRevision: nil)
        let model = ModelDescriptor(connectionID: connection.id, connectionRevision: connection.revision, modelID: "fixture", contextWindow: 65_536, textCapability: .declared)
        try store.saveModel(model, expectedRevision: nil)
        let route = ModelRoute(name: "Synthetic", modelDescriptorID: model.id)
        try store.saveRoute(route, expectedRevision: nil)
        let conversation = Conversation(id: .init(), workspaceID: nil, title: "Citation", createdAt: .now, updatedAt: .now)
        try store.createConversation(conversation)
        let resolved = try store.modelConfiguration().resolve(purpose: .conversation, explicitRouteID: route.id, conversation: conversation)
        execution = try store.enqueue(conversationID: conversation.id, text: "Tell me about the editor", route: resolved, executionID: .init(), messageID: .init(), at: .now)
    }
    func createMemory(_ content: String) throws -> Memory {
        try store.createMemory(draft: .init(content: content, scope: .global), source: .manualEntry(id: UUID(), statement: content), operationID: UUID(), replacing: nil, expectedRevision: nil, at: .now).memory
    }
    func resolve(_ reference: MemoryCitationReference) throws -> MemoryCitationDetail {
        try store.memoryCitation(reference, executionID: execution.id, conversationID: execution.conversationID)
    }
    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}
