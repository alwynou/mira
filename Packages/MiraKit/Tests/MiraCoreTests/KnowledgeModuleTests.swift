import Foundation
import Testing
@testable import MiraCore

@Suite("Knowledge tools")
struct KnowledgeModuleTests {
    @Test func searchCarriesImmutableChunkSourcesAndBoundsSnippets() async throws {
        let fixture = KnowledgeFixture(); let tool = KnowledgeTools.readOnly(store: fixture)[0]
        let context = fixture.context
        let plan = try await tool.preparation.prepare(.object(["query": .string("notes")]), context: context)
        try plan.validate(); _ = try ToolSchemaValidator.decode(try plan.input.jsonString(), schema: tool.preparation.descriptor.outputSchema)
        #expect(plan.sources.count == 1)
        #expect({ if case .domain(let ns, _, let rev) = plan.sources[0] { return ns == KnowledgeSources.chunkNamespace && rev == 1 }; return false }())
        #expect(try plan.input.jsonString().utf8.count <= 28_000)
        if case .read(let read) = tool { _ = try await read.execute(plan, context: context) }
    }

    @Test func openMetadataDoesNotGrantChunkCitationAndReadChunkDoes() async throws {
        let fixture = KnowledgeFixture(); let tools = KnowledgeTools.readOnly(store: fixture)
        let open = try await tools[1].preparation.prepare(.object(["source_id": .string(fixture.source.id.rawValue.uuidString)]), context: fixture.context)
        _ = try ToolSchemaValidator.decode(try open.input.jsonString(), schema: tools[1].preparation.descriptor.outputSchema)
        #expect(open.sources == [KnowledgeSources.metadata(fixture.source)])
        let chunk = try await tools[2].preparation.prepare(.object(["chunk_id": .string(fixture.chunk.id.rawValue.uuidString)]), context: fixture.context)
        _ = try ToolSchemaValidator.decode(try chunk.input.jsonString(), schema: tools[2].preparation.descriptor.outputSchema)
        #expect(chunk.sources == [KnowledgeSources.chunk(fixture.chunk.summary)])
        #expect(chunk.input["content"]?.stringValue == fixture.chunk.text)
    }

    @Test func malformedOptionalVersionAndRequestedIDsFailClosed() async throws {
        let fixture = KnowledgeFixture(); let tools = KnowledgeTools.readOnly(store: fixture)
        await #expect(throws: MiraError.self) { _ = try await tools[1].preparation.prepare(.object(["source_id": .string(fixture.source.id.rawValue.uuidString), "version_id": .string("bad")]), context: fixture.context) }
        await #expect(throws: MiraError.self) { _ = try await tools[1].preparation.prepare(.object(["source_id": .string(UUID().uuidString)]), context: fixture.context) }
    }

    @Test func duplicateOversizedAndMismatchedStoreResultsAreRejected() async throws {
        let fixture = KnowledgeFixture(); let context = fixture.context
        let duplicate = KnowledgeTools.readOnly(store: BrokenKnowledgeStore(base: fixture, mode: .duplicate))[0]
        await #expect(throws: MiraError.self) { _ = try await duplicate.preparation.prepare(.object(["query": .string("notes")]), context: context) }
        let oversized = KnowledgeTools.readOnly(store: BrokenKnowledgeStore(base: fixture, mode: .oversized))[0]
        await #expect(throws: MiraError.self) { _ = try await oversized.preparation.prepare(.object(["query": .string("notes")]), context: context) }
        let mismatch = KnowledgeTools.readOnly(store: BrokenKnowledgeStore(base: fixture, mode: .mismatch))[1]
        await #expect(throws: MiraError.self) { _ = try await mismatch.preparation.prepare(.object(["source_id": .string(UUID().uuidString)]), context: context) }
    }

