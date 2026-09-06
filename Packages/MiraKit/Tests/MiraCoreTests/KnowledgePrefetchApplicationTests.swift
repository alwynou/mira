import Foundation
import MiraCore
import MiraData
import Testing

@Suite("Knowledge prefetch application integration")
struct KnowledgePrefetchApplicationTests {
    @Test func ordinaryMarkdownQuestionPrefetchesCurrentChunkAndAuditsCitation() async throws {
        let fixture = try PrefetchApplicationFixture(remoteUse: true)
        defer { fixture.cleanup() }
        let provider = PrefetchApplicationProvider()
        let app = try fixture.application(provider: provider)
        let conversationID = try await app.createConversation(workspaceID: nil)
        let executionID = try await app.send(
            conversationID: conversationID,
            text: "According to my Markdown notes, what does the guide say about breakfast?",
            routeID: fixture.route.id
        )
        try await prefetchEventually { try fixture.store.execution(executionID)?.status == .completed }

        let request = try #require(provider.requests.first)
        #expect(request.messages.last?.text == "According to my Markdown notes, what does the guide say about breakfast?")
        #expect(request.messages.dropLast().contains { $0.role == .context && $0.text.contains("savory breakfast") })
        let reference = try #require(request.contextInfo?.references.first { $0.kind == "sourceChunk" })
        #expect(reference.id == fixture.chunk.id.rawValue.uuidString.lowercased())
        #expect(request.contextInfo?.references.contains {
            $0.kind == "sourceVersion" && $0.id == fixture.version.id.rawValue.uuidString.lowercased()
        } == true)

        let citation = try await app.sourceCitation(
            .init(versionID: fixture.version.id, chunkID: fixture.chunk.id),
            executionID: executionID,
            conversationID: conversationID
        )
        #expect(citation.chunk.text.contains("savory breakfast"))
        #expect(await app.shutdown())
    }

    @Test func localOnlySourceIsExcludedFromAutomaticPrefetch() async throws {
        let fixture = try PrefetchApplicationFixture(remoteUse: false)
        defer { fixture.cleanup() }
        let provider = PrefetchApplicationProvider()
        let app = try fixture.application(provider: provider)
        let conversationID = try await app.createConversation(workspaceID: nil)
        let executionID = try await app.send(
            conversationID: conversationID,
            text: "According to my Markdown notes, what does the guide say about breakfast?",
            routeID: fixture.route.id
        )
        try await prefetchEventually { try fixture.store.execution(executionID)?.status == .completed }

        let request = try #require(provider.requests.first)
        #expect(request.contextInfo?.references.contains { $0.kind == "sourceChunk" || $0.kind == "sourceVersion" } != true)
        #expect(request.messages.dropLast().contains { $0.role == .context && $0.text.contains("savory breakfast") } == false)
        #expect(await app.shutdown())
    }
}

private final class PrefetchApplicationProvider: ModelProviderPort, @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [CanonicalModelRequest] = []
    var requests: [CanonicalModelRequest] { lock.withLock { captured } }

    func stream(request: CanonicalModelRequest, route: ResolvedModelRouteSnapshot) -> AsyncThrowingStream<CanonicalStreamEvent, any Error> {
        lock.withLock { captured.append(request) }
        return AsyncThrowingStream { continuation in
            continuation.yield(.textDelta("Synthetic prefetch answer"))
            continuation.yield(.finished(.stop))
            continuation.finish()
        }
    }
}

private struct PrefetchApplicationFixture {
    let directory: URL
    let store: SQLiteMiraStore
    let route: ModelRoute
    let version: KnowledgeSourceVersion
    let chunk: SourceChunk

    init(remoteUse: Bool) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("mira-knowledge-prefetch-" + UUID().uuidString)
        store = try SQLiteMiraStore(directory: directory)
        let connection = ProviderConnection(name: "Synthetic", providerKind: .openAICompatible, baseURL: "https://example.invalid/v1", credentialReference: "fixture")
        try store.saveConnection(connection, expectedRevision: nil)
        let model = ModelDescriptor(id: .init(), connectionID: connection.id, connectionRevision: connection.revision, modelID: "fixture", contextWindow: 65_536, textCapability: .declared, toolCapability: .declared)
        try store.saveModel(model, expectedRevision: nil)
        route = ModelRoute(name: "Synthetic", modelDescriptorID: model.id)
        try store.saveRoute(route, expectedRevision: nil)
        try store.saveRouteBinding(.init(scope: .global, purpose: .conversation, routeID: route.id), expectedRevision: nil)

        let file = directory.appendingPathComponent("breakfast-guide.md")
        try Data("# Markdown Breakfast Guide\nI prefer a savory breakfast with eggs.\n".utf8).write(to: file)
        let receipt = try store.importMarkdownFile(file, workspaceID: nil, updating: nil, expectedRevision: nil, at: .now)
        if remoteUse {
            _ = try store.setSourceRemoteUse(receipt.source.id, workspaceID: nil, allowed: true, expectedRevision: receipt.source.revision, at: .now)
        }
        version = receipt.version
        let detail = try store.knowledgeSource(receipt.source.id, versionID: version.id, workspaceID: nil, connectionID: remoteUse ? connection.id : nil)
        chunk = try store.sourceChunk(try #require(detail.chunks.first).id, workspaceID: nil, connectionID: remoteUse ? connection.id : nil)
    }

    func application(provider: PrefetchApplicationProvider) throws -> MiraApplication {
        try MiraApplication(store: store, provider: provider, tools: ToolRegistry(KnowledgeTools.readOnly(store: store)))
    }

    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}

private func prefetchEventually(_ predicate: @escaping @Sendable () throws -> Bool) async throws {
    for _ in 0..<400 {
        if try predicate() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw MiraError(.timeout, "Knowledge prefetch application condition was not reached.")
}
