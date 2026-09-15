import Foundation

/// Runs one synthetic model capability probe against an already captured route.
/// Persistence and route freshness checks belong to the caller; this type owns
/// only the frozen runtime catalog and the provider operation lifetime.
public struct AgentModelProbeExecution: Sendable {
    private let registry: RuntimeRegistry<AgentCapability>
    private let environment: RuntimeEnvironment
    private let timeout: Duration

    public init(
        registry: RuntimeRegistry<AgentCapability>,
        environment: RuntimeEnvironment = .init(),
        timeout: Duration = .seconds(30)
    ) throws {
        guard timeout > .zero, timeout <= .seconds(120) else {
            throw MiraError(.configuration, "The model capability probe timeout is invalid.")
        }
        self.registry = registry
        self.environment = environment
        self.timeout = timeout
    }

    public func run(
        candidate: AgentModelRouteCandidate,
        probeID: String,
        lease: AgentLibraryAccessLease
    ) async throws -> AgentModelProbeObservation {
        try Task.checkCancellation()
        let snapshot = try await registry.freeze()
        let catalog: AgentRuntimeCatalog
        do {
            catalog = try AgentRuntimeCatalog(snapshot: snapshot)
        } catch {
            await snapshot.release()
            throw error
        }
        do {
            let probe = try catalog.probe(id: probeID)
            let preparedCandidate = try probe.prepareCandidate(candidate)
            try Self.validateCandidatePreparation(
                candidate, prepared: preparedCandidate,
                capabilityIDs: probe.preparationCapabilityIDs)
            let route = try catalog.configuredRoute(preparedCandidate)
            let adapter = try catalog.model(identity: route.adapter)
            let input = try probe.makeInput(
                stepID: environment.uuid(), executionID: .init(environment.uuid()), route: route)
            let prepared = try adapter.prepare(input, route: route)
            try prepared.validate(for: route)
            try await lease.check()
            let resource = try await lease.start {
                let operation = adapter.stream(prepared, route: route)
                return AgentLibraryResource(value: operation) { await operation.close() }
            }
            let output: AgentModelOutput
            do {
                output = try await Self.collect(
                    resource.value, route: route, timeout: timeout,
                    environment: environment)
                await resource.release()
            } catch {
                await resource.release()
                throw error
            }
            try await lease.check()
            let outcome = try probe.evaluate(output)
            try await lease.check()
            let observation = AgentModelProbeObservation(
                candidate: candidate, probe: probe.identity,
                outcome: outcome, observedAt: environment.now())
            try observation.validate()
            await catalog.release()
            return observation
        } catch {
            await catalog.release()
            if let failure = error as? AgentModelFailure { throw failure.error }
            throw error
        }
    }

    private static func validateCandidatePreparation(
        _ original: AgentModelRouteCandidate,
        prepared: AgentModelRouteCandidate,
        capabilityIDs: Set<String>
    ) throws {
        let originalSpec = try original.invocation
        let preparedSpec = try prepared.invocation
        let unchangedSpec = AgentModelInvocationSpec(
            id: preparedSpec.id, revision: preparedSpec.revision, adapter: preparedSpec.adapter,
            endpointID: preparedSpec.endpointID, contextWindow: preparedSpec.contextWindow,
            maximumOutputTokens: preparedSpec.maximumOutputTokens, capabilities: originalSpec.capabilities,
            configuration: preparedSpec.configuration, parameterSchema: preparedSpec.parameterSchema,
            maximumInputTokens: preparedSpec.maximumInputTokens)
        guard prepared.connection == original.connection, prepared.preset == original.preset,
            prepared.model.id == original.model.id, prepared.model.revision == original.model.revision,
            prepared.model.authorizationRevision == original.model.authorizationRevision,
            prepared.model.reference == original.model.reference,
            prepared.model.displayName == original.model.displayName,
            prepared.model.isEnabled == original.model.isEnabled, prepared.model.facts == original.model.facts,
            originalSpec == unchangedSpec,
            prepared.model.invocations.filter({ $0.id != preparedSpec.id }) == original.model.invocations.filter({ $0.id != originalSpec.id }) else {
            throw MiraError(.configuration, "A capability probe changed frozen route configuration.")
        }
        let allIDs = Set(originalSpec.capabilities.keys).union(preparedSpec.capabilities.keys)
        for id in allIDs {
            let old = originalSpec.capabilities[id], new = preparedSpec.capabilities[id]
            if old == new { continue }
            guard capabilityIDs.contains(id), new == .declared,
                old == nil || old == .unknown || old == .failed else {
                throw MiraError(.configuration, "A capability probe declared an unauthorized capability.")
            }
        }
        try prepared.validate()
    }

    private static func collect(
        _ operation: AgentModelOperation,
        route: AgentModelRoute,
        timeout: Duration,
        environment: RuntimeEnvironment
    ) async throws -> AgentModelOutput {
        try await withThrowingTaskGroup(of: AgentModelOutput.self) { group in
            group.addTask {
                var accumulator = try AgentModelAccumulator(route: route)
                for try await event in operation.events {
                    try accumulator.consume(event)
                }
                return try accumulator.finish()
            }
            group.addTask {
                try await environment.clock.sleep(for: timeout)
                throw MiraError(.timeout, "The model capability probe timed out.")
            }
            do {
                guard let result = try await group.next() else { throw CancellationError() }
                group.cancelAll()
                return result
            } catch {
                group.cancelAll()
                await operation.close()
                throw error
            }
        }
    }
}