    @Test func openPaginatesTwoHundredSummariesAndRevalidationCanReject() async throws {
        let fixture = KnowledgeFixture(summaryCount: 200)
        let tool = KnowledgeTools.readOnly(store: fixture)[1]
        let plan = try await tool.preparation.prepare(.object(["source_id": .string(fixture.source.id.rawValue.uuidString)]), context: fixture.context)
        #expect(plan.sources == [KnowledgeSources.metadata(fixture.source)])
        if case .array(let chunks)? = plan.input["chunks"] { #expect(chunks.count == 40) } else { Issue.record("Open result omitted chunks") }
        let rejecting = KnowledgeTools.readOnly(store: RejectingKnowledgeStore(base: fixture))[1]
        let rejectedPlan = try await rejecting.preparation.prepare(.object(["source_id": .string(fixture.source.id.rawValue.uuidString)]), context: fixture.context)
        guard case .read(let read) = rejecting else { Issue.record("Expected a read tool"); return }
        await #expect(throws: MiraError.self) { _ = try await read.execute(rejectedPlan, context: fixture.context) }
    }

    @Test func prefetchUsesSixHundredByteSnippetsAndExactChunkSources() async throws {
        let fixture = KnowledgeFixture(); let request = AgentContextRequest(sessionID: fixture.context.evidence.reference.sessionID, executionID: fixture.context.executionID, workspaceID: nil, userText: "According to my notes, what does this say?", authorizationEpoch: 0, destination: .model(fixture.context.route))
        let items = try await KnowledgePrefetchContributor(store: fixture).contribute(to: request)
        try #require(items.count == 1); #expect(items[0].sources == [KnowledgeSources.chunk(fixture.chunk.summary)])
        #expect(items[0].text.contains(String(repeating: "x", count: 600))); #expect(!items[0].text.contains(String(repeating: "x", count: 601)))
    }

    @Test func moduleRegistersBothAuthoritiesAndTools() async throws {
        let registry = RuntimeRegistry<AgentCapability>(); let authorities = RuntimeRegistry<any AgentDomainSourceAuthority>(); let scope = RuntimeScope(kind: .application)
        let module = KnowledgeModule(registry: registry, store: KnowledgeFixture(), sourceAuthorities: authorities)
        try await module.activate(in: scope)
        let snapshot = try await registry.freeze()
        #expect(snapshot.entries.map(\.id) == ["knowledge.search", "source.open", "source.read_chunk"])
        let auth = try await authorities.freeze()
        #expect(Set(auth.entries.map(\.id)) == [KnowledgeSources.metadataNamespace, KnowledgeSources.chunkNamespace])
        await snapshot.release(); await auth.release()
        await scope.dispose()
    }
}

private struct KnowledgeFixture: KnowledgeReadStore, Sendable {
    let source: KnowledgeSource
    let version: KnowledgeSourceVersion
    let chunk: SourceChunk
    let summaryCount: Int
    init(summaryCount: Int = 1) {
        self.summaryCount = summaryCount
        let sid = KnowledgeSourceID(); let vid = SourceVersionID(); let cid = SourceChunkID(); let date = Date(timeIntervalSince1970: 1)
        source = KnowledgeSource(id: sid, workspaceID: nil, title: "Notes", currentVersionID: vid, allowsRemoteUse: true, createdAt: date, updatedAt: date)
        version = KnowledgeSourceVersion(id: vid, sourceID: sid, contentHash: String(repeating: "a", count: 64), byteCount: summaryCount * 1_200, parserVersion: "1", parseState: .ready, parseError: nil, createdAt: date)
        let summary = SourceChunkSummary(id: cid, sourceID: sid, sourceVersionID: vid, sequence: 0, startLine: 1, endLine: 1, startUTF8Offset: 0, endUTF8Offset: 1_200, headingPath: ["Notes"], contentHash: String(repeating: "b", count: 64))
        chunk = SourceChunk(summary: summary, text: String(repeating: "x", count: 1_200))
    }
    var context: AgentToolContext { .init(executionID: ExecutionID(), invocationID: UUID(), evidence: evidence, route: route) }
    private var evidence: SessionUserEvidence { let sid = ConversationID(); let bid = UUID(); return .init(reference: .init(sessionID: sid, originalExecutionID: ExecutionID(), userMessageID: MessageID(), admissionEventID: UUID(), admissionSequence: 1), workspaceID: nil, admittedAt: Date(timeIntervalSince1970: 1), timeZoneIdentifier: "UTC", text: "notes", observedHead: .init(cursor: .init(sessionID: sid, sequence: 1), batchID: bid), sessionAuthorizationEpoch: 0) }
    private var route: AgentModelRoute { .init(id: RouteID(), revision: 1, connectionID: ConnectionID(), connectionRevision: 1, modelDescriptorID: ModelDescriptorID(), modelRevision: 1, modelAuthorizationRevision: 1, adapter: .init(id: "test", revision: 1), invocationID: "test-invocation", invocationRevision: 1, endpointID: "test-endpoint", modelID: "test", credential: nil, contextWindow: 4096, maximumOutputTokens: 128, capabilities: .init(streamsText: true, callsTools: false, producesThinking: false), configuration: .object([:])) }
    func knowledgeSources(scope: KnowledgeReadScope, limit: Int) async throws -> [KnowledgeSource] { [source] }
    func knowledgeSource(_ id: KnowledgeSourceID, versionID: SourceVersionID?, scope: KnowledgeReadScope) async throws -> KnowledgeSourceDetail { .init(source: source, versions: [version], selectedVersion: version, chunks: (0..<summaryCount).map { index in var s = chunk.summary; s.id = index == 0 ? chunk.id : SourceChunkID(); s.sequence = index; s.startUTF8Offset = index * 1_200; s.endUTF8Offset = index * 1_200 + 1_200; return s }) }
    func sourceChunk(_ id: SourceChunkID, scope: KnowledgeReadScope) async throws -> SourceChunk { chunk }
    func searchKnowledge(query: String, scope: KnowledgeReadScope, limit: Int) async throws -> KnowledgeSearchResult { .init(hits: [.init(source: source, chunk: chunk.summary, snippet: chunk.text)]) }
    func sourceCitation(_ reference: SourceCitationReference, scope: KnowledgeReadScope) async throws -> SourceCitationDetail { .init(source: source, version: version, chunk: chunk) }
    func validateKnowledgeSources(_ sources: [AgentSourceReference], for request: AgentContextRequest) async throws {}
}

private struct BrokenKnowledgeStore: KnowledgeReadStore {
    enum Mode { case duplicate, oversized, mismatch }
    let base: KnowledgeFixture; let mode: Mode
    func knowledgeSources(scope: KnowledgeReadScope, limit: Int) async throws -> [KnowledgeSource] { try await base.knowledgeSources(scope: scope, limit: limit) }
    func knowledgeSource(_ id: KnowledgeSourceID, versionID: SourceVersionID?, scope: KnowledgeReadScope) async throws -> KnowledgeSourceDetail { try await base.knowledgeSource(id, versionID: versionID, scope: scope) }
    func sourceChunk(_ id: SourceChunkID, scope: KnowledgeReadScope) async throws -> SourceChunk { try await base.sourceChunk(id, scope: scope) }
    func searchKnowledge(query: String, scope: KnowledgeReadScope, limit: Int) async throws -> KnowledgeSearchResult {
        var hit = KnowledgeSearchHit(source: base.source, chunk: base.chunk.summary, snippet: base.chunk.text)
        switch mode {
        case .duplicate: return .init(hits: [hit, hit])
        case .oversized: hit.snippet = String(repeating: "z", count: 1_201)
        case .mismatch: hit.chunk.sourceID = KnowledgeSourceID()
        }
        return .init(hits: [hit])
    }
    func sourceCitation(_ reference: SourceCitationReference, scope: KnowledgeReadScope) async throws -> SourceCitationDetail { try await base.sourceCitation(reference, scope: scope) }
    func validateKnowledgeSources(_ sources: [AgentSourceReference], for request: AgentContextRequest) async throws {}
}

private struct RejectingKnowledgeStore: KnowledgeReadStore {
    let base: KnowledgeFixture
    func knowledgeSources(scope: KnowledgeReadScope, limit: Int) async throws -> [KnowledgeSource] { try await base.knowledgeSources(scope: scope, limit: limit) }
    func knowledgeSource(_ id: KnowledgeSourceID, versionID: SourceVersionID?, scope: KnowledgeReadScope) async throws -> KnowledgeSourceDetail { try await base.knowledgeSource(id, versionID: versionID, scope: scope) }
    func sourceChunk(_ id: SourceChunkID, scope: KnowledgeReadScope) async throws -> SourceChunk { try await base.sourceChunk(id, scope: scope) }
    func searchKnowledge(query: String, scope: KnowledgeReadScope, limit: Int) async throws -> KnowledgeSearchResult { try await base.searchKnowledge(query: query, scope: scope, limit: limit) }
    func sourceCitation(_ reference: SourceCitationReference, scope: KnowledgeReadScope) async throws -> SourceCitationDetail { try await base.sourceCitation(reference, scope: scope) }
    func validateKnowledgeSources(_ sources: [AgentSourceReference], for request: AgentContextRequest) async throws { throw MiraError(.unauthorized, "rejected") }
}
