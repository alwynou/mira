import Foundation
import Testing
@testable import MiraCore

@Suite("Memory runtime module")
struct MemoryModuleTests {
    @Test func descriptorsExposeBoundedSchemasAndDirectCapabilities() throws {
        let descriptors = [
            AgentToolDescriptor(definition: MemoryTools.searchDefinition, revision: 1,
                                outputSchema: MemoryTools.searchResultSchema, executionMode: .parallelSafe,
                                timeoutMilliseconds: 30_000, maximumResultBytes: 32_768),
            AgentToolDescriptor(definition: MemoryTools.getDefinition, revision: 1,
                                outputSchema: MemoryTools.getResultSchema, executionMode: .parallelSafe,
                                timeoutMilliseconds: 30_000, maximumResultBytes: 32_768),
            AgentToolDescriptor(definition: MemoryTools.rememberDefinition, revision: 4,
                                outputSchema: MemoryTools.rememberResultSchema, executionMode: .exclusive,
                                timeoutMilliseconds: 120_000, maximumResultBytes: 4_096),
            AgentToolDescriptor(definition: MemoryTools.retractDefinition, revision: 1,
                                outputSchema: MemoryTools.retractResultSchema, executionMode: .exclusive,
                                timeoutMilliseconds: 120_000, maximumResultBytes: 4_096)
        ]
        for descriptor in descriptors { try descriptor.validate() }
        #expect(MemoryTools.searchDefinition.name == "memory.search")
        #expect(MemoryTools.getDefinition.name == "memory.get")
        #expect(MemoryTools.rememberDefinition.name == "memory.remember")
        #expect(MemoryTools.rememberDefinition.inputSchema["additionalProperties"] == .bool(false))
    }

    @Test func activationRegistersMemoryToolsContributorAndAuthorityInOneScope() async throws {
        let tools = RuntimeRegistry<AgentCapability>()
        let authorities = RuntimeRegistry<any AgentDomainSourceAuthority>()
        let store = ModuleMemoryStore()
        let scope = RuntimeScope(kind: .application)
        let module = MemoryModule(registry: tools, store: store, sourceAuthorities: authorities)
        try await module.activate(in: scope)

        let toolSnapshot = try await tools.freeze()
        let authoritySnapshot = try await authorities.freeze()
        do {
            #expect(toolSnapshot.entries.map(\.id) == ["memory.search", "memory.get", "memory.remember", "memory.retract", "memory.delete", "memory.recall"])
            #expect(authoritySnapshot.entries.map(\.id) == ["memories"])
        }
        await toolSnapshot.release()
        await authoritySnapshot.release()
        await scope.dispose()
    }

    @Test func recallPlannerDoesNotExpandUnrelatedText() {
        let expansion = MemoryRecallPlanner.expand(query: "Tell me about a random topic")
        #expect(expansion.aliasTerms.isEmpty)
        #expect(expansion.matchedTopics.isEmpty)
    }
}

private actor ModuleMemoryStore: MemoryReadStore {
    func memoryContextNotices(references: [MemoryCitationReference], workspaceID: WorkspaceID?, connectionID: ConnectionID?, at: Date) -> [MemoryContextNotice] { [] }
    func memoryList(workspaceID: WorkspaceID?, states: Set<MemoryState>, query: String, limit: Int) async throws -> MemorySearchResult { .init(memories: []) }
    func memoryDetail(_ id: MemoryID, workspaceID: WorkspaceID?) async throws -> MemoryDetail { throw MiraError(.notFound, "Memory fixture has no records.") }
    func memoryManagementPage(_ query: MemoryManagementQuery, at: Date) async throws -> MemoryManagementPage { .init(memories: [], nextCursor: nil) }
    func memoryCitationRevision(_ reference: MemoryCitationReference, workspaceID: WorkspaceID?) async throws -> MemoryCitationDetail { throw MiraError(.notFound, "Memory fixture has no records.") }
    func recallMemories(query: String, request: AgentContextRequest, limit: Int, at: Date) async throws -> MemorySearchResult { .init(memories: []) }
    func recallMemory(_ id: MemoryID, request: AgentContextRequest, at: Date) async throws -> Memory { throw MiraError(.notFound, "Memory fixture has no records.") }
    func validateMemorySources(_ sources: [AgentSourceReference], for request: AgentContextRequest, at: Date) async throws {}
    func validateMemoryContextSources(_ sources: [AgentSourceReference], for request: AgentContextRequest, at: Date) async throws {}
    func suppressedMemorySources() async throws -> [MemoryEvidenceSource] { [] }
}
