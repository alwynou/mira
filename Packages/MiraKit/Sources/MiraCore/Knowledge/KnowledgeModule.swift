import Foundation

/// Registers bounded Knowledge tools and distinct metadata and immutable chunk source authorities.
public struct KnowledgeModule: RuntimeModule {
    public let id = "mira.knowledge"
    public let dependencies: Set<String> = []
    private let registry: RuntimeRegistry<AgentCapability>
    private let sourceAuthorities: RuntimeRegistry<any AgentDomainSourceAuthority>
    private let store: any KnowledgeReadStore
    private let prefetch: Bool
    public init(registry: RuntimeRegistry<AgentCapability>, store: any KnowledgeReadStore, sourceAuthorities: RuntimeRegistry<any AgentDomainSourceAuthority>, prefetch: Bool = false) {
        self.registry = registry; self.store = store; self.sourceAuthorities = sourceAuthorities; self.prefetch = prefetch
    }
    public func activate(in scope: RuntimeScope) async throws {
        try await sourceAuthorities.register(id: KnowledgeSources.metadataNamespace, value: try KnowledgeSourceAuthority(store: store, namespace: KnowledgeSources.metadataNamespace), scope: scope)
        try await sourceAuthorities.register(id: KnowledgeSources.chunkNamespace, value: try KnowledgeSourceAuthority(store: store, namespace: KnowledgeSources.chunkNamespace), scope: scope)
        let tools = KnowledgeTools.readOnly(store: store)
        try await registry.register(id: "knowledge.search", value: .tool(tools[0]), scope: scope, order: 0)
        try await registry.register(id: "source.open", value: .tool(tools[1]), scope: scope, order: 1)
        try await registry.register(id: "source.read_chunk", value: .tool(tools[2]), scope: scope, order: 2)
        if prefetch { try await registry.register(id: "knowledge.prefetch", value: .context(KnowledgePrefetchContributor(store: store)), scope: scope, order: 3) }
    }
}

public struct KnowledgeSourceAuthority: AgentDomainSourceAuthority {
    private let store: any KnowledgeReadStore
    public let namespace: String

    public init(store: any KnowledgeReadStore, namespace: String) throws {
        guard namespace == KnowledgeSources.metadataNamespace || namespace == KnowledgeSources.chunkNamespace else {
            throw MiraError(.invalidInput, "The knowledge source namespace is invalid.")
        }
        self.store = store
        self.namespace = namespace
    }

    public func validate(_ sources: [AgentSourceReference], for request: AgentContextRequest) async throws {
        guard sources.allSatisfy({ if case .domain(let ns, _, let revision) = $0 { ns == namespace && revision > 0 } else { false } }) else { throw denied() }
        try await store.validateKnowledgeSources(sources, for: request)
    }
    private func denied() -> MiraError { .init(.unauthorized, "The knowledge source is unavailable for this destination.") }
}
