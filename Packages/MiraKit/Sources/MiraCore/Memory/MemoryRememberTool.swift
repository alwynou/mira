import Foundation

public struct MemoryRememberProposal: Sendable, Equatable {
    public let draft: MemoryDraft
    public let quote: String
    public let isDirectIntent: Bool
    public let hasExplicitIntent: Bool
    public init(draft: MemoryDraft, quote: String, isDirectIntent: Bool, hasExplicitIntent: Bool = false) {
        self.draft = draft; self.quote = quote; self.isDirectIntent = isDirectIntent; self.hasExplicitIntent = hasExplicitIntent
    }
}

/// Prepares an explicitly authorized memory write. It never mutates the
/// business store; the Data-layer effect handler owns the guarded commit.
public struct MemoryRememberTool: AgentLocalWriteTool {
    private let store: any MemoryReadStore
    private let capturePolicy: any MemoryCapturePolicyStore
    private let now: @Sendable () -> Date

    public init(store: any MemoryReadStore, capturePolicy: any MemoryCapturePolicyStore,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store; self.capturePolicy = capturePolicy; self.now = now
    }

    public var policy: AgentToolPolicyRequirement {
        .constrained(MemoryRememberPolicy(store: store, capturePolicy: capturePolicy, now: now))
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
    let capturePolicy: any MemoryCapturePolicyStore
    let now: @Sendable () -> Date

    func evaluate(_ proposal: AgentToolProposal, context: AgentToolContext) async throws -> AgentToolPolicyDecision {
        let parsed = try MemoryTools.parsedProposal(arguments: proposal.plan.input, evidence: context.evidence)
        let current = try await capturePolicy.memoryCapturePolicy()
        let suppressed = try await store.suppressedMemorySources()
        if current.mode != .manualOnly && !parsed.hasExplicitIntent { return .deny }
        if parsed.isDirectIntent {
            return suppressed.contains(.userMessage(context.evidence.reference)) ? .deny : .allow
        }
        let prompt = "Approve saving this local-only memory.\nRemote use: disabled\nQuote: \(parsed.quote)\nContent: \(parsed.draft.content)\nScope: \(parsed.draft.scope.key)\nSensitivity: \(parsed.draft.sensitivity.rawValue)"
        guard prompt.utf8.count <= 4_096 else {
            throw MiraError(.invalidInput, "This memory proposal exceeds the approval size limit.")
        }
        return .requireApproval(prompt: prompt, expiresAt: now().addingTimeInterval(600))
    }

    func validate(_ proposal: AgentToolProposal, context: AgentToolContext) async throws {
        let parsed = try MemoryTools.parsedProposal(arguments: proposal.plan.input, evidence: context.evidence)
        let current = try await capturePolicy.memoryCapturePolicy()
        guard current.mode == .manualOnly || parsed.hasExplicitIntent else {
            throw MiraError(.unauthorized, "Automatic memory capture handles ordinary statements after the reply.")
        }
        let suppressed = try await store.suppressedMemorySources()
        if parsed.isDirectIntent, suppressed.contains(.userMessage(context.evidence.reference)) {
            throw MiraError(.unauthorized, "The source message is suppressed for memory capture.")
        }
        // Approval-granted ambiguous or suppressed proposals remain valid here.
    }
}
