import Foundation

/// A driver selects iteration policy. The kernel validates every requested operation and final decision.
public protocol AgentDriver: Sendable {
    var id: String { get }
    var revision: Int { get }
    func run(in context: AgentRunContext) async throws -> AgentDriverDecision
}

public enum AgentDriverDecision: Sendable {
    case complete
    /// A deterministic, bounded answer before any model operation. It cannot invent tool or source evidence.
    case respond(text: String)
    case stop
}

/// Created only by the kernel and valid only for this execution's latest model step.
public struct AgentDriverStep: Sendable {
    public let id: UUID
    public let output: AgentModelOutput
    public var hasToolCalls: Bool { !output.toolCalls.isEmpty }
    init(id: UUID, output: AgentModelOutput) { self.id = id; self.output = output }
}

/// An unforgeable operation surface. It contains no journal, provider, authority, or business port.
public final class AgentRunContext: Sendable {
    private let access: AgentRunAccess
    public let userText: String
    init(kernel: AgentExecutionKernel) {
        self.access = AgentRunAccess(kernel: kernel); self.userText = kernel.request.userText
    }
    public func modelStep() async throws -> AgentDriverStep { try await access.modelStep() }
    public func executeTools(for step: AgentDriverStep) async throws -> [ToolResultStatus] {
        try await access.executeTools(for: step)
    }
}

/// Retaining a completed context must not retain its execution, adapters, or library owner.
private actor AgentRunAccess {
    private weak var kernel: AgentExecutionKernel?
    init(kernel: AgentExecutionKernel) { self.kernel = kernel }
    func modelStep() async throws -> AgentDriverStep { try await owner().modelStep() }
    func executeTools(for step: AgentDriverStep) async throws -> [ToolResultStatus] {
        try await owner().executeTools(for: step)
    }
    private func owner() throws -> AgentExecutionKernel {
        guard let kernel else { throw MiraError(.conflict, "The driver operation is unavailable or already occupied.") }
        return kernel
    }
}

public struct DefaultAgentDriver: AgentDriver {
    public let id = "mira.default"
    public let revision = 1
    public init() {}
    public func run(in context: AgentRunContext) async throws -> AgentDriverDecision {
        while true {
            let step = try await context.modelStep()
            if !step.hasToolCalls { return .complete }
            _ = try await context.executeTools(for: step)
        }
    }
}
