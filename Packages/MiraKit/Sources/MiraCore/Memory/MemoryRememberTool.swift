import Foundation

public struct MemoryRememberProposal: Sendable, Equatable {
    public let draft: MemoryDraft
    public let quote: String
    public let enrichmentTargets: [MemoryUsage]
    public init(draft: MemoryDraft, quote: String, enrichmentTargets: [MemoryUsage] = []) {
        self.draft = draft; self.quote = quote; self.enrichmentTargets = enrichmentTargets
    }
}

/// Prepares an explicitly authorized memory write. It never mutates the
/// business store; the Data-layer effect handler owns the guarded commit.
public struct MemoryRememberTool: AgentLocalWriteTool {
    private let store: any MemoryReadStore
    private let now: @Sendable () -> Date

    public init(store: any MemoryReadStore, now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store; self.now = now
    }

    public var policy: AgentToolPolicyRequirement {
        .constrained(MemoryRememberPolicy(store: store, now: now))
    }
    public var businessNamespace: String { "memory.remember" }
    public var descriptor: AgentToolDescriptor {
        .init(definition: MemoryTools.rememberDefinition, revision: 2, outputSchema: MemoryTools.rememberResultSchema,
              executionMode: .exclusive, timeoutMilliseconds: 120_000, maximumResultBytes: 4_096)
    }

    public func prepare(_ arguments: JSONValue, context: AgentToolContext) async throws -> AgentToolPlan {
        let normalized = try ToolSchemaValidator.decode(try arguments.jsonString(), schema: descriptor.definition.inputSchema)
        let proposal = try MemoryTools.parsedProposal(arguments: normalized, evidence: context.evidence)
        let memories = try await MemoryRememberValidation.loadTargets(
            proposal.enrichmentTargets, draft: proposal.draft, store: store, context: context, at: now())
        let references = memories.map {
            AgentSourceReference.domain(namespace: "memories", id: $0.id.rawValue, revision: $0.revision)
        }
        return .init(input: normalized, sources: references, targets: references)
    }
}

private struct MemoryRememberPolicy: AgentToolPolicy {
    let store: any MemoryReadStore
    let now: @Sendable () -> Date

    func evaluate(_ proposal: AgentToolProposal, context: AgentToolContext) async throws -> AgentToolPolicyDecision {
        _ = try await validatedTargets(proposal, context: context)
        let suppressed = try await store.suppressedMemorySources()
        return suppressed.contains(.userMessage(context.evidence.reference)) ? .deny : .allow
    }

    func validate(_ proposal: AgentToolProposal, context: AgentToolContext) async throws {
        _ = try await validatedTargets(proposal, context: context)
        let suppressed = try await store.suppressedMemorySources()
        if suppressed.contains(.userMessage(context.evidence.reference)) {
            throw MiraError(.unauthorized, "The source message is suppressed for memory capture.")
        }
    }

    private func validatedTargets(_ proposal: AgentToolProposal, context: AgentToolContext) async throws -> MemoryRememberProposal {
        let parsed = try MemoryTools.parsedProposal(arguments: proposal.plan.input, evidence: context.evidence)
        let memories = try await MemoryRememberValidation.loadTargets(
            parsed.enrichmentTargets, draft: parsed.draft, store: store, context: context, at: now())
        let references = memories.map {
            AgentSourceReference.domain(namespace: "memories", id: $0.id.rawValue, revision: $0.revision)
        }
        guard proposal.plan.sources == references, proposal.plan.targets == references else {
            throw MemoryTools.evolutionTargetInvalid
        }
        return parsed
    }
}

private enum MemoryRememberValidation {
    static func loadTargets(
        _ targets: [MemoryUsage], draft: MemoryDraft,
        store: any MemoryReadStore, context: AgentToolContext, at: Date
    ) async throws -> [Memory] {
        guard targets.count <= 6, Set(targets.map(\.memoryID)).count == targets.count else {
            throw MemoryTools.evolutionTargetInvalid
        }
        guard !targets.isEmpty else { return [] }
        let request = try MemoryTools.request(context)
        var memories: [Memory] = []
        for target in targets {
            let memory = try await store.recallMemory(target.memoryID, request: request, at: at)
            guard memory.revision == target.revision,
                  memory.state == .active, memory.isCurrent,
                  let existing = memory.draft,
                  existing.scope == draft.scope,
                  existing.subject == draft.subject,
                  existing.kind == draft.kind,
                  existing.sensitivity == draft.sensitivity,
                  existing.allowsRemoteUse == draft.allowsRemoteUse,
                  existing.allowedConnectionIDs == draft.allowedConnectionIDs
            else { throw MemoryTools.evolutionTargetInvalid }
            if let first = memories.first?.draft, !compatible(existing, first) {
                throw MemoryTools.evolutionTargetInvalid
            }
            memories.append(memory)
        }
        return memories
    }

    private static func compatible(_ lhs: MemoryDraft, _ rhs: MemoryDraft) -> Bool {
        lhs.scope == rhs.scope && lhs.subject == rhs.subject && lhs.kind == rhs.kind &&
            lhs.sensitivity == rhs.sensitivity && lhs.allowsRemoteUse == rhs.allowsRemoteUse &&
            lhs.allowedConnectionIDs == rhs.allowedConnectionIDs &&
            lhs.validFrom == rhs.validFrom && lhs.validUntil == rhs.validUntil
    }
}
