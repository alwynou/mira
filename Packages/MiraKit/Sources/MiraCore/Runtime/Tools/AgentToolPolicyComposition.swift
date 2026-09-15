import Foundation

/// The catalog captures the module policy with the tool, so withdrawing a separate registration
/// cannot accidentally turn a previously constrained invocation into a host-only invocation.
struct AgentToolPolicyComposition: AgentToolPolicy {
    let host: any AgentToolPolicy
    let requirement: AgentToolPolicyRequirement

    func evaluate(_ proposal: AgentToolProposal, context: AgentToolContext) async throws -> AgentToolPolicyDecision {
        try Task.checkCancellation()
        let hostDecision = try await host.evaluate(proposal, context: context)
        try Task.checkCancellation()
        if case .deny = hostDecision { return .deny }
        let moduleDecision: AgentToolPolicyDecision
        switch requirement {
        case .hostOnly: moduleDecision = .allow
        case .constrained(let policy): moduleDecision = try await policy.evaluate(proposal, context: context)
        }
        try Task.checkCancellation()
        if case .deny = moduleDecision { return .deny }
        var prompts: [String] = []
        var deadline: Date?
        for decision in [hostDecision, moduleDecision] {
            if case .requireApproval(let prompt, let expiresAt) = decision {
                guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      prompt.utf8.count <= 4_096, expiresAt.timeIntervalSince1970.isFinite else { throw Self.invalidApproval }
                prompts.append(prompt)
                deadline = deadline.map { min($0, expiresAt) } ?? expiresAt
            }
        }
        guard let deadline else { return .allow }
        let prompt = prompts.joined(separator: "\n\n")
        guard prompt.utf8.count <= 4_096 else { throw Self.invalidApproval }
        return .requireApproval(prompt: prompt, expiresAt: deadline)
    }

    func validate(_ proposal: AgentToolProposal, context: AgentToolContext) async throws {
        try Task.checkCancellation()
        try await host.validate(proposal, context: context)
        try Task.checkCancellation()
        if case .constrained(let policy) = requirement {
            try await policy.validate(proposal, context: context)
        }
        try Task.checkCancellation()
    }

    private static var invalidApproval: MiraError {
        .init(.configuration, "The combined tool approval request is invalid or exceeds its limit.")
    }
}
