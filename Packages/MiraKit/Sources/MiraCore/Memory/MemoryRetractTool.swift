import Foundation

public struct MemoryRetractionProposal: Sendable, Equatable {
    public let target: MemoryUsage
    public let quote: String
    public init(target: MemoryUsage, quote: String) { self.target = target; self.quote = quote }
}

/// Prepares an exact, no-replacement withdrawal. The Data handler owns the atomic commit.
public struct MemoryRetractTool: AgentLocalWriteTool {
    private let store: any MemoryReadStore
    private let now: @Sendable () -> Date

    public init(store: any MemoryReadStore, now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store; self.now = now
    }
    public var policy: AgentToolPolicyRequirement { .constrained(MemoryRetractPolicy(store: store, now: now)) }
    public var businessNamespace: String { "memory.retract" }
    public var descriptor: AgentToolDescriptor {
        .init(definition: MemoryTools.retractDefinition, revision: 1,
              outputSchema: MemoryTools.retractResultSchema, executionMode: .exclusive,
              timeoutMilliseconds: 120_000, maximumResultBytes: 4_096)
    }

    public func prepare(_ arguments: JSONValue, context: AgentToolContext) async throws -> AgentToolPlan {
        let normalized = try ToolSchemaValidator.decode(try arguments.jsonString(), schema: descriptor.definition.inputSchema)
        let proposal = try MemoryTools.parsedRetraction(arguments: normalized, evidence: context.evidence)
        let request = try MemoryTools.request(context)
        let memory = try await store.recallMemory(proposal.target.memoryID, request: request, at: now())
        guard memory.revision == proposal.target.revision, memory.state == .active, memory.isCurrent,
              memory.draft != nil else { throw MiraError(.conflict, "The memory revision is out of date.") }
        let reference = AgentSourceReference.domain(namespace: "memories", id: memory.id.rawValue, revision: memory.revision)
        return .init(input: normalized, sources: [reference], targets: [reference])
    }
}

private struct MemoryRetractPolicy: AgentToolPolicy {
    let store: any MemoryReadStore
    let now: @Sendable () -> Date

    func evaluate(_ proposal: AgentToolProposal, context: AgentToolContext) async throws -> AgentToolPolicyDecision {
        try await validate(proposal, context: context); return .allow
    }
    func validate(_ proposal: AgentToolProposal, context: AgentToolContext) async throws {
        let parsed = try MemoryTools.parsedRetraction(arguments: proposal.plan.input, evidence: context.evidence)
        let request = try MemoryTools.request(context)
        let memory = try await store.recallMemory(parsed.target.memoryID, request: request, at: now())
        guard memory.revision == parsed.target.revision, memory.state == .active, memory.isCurrent,
              memory.draft != nil else { throw MiraError(.conflict, "The memory revision is out of date.") }
        let reference = AgentSourceReference.domain(namespace: "memories", id: memory.id.rawValue, revision: memory.revision)
        guard proposal.plan.sources == [reference], proposal.plan.targets == [reference] else {
            throw MiraError(.unauthorized, "The retraction target is not authorized.")
        }
        let suppressed = try await store.suppressedMemorySources()
        if suppressed.contains(.userMessage(context.evidence.reference)) {
            throw MiraError(.unauthorized, "The source message is suppressed for memory capture.")
        }
    }
}
