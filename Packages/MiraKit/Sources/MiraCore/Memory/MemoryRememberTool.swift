import Foundation

public struct MemoryRememberProposal: Sendable, Equatable {
    public let draft: MemoryDraft
    public let quote: String
    public init(draft: MemoryDraft, quote: String) {
        self.draft = draft; self.quote = quote
    }
}

/// Prepares an explicitly authorized memory write. It never mutates the
/// business store; the Data-layer effect handler owns the guarded commit.
public struct MemoryRememberTool: AgentLocalWriteTool {
    private let store: any MemoryReadStore

    public init(store: any MemoryReadStore) { self.store = store }

    public var policy: AgentToolPolicyRequirement {
        .constrained(MemoryRememberPolicy(store: store))
    }
    public var businessNamespace: String { "memory.remember" }
    public var descriptor: AgentToolDescriptor {
        .init(definition: MemoryTools.rememberDefinition, revision: 1, outputSchema: MemoryTools.rememberResultSchema,
              executionMode: .exclusive, timeoutMilliseconds: 120_000, maximumResultBytes: 4_096)
    }

    public func prepare(_ arguments: JSONValue, context: AgentToolContext) async throws -> AgentToolPlan {
        let normalized = try ToolSchemaValidator.decode(try arguments.jsonString(), schema: descriptor.definition.inputSchema)
        _ = try MemoryTools.parsedProposal(arguments: normalized, evidence: context.evidence)
        return .init(input: normalized, sources: [], targets: [])
    }
}

private struct MemoryRememberPolicy: AgentToolPolicy {
    let store: any MemoryReadStore

    func evaluate(_ proposal: AgentToolProposal, context: AgentToolContext) async throws -> AgentToolPolicyDecision {
        _ = try MemoryTools.parsedProposal(arguments: proposal.plan.input, evidence: context.evidence)
        let suppressed = try await store.suppressedMemorySources()
        return suppressed.contains(.userMessage(context.evidence.reference)) ? .deny : .allow
    }

    func validate(_ proposal: AgentToolProposal, context: AgentToolContext) async throws {
        _ = try MemoryTools.parsedProposal(arguments: proposal.plan.input, evidence: context.evidence)
        let suppressed = try await store.suppressedMemorySources()
        if suppressed.contains(.userMessage(context.evidence.reference)) {
            throw MiraError(.unauthorized, "The source message is suppressed for memory capture.")
        }
    }
}
