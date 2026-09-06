import Foundation
import MiraCore
import MiraData
import Testing

@Suite("Knowledge presentation continuity")
@MainActor
struct KnowledgePresentationTests {
    @Test func searchHitBeyondTheChunkListOpensItsExactVersionAndClearsOnNavigation() async throws {
        let fixture = try KnowledgePresentationFixture()
        defer { fixture.cleanup() }
        let sections = (0..<230).map { index in
            "# Section \(index)\n\n" + String(repeating: "Synthetic source text. ", count: 195) + "\n\n"
        }.joined() + "# Final section\n\nUNIQUE_TAIL_EVIDENCE\n"
        let imported = try await fixture.importText(sections)
        let model = KnowledgeModel(application: fixture.application, workspaceID: nil)
        await model.reload()
        model.query = "UNIQUE_TAIL_EVIDENCE"
        await model.search()
        let hit = try #require(model.searchHits.first)
        #expect(hit.chunk.sequence >= 200)

        await model.openSearchHit(hit)

        #expect(model.selectedDetail?.source.id == imported.source.id)
        #expect(model.selectedDetail?.selectedVersion?.id == hit.chunk.sourceVersionID)
        #expect(model.selectedDetail?.chunks.contains { $0.id == hit.chunk.id } == false)
        #expect(model.selectedChunk?.id == hit.chunk.id)
        #expect(model.selectedChunk?.text.contains("UNIQUE_TAIL_EVIDENCE") == true)
        await model.reload()
        #expect(model.selectedChunk?.id == hit.chunk.id)

        let updated = try await fixture.importText("# Replacement\n\nCurrent version content\n", updating: imported.source)
        await model.selectVersion(updated.version.id)
        #expect(model.selectedChunk == nil)
        await model.loadChunk(hit.chunk)
        #expect(model.selectedChunk == nil, "A stale chunk action cannot open a different version from the selected one.")
        model.updateWorkspace(WorkspaceID())
        #expect(model.selectedDetail == nil && model.selectedChunk == nil && model.searchHits.isEmpty)
        #expect(await fixture.application.shutdown())
    }

    @Test func deletingAnOpenLocalSourceClearsThePresentedChunk() async throws {
        let fixture = try KnowledgePresentationFixture()
        defer { fixture.cleanup() }
        let imported = try await fixture.importText("# Local\n\nLocal source body\n")
        let model = KnowledgeModel(application: fixture.application, workspaceID: nil)
        model.selectSource(imported.source.id)
        await model.loadSelectedDetail()
        await model.loadChunk(try #require(model.selectedDetail?.chunks.first))
        #expect(model.selectedChunk != nil)

        try await fixture.application.deleteKnowledgeSource(imported.source.id, workspaceID: nil,
                                                            expectedRevision: imported.source.revision)
        await model.reload()
        #expect(model.selectedDetail == nil && model.selectedChunk == nil)
        #expect(await fixture.application.shutdown())
    }

    @Test func deletionInvalidatesAnAuthorizedChunkReadThatReturnsLate() async throws {
        let fixture = try KnowledgePresentationFixture()
        defer { fixture.cleanup() }
        let imported = try await fixture.importText("# Delayed\n\nBody read before deletion\n")
        let application = fixture.application
        let gate = ChunkReadGate()
        let model = KnowledgeModel(application: application, workspaceID: nil, readChunk: { id, scope in
            let chunk = try await application.sourceChunk(id, workspaceID: scope)
            await gate.wait()
            return chunk
        })
        model.selectSource(imported.source.id)
        await model.loadSelectedDetail()
        let summary = try #require(model.selectedDetail?.chunks.first)
        let reading = Task { await model.loadChunk(summary) }
        do {
            try await presentationEventually { await gate.isWaiting }
            await model.delete(imported.source)
            #expect(model.selectedID == nil && model.selectedChunk == nil)
        } catch {
            await gate.release()
            await reading.value
            throw error
        }
        await gate.release()
        await reading.value
        #expect(model.selectedID == nil && model.selectedDetail == nil && model.selectedChunk == nil)
        #expect(await application.shutdown())
    }

    @Test(arguments: [false, true])
    func openAndReopenedCitationsLoseTheirBodyAfterRevocationOrDeletion(delete: Bool) async throws {
        let fixture = try KnowledgePresentationFixture()
        defer { fixture.cleanup() }
        let imported = try await fixture.importText("# Evidence\n\nRevocable source body\n")
        let context = try await fixture.citation(for: imported)
        let model = SourceCitationModel()
        let observation = Task {
            await model.observe(application: fixture.application, reference: context.reference,
                                executionID: context.execution.id, conversationID: context.execution.conversationID)
        }
        defer { observation.cancel() }
        try await presentationEventually { model.detail?.chunk.text.contains("Revocable source body") == true }

        if delete {
            try await fixture.application.deleteKnowledgeSource(context.source.id, workspaceID: nil,
                                                                expectedRevision: context.source.revision)
        } else {
            _ = try await fixture.application.setSourceRemoteUse(context.source.id, workspaceID: nil,
                                                                allowed: false, expectedRevision: context.source.revision)
        }
        try await presentationEventually { model.detail == nil && model.error != nil }
        observation.cancel()
        await observation.value
        #expect(model.detail == nil)

        let reopened = Task {
            await model.observe(application: fixture.application, reference: context.reference,
                                executionID: context.execution.id, conversationID: context.execution.conversationID)
        }
        defer { reopened.cancel() }
        try await presentationEventually { model.error != nil }
        #expect(model.detail == nil, "Opening again must resolve current policy instead of reusing a prefetched body.")
        reopened.cancel()
        await reopened.value
        #expect(await fixture.application.shutdown())
    }

    @Test func visibleCitationKeepsHistoricalBytesAndChecksTheReplyIdentity() async throws {
        let fixture = try KnowledgePresentationFixture()
        defer { fixture.cleanup() }
        let imported = try await fixture.importText("# History\n\nOriginal evidence\n")
        let context = try await fixture.citation(for: imported)
        let model = SourceCitationModel()
        let first = Task {
            await model.observe(application: fixture.application, reference: context.reference,
                                executionID: context.execution.id, conversationID: context.execution.conversationID)
        }
        defer { first.cancel() }
        try await presentationEventually { model.detail != nil }
        let updated = try await fixture.importText("# History\n\nReplacement evidence\n", updating: context.source)
        try await presentationEventually { model.detail?.source.revision == updated.source.revision }
        #expect(model.detail?.version.id == imported.version.id)
        #expect(model.detail?.chunk.text.contains("Original evidence") == true)

        let other = Task {
            await model.observe(application: fixture.application, reference: context.reference,
                                executionID: context.execution.id, conversationID: ConversationID())
        }
        defer { other.cancel() }
        try await presentationEventually { model.error != nil }
        first.cancel()
        await first.value
        #expect(model.detail == nil && model.error != nil)
        other.cancel()
        await other.value
        #expect(model.detail == nil && model.error == nil)
        #expect(await fixture.application.shutdown())
    }
}

@MainActor
private struct KnowledgePresentationFixture {
    let directory: URL
    let store: SQLiteMiraStore
    let application: MiraApplication

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("MiraKnowledgePresentation-\(UUID())")
        store = try SQLiteMiraStore(directory: directory)
        application = try MiraApplication(store: store, provider: NoPresentationRequests())
    }

