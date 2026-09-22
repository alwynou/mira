#if DEBUG
import Foundation
import MiraCore

/// Fast, deterministic model I/O for composition tests. The debug demo seed is reused
/// only for its credential-free route/settings contract; this adapter owns every reply.
struct SyntheticCompositionModelModule: RuntimeModule, Sendable {
    let id = "tests.synthetic.composition"
    let dependencies: Set<String> = []
    let registry: RuntimeRegistry<AgentCapability>
    let gate: SyntheticCompositionStreamGate?

    init(registry: RuntimeRegistry<AgentCapability>, gate: SyntheticCompositionStreamGate? = nil) {
        self.registry = registry
        self.gate = gate
    }

    func activate(in scope: RuntimeScope) async throws {
        try await registry.register(
            id: "tests.synthetic.composition.model",
            value: .model(SyntheticCompositionModelAdapter(gate: gate)), scope: scope)
        try await registry.register(
            id: "tests.synthetic.composition.configuration",
            value: .modelConfiguration(SyntheticCompositionModelConfiguration()), scope: scope)
    }
}

/// Holds one foreground model stream until the test has switched conversation pages.
actor SyntheticCompositionStreamGate {
    private var isArmed = false
    private(set) var hasEntered = false
    private var wasReleased = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func arm() {
        isArmed = true
        hasEntered = false
        wasReleased = false
    }

    func release() {
        wasReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    fileprivate func pauseIfArmed() async {
        guard isArmed else { return }
        isArmed = false
        hasEntered = true
        guard !wasReleased else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }
}

private struct SyntheticCompositionModelAdapter: AgentModelAdapter {
    let identity = MacDemoModule.adapterIdentity
    let gate: SyntheticCompositionStreamGate?

    func prepare(_ input: AgentModelInput, route: AgentModelRoute) throws -> AgentPreparedModelRequest {
        let prepared = AgentPreparedModelRequest(
            adapter: identity, input: input, wirePayload: .object([:]), estimatedInputTokens: 1)
        try prepared.validate(for: route)
        return prepared
    }

    func stream(_ request: AgentPreparedModelRequest, route: AgentModelRoute) -> AgentModelOperation {
        let (events, continuation) = AsyncThrowingStream<AgentModelStreamEvent, any Error>.makeStream()
        let gate = gate
        let isExtraction = request.input.messages.last?.blocks.contains { $0.id == "memory-extraction" } == true
        let producer = Task {
            do {
                if !isExtraction {
                    await gate?.pauseIfArmed()
                    try Task.checkCancellation()
                    continuation.yield(.blockStarted(.init(
                        id: "thinking", content: .thinking("Synthetic thinking retained after settlement."))))
                    continuation.yield(.blockFinished(id: "thinking"))
                }
                let reply = isExtraction
                    ? #"{"version":4,"items":[],"retractions":[]}"#
                    : "Synthetic composition reply with a durable body."
                continuation.yield(.blockStarted(.init(id: "answer", content: .text(""))))
                continuation.yield(.blockDelta(id: "answer", text: reply))
                continuation.yield(.blockFinished(id: "answer"))
                continuation.yield(.finished(.stop))
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        return .init(events: events, cancelAndDrain: {
            producer.cancel()
            await gate?.release()
            await producer.value
        })
    }

    func replay(
        _ messages: [AgentModelMessage], from source: AgentModelRoute,
        to target: AgentModelRoute, boundary: AgentReplayBoundary
    ) throws -> AgentReplayDecision { .include(messages) }
}

private struct SyntheticCompositionModelConfiguration: AgentModelConfigurationProvider {
    let identity = MacDemoModule.adapterIdentity

    func descriptor(for invocation: AgentModelInvocationSpec) throws -> AgentModelConfigurationDescriptor {
        guard invocation.adapter == identity, invocation.id == "demo" else {
            throw MiraError(.configuration, "The synthetic composition model is unavailable.")
        }
        return .init(
            adapter: identity, title: "Synthetic composition model", credential: .none,
            connection: schema(MacDemoModule.connectionSchema, title: "Synthetic connection"),
            route: schema(MacDemoModule.routeSchema, title: "Synthetic route"))
    }

    func configuration(for candidate: AgentModelRouteCandidate) throws -> JSONValue {
        let invocation = try candidate.invocation
        let endpoint = try candidate.endpoint
        let descriptor = try descriptor(for: invocation)
        try descriptor.connection.validate(endpoint.configuration)
        try descriptor.route.validate(candidate.preset.configuration)
        guard endpoint.credential == nil,
            endpoint.configuration.schema == MacDemoModule.connectionSchema,
            candidate.preset.configuration.schema == MacDemoModule.routeSchema
        else {
            throw MiraError(.configuration, "The synthetic composition settings do not match their schema.")
        }
        return .object([:])
    }

    private func schema(_ identity: AgentConfigurationIdentity, title: String) -> AgentConfigurationSchema {
        .init(identity: identity, title: title,
            schema: .object(["type": .string("object"), "properties": .object([:]),
                             "additionalProperties": .bool(false)]),
            defaults: .object([:]))
    }
}
#endif
