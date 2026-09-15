import Foundation

/// Immutable preparation inputs run outside the kernel actor. A slow synchronous adapter
/// must not prevent the kernel from accepting cancellation or latching a deadline failure.
struct AgentModelPreparation: Sendable {
    let runtime: SessionRuntime
    let payloads: any SessionPayloadReader
    let request: AgentContextRequest
    let instructions: String
    let trace: AgentContextHistory
    let tools: [ToolDefinition]
    let route: AgentModelRoute
    let adapter: any AgentModelAdapter
    let contributors: [any AgentContextContributor]
    let authorizer: any AgentSourceAuthorizer

    nonisolated func build(stepID: UUID) async throws -> AgentContextBuild {
        try Task.checkCancellation()
        guard request.destination == .model(route) else {
            throw MiraError(.configuration, "The model operation does not match its frozen context.")
        }
        try await authorizer.validate(trace.sources, for: request)
        try Task.checkCancellation()
        let currentTrace = try replayTrace()
        let state = await runtime.snapshot()
        let history = try await JournalAgentHistoryReader(payloads: payloads).read(
            state: state, request: request, route: route, adapter: adapter, authorizer: authorizer,
            maximumMessages: max(0, 254 - currentTrace.messages.count))
        try Task.checkCancellation()
        return try await AgentContextAssembler().build(request: request, stepID: stepID,
            instructions: instructions, history: history, currentTrace: currentTrace, tools: tools,
            route: route, adapter: adapter, contributors: contributors, authorizer: authorizer)
    }

    private func replayTrace() throws -> AgentContextHistory {
        if trace.messages.isEmpty { return trace }
        guard case .include(let messages) = try adapter.replay(trace.messages, from: route, to: route, boundary: .sameExecution),
              messages.count == trace.messages.count else {
            throw MiraError(.unsupported, "The adapter cannot replay this execution's tool exchange.")
        }
        try Task.checkCancellation()
        for (old, new) in zip(trace.messages, messages) {
            guard old.role == new.role, old.blocks == new.blocks,
                  new.continuation == old.continuation else {
                throw MiraError(.malformedStream, "The adapter changed the current execution's replay content.")
            }
        }
        return .init(messages: messages, sources: trace.sources)
    }
}