    func importText(_ text: String, updating source: KnowledgeSource? = nil) async throws -> KnowledgeImportReceipt {
        let file = directory.appendingPathComponent("fixture.md")
        try Data(text.utf8).write(to: file)
        return try await application.importMarkdownFile(file, workspaceID: nil,
                                                       updating: source?.id, expectedRevision: source?.revision)
    }

    func citation(for imported: KnowledgeImportReceipt) async throws
        -> (source: KnowledgeSource, reference: SourceCitationReference, execution: Execution) {
        let source = try await application.setSourceRemoteUse(imported.source.id, workspaceID: nil, allowed: true,
                                                             expectedRevision: imported.source.revision)
        let detail = try await application.knowledgeSource(source.id, workspaceID: nil)
        let chunk = try #require(detail.chunks.first)
        let connection = ProviderConnection(name: "Synthetic", providerKind: .openAICompatible,
                                            baseURL: "https://fixture.invalid/v1", credentialReference: "unused")
        try store.saveConnection(connection, expectedRevision: nil)
        let descriptor = ModelDescriptor(connectionID: connection.id, modelID: "fixture",
                                         contextWindow: 65_536, textCapability: .declared)
        try store.saveModel(descriptor, expectedRevision: nil)
        let route = ModelRoute(name: "Synthetic", modelDescriptorID: descriptor.id)
        try store.saveRoute(route, expectedRevision: nil)
        let conversation = Conversation(id: .init(), workspaceID: nil, title: "Synthetic citation",
                                        createdAt: .now, updatedAt: .now)
        try store.createConversation(conversation)
        let resolved = try store.modelConfiguration().resolve(purpose: .conversation, explicitRouteID: route.id,
                                                              conversation: conversation)
        let execution = try store.enqueue(conversationID: conversation.id, text: "Show source evidence", route: resolved,
                                          executionID: .init(), messageID: .init(), at: .now)
        try store.recordSourceUsage([.init(sourceID: source.id, sourceVersionID: imported.version.id, chunkID: chunk.id)],
                                    executionID: execution.id, at: .now)
        _ = try store.finish(executionID: execution.id, status: .completed, text: chunk.citation, usage: .init(),
                             error: nil, assistantMessageID: .init(), at: .now)
        return (source, .init(versionID: imported.version.id, chunkID: chunk.id), execution)
    }

    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}

private struct NoPresentationRequests: ModelProviderPort {
    func stream(request: CanonicalModelRequest, route: ResolvedModelRouteSnapshot) -> AsyncThrowingStream<CanonicalStreamEvent, any Error> {
        Issue.record("Presentation checks must not start model requests.")
        return AsyncThrowingStream { $0.finish(throwing: MiraError(.unsupported, "No model requests are expected.")) }
    }
}

@MainActor
private func presentationEventually(_ condition: () async -> Bool) async throws {
    for _ in 0..<400 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw MiraError(.timeout, "Presentation state did not reach the expected condition.")
}

private actor ChunkReadGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isReleased = false
    private(set) var isWaiting = false

    func wait() async {
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            isWaiting = true
        }
    }

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}
