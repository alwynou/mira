import Foundation

/// The only outcomes a successful probe may persist. Transport, cancellation,
/// configuration and authorization failures are thrown and are never converted
/// into an unsupported capability.
public enum AgentModelProbeOutcome: String, Codable, Sendable, Equatable {
    case verified
    case unsupported
}

public struct AgentModelProbeIdentity: Codable, Sendable, Equatable, Hashable {
    public let id: String
    public let revision: Int
    public let title: String
    public let capabilityIDs: Set<String>

    public init(id: String, revision: Int, title: String, capabilityIDs: Set<String>) {
        self.id = id
        self.revision = revision
        self.title = title
        self.capabilityIDs = capabilityIDs
    }

    public func validate() throws {
        guard SessionState.validIdentifier(id, maximumBytes: 128), revision > 0,
            !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            title.utf8.count <= 256, (1...16).contains(capabilityIDs.count),
            capabilityIDs.allSatisfy({ SessionState.validIdentifier($0, maximumBytes: 128) }),
            capabilityIDs.count == Set(capabilityIDs).count,
            try SessionCodec.encode(self).count <= 16_384
        else {
            throw MiraError(.configuration, "The model capability probe identity is invalid.")
        }
    }
}

/// A provider owns the synthetic request and typed interpretation. Core does
/// not switch on provider families or capability names.
public struct AgentModelProbeDefinition: Sendable {
    public let identity: AgentModelProbeIdentity
    public let preparationCapabilityIDs: Set<String>
    private let prepareCandidateBody: @Sendable (AgentModelRouteCandidate) throws -> AgentModelRouteCandidate
    private let makeInputBody: @Sendable (UUID, ExecutionID, AgentModelRoute) throws -> AgentModelInput
    private let evaluateBody: @Sendable (AgentModelOutput) throws -> AgentModelProbeOutcome

    public init(
        identity: AgentModelProbeIdentity,
        preparationCapabilityIDs: Set<String>,
        prepareCandidate: @escaping @Sendable (AgentModelRouteCandidate) throws -> AgentModelRouteCandidate,
        makeInput: @escaping @Sendable (UUID, ExecutionID, AgentModelRoute) throws -> AgentModelInput,
        evaluate: @escaping @Sendable (AgentModelOutput) throws -> AgentModelProbeOutcome
    ) throws {
        try identity.validate()
        guard preparationCapabilityIDs.count <= 16,
            preparationCapabilityIDs.allSatisfy({ SessionState.validIdentifier($0, maximumBytes: 128) })
        else {
            throw MiraError(.configuration, "The model capability probe preparation capabilities are invalid.")
        }
        self.identity = identity
        self.preparationCapabilityIDs = preparationCapabilityIDs
        prepareCandidateBody = prepareCandidate
        makeInputBody = makeInput
        evaluateBody = evaluate
    }

    public func prepareCandidate(_ candidate: AgentModelRouteCandidate) throws -> AgentModelRouteCandidate {
        try prepareCandidateBody(candidate)
    }

    public func makeInput(stepID: UUID, executionID: ExecutionID, route: AgentModelRoute) throws -> AgentModelInput {
        try makeInputBody(stepID, executionID, route)
    }

    public func evaluate(_ output: AgentModelOutput) throws -> AgentModelProbeOutcome {
        try evaluateBody(output)
    }
}

public protocol AgentModelProbeProvider: Sendable {
    func probes() throws -> [AgentModelProbeDefinition]
}

public final class AgentModelProbeCatalog: Sendable {
    private let values: [String: AgentModelProbeDefinition]

    public init(providers: [any AgentModelProbeProvider]) throws {
        guard providers.count <= 32 else {
            throw MiraError(.configuration, "The runtime capability probe limit was exceeded.")
        }
        var values: [String: AgentModelProbeDefinition] = [:]
        for provider in providers {
            let definitions = try provider.probes()
            guard definitions.count <= 64 else {
                throw MiraError(.configuration, "The runtime capability probe limit was exceeded.")
            }
            for definition in definitions {
                try definition.identity.validate()
                guard values.updateValue(definition, forKey: definition.identity.id) == nil else {
                    throw MiraError(.configuration, "The runtime contains duplicate capability probes.")
                }
            }
        }
        self.values = values
    }

    public var identities: [AgentModelProbeIdentity] {
        values.values.map(\.identity).sorted { $0.id < $1.id }
    }

    public func definition(id: String) throws -> AgentModelProbeDefinition {
        guard let value = values[id] else {
            throw MiraError(.notFound, "The requested model capability probe is unavailable.")
        }
        return value
    }
}

public struct AgentModelProbeObservation: Codable, Sendable, Equatable {
    public let candidate: AgentModelRouteCandidate
    public let probe: AgentModelProbeIdentity
    public let outcome: AgentModelProbeOutcome
    public let observedAt: Date

    public init(
        candidate: AgentModelRouteCandidate, probe: AgentModelProbeIdentity,
        outcome: AgentModelProbeOutcome, observedAt: Date
    ) {
        self.candidate = candidate
        self.probe = probe
        self.outcome = outcome
        self.observedAt = observedAt
    }

    public func validate() throws {
        try candidate.connection.validate()
        try candidate.model.validate()
        try candidate.preset.validate()
        guard candidate.model.connectionID == candidate.connection.id,
            candidate.preset.modelDescriptorID == candidate.model.id,
            candidate.connection.isEnabled, candidate.model.isEnabled,
            let window = try candidate.invocation.contextWindow,
            candidate.preset.maximumOutputTokens < window
        else {
            throw MiraError(.configuration, "The model capability probe candidate is invalid.")
        }
        try probe.validate()
        guard observedAt.timeIntervalSince1970.isFinite else {
            throw MiraError(.configuration, "The capability probe observation date is invalid.")
        }
    }
}

public protocol AgentModelProbeStore: Sendable {
    /// Reads the route atomically from the settings authority. Probe preparation
    /// must compare this same snapshot again after transport completes.
    func candidate(routeID: RouteID, authorization: AgentLibraryAuthorization) async throws -> AgentModelRouteCandidate
    func save(_ observation: AgentModelProbeObservation, authorization: AgentLibraryAuthorization) async throws
}

public actor AgentModelProbeService {
    private let probeStore: any AgentModelProbeStore
    private let registry: RuntimeRegistry<AgentCapability>
    private let execution: AgentModelProbeExecution
    private let access: AgentLibraryAccess
    private let scope: RuntimeScope
    private struct Owner: Sendable {
        let cancel: @Sendable () -> Void
        let drain: @Sendable () async -> Void
    }
    private var owners: [UUID: Owner] = [:]
    private var captured: [AgentModelProbeObservation] = []
    private var closed = false
    private var closeTask: Task<Void, Never>?
    private let maximumConcurrentOperations: Int

    public init(
        probeStore: any AgentModelProbeStore,
        registry: RuntimeRegistry<AgentCapability>, access: AgentLibraryAccess, scope: RuntimeScope,
        environment: RuntimeEnvironment = .init(), timeout: Duration = .seconds(30),
        maximumConcurrentOperations: Int = 8
    ) throws {
        guard timeout > .zero, timeout <= .seconds(120) else {
            throw MiraError(.configuration, "The model capability probe timeout is invalid.")
        }
        guard (1...64).contains(maximumConcurrentOperations) else {
            throw MiraError(.configuration, "The model capability probe operation limit is invalid.")
        }
        self.probeStore = probeStore
        self.registry = registry
        self.execution = try AgentModelProbeExecution(
            registry: registry, environment: environment, timeout: timeout)
        self.access = access
        self.scope = scope
        self.maximumConcurrentOperations = maximumConcurrentOperations
    }

    public func probe(routeID: RouteID, probeID: String) async throws -> AgentModelProbeObservation {
        try Task.checkCancellation()
        guard !closed else { throw MiraError(.cancelled, "Model capability probing was stopped.") }
        guard owners.count < maximumConcurrentOperations else {
            throw MiraError(.busy, "Too many model capability probe operations are active.")
        }
        let id = UUID()
        let probeStore = probeStore
        let execution = execution
        let access = access
        let scope = scope
        let task = Task {
            let lease = try await access.acquire(in: scope)
            let work = Task {
                let candidate = try await lease.read {
                    try await probeStore.candidate(
                        routeID: routeID, authorization: lease.authorization)
                }
                let result = try await execution.run(
                    candidate: candidate, probeID: probeID, lease: lease)
                try await lease.check()
                let current = try await lease.read {
                    try await probeStore.candidate(
                        routeID: routeID, authorization: lease.authorization)
                }
                guard current == candidate else {
                    throw MiraError(.conflict, "The model route changed while the capability probe was running.")
                }
                return result
            }
            do {
                try lease.bindCancellation { work.cancel() }
                let result = try await withTaskCancellationHandler {
                    try await work.value
                } onCancel: {
                    work.cancel()
                }
                await lease.release()
                return result
            } catch {
                work.cancel()
                _ = await work.result
                await lease.release()
                throw error
            }
        }
        owners[id] = .init(cancel: { task.cancel() }, drain: { _ = await task.result })
        defer { owners.removeValue(forKey: id) }
        return try await withTaskCancellationHandler {
            let result = try await task.value
            try Task.checkCancellation()
            guard !closed else { throw MiraError(.cancelled, "Model capability probing was stopped.") }
            guard captured.count < 128 else {
                throw MiraError(.busy, "Too many unsaved model capability observations.")
            }
            captured.append(result)
            return result
        } onCancel: {
            task.cancel()
        }
    }

    public func descriptors() async throws -> [AgentModelProbeIdentity] {
        try Task.checkCancellation()
        guard !closed else { throw MiraError(.cancelled, "Model capability probing was stopped.") }
        guard owners.count < maximumConcurrentOperations else {
            throw MiraError(.busy, "Too many model capability probe operations are active.")
        }
        let id = UUID()
        let registry = registry
        let access = access
        let scope = scope
        let task = Task { () throws -> [AgentModelProbeIdentity] in
            let lease = try await access.acquire(in: scope)
            do {
                try await lease.check()
                let snapshot = try await registry.freeze()
                let catalog: AgentRuntimeCatalog
                do { catalog = try AgentRuntimeCatalog(snapshot: snapshot) } catch {
                    await snapshot.release()
                    throw error
                }
                let result = catalog.probes.identities
                await catalog.release()
                try await lease.check()
                await lease.release()
                return result
            } catch {
                await lease.release()
                throw error
            }
        }
        owners[id] = .init(cancel: { task.cancel() }, drain: { _ = await task.result })
        defer { owners.removeValue(forKey: id) }
        return try await withTaskCancellationHandler {
            let result = try await task.value
            try Task.checkCancellation()
            guard !closed else { throw MiraError(.cancelled, "Model capability probing was stopped.") }
            return result
        } onCancel: {
            task.cancel()
        }
    }

    public func save(_ observation: AgentModelProbeObservation) async throws {
        try Task.checkCancellation()
        guard !closed else { throw MiraError(.cancelled, "Model capability probing was stopped.") }
        guard owners.count < maximumConcurrentOperations else {
            throw MiraError(.busy, "Too many model capability probe operations are active.")
        }
        guard captured.contains(observation) else {
            throw MiraError(.conflict, "The model capability observation was not produced by this service.")
        }
        let id = UUID()
        let task = Task {
            let lease = try await access.acquire(in: scope)
            do {
                try await lease.check()
                let resource = try await lease.start {
                    let work = Task { () throws -> Void in
                        try await self.probeStore.save(observation, authorization: lease.authorization)
                    }
                    return AgentLibraryResource(value: work) {
                        work.cancel()
                        _ = await work.result
                    }
                }
                do {
                    try await resource.value.value
                    await resource.release()
                } catch {
                    await resource.release()
                    throw error
                }
                try await lease.check()
                await lease.release()
            } catch {
                await lease.release()
                throw error
            }
        }
        owners[id] = .init(cancel: { task.cancel() }, drain: { _ = await task.result })
        defer { owners.removeValue(forKey: id) }
        try await withTaskCancellationHandler {
            try await task.value
            try Task.checkCancellation()
            guard !closed else { throw MiraError(.cancelled, "Model capability probing was stopped.") }
            if let index = captured.firstIndex(of: observation) { captured.remove(at: index) }
        } onCancel: {
            task.cancel()
        }
    }

    public func close() async {
        if let closeTask {
            await closeTask.value
            return
        }
        closed = true
        let activeOwners = Array(owners.values)
        for owner in activeOwners { owner.cancel() }
        let drain = Task {
            await withTaskGroup(of: Void.self) { group in
                for owner in activeOwners { group.addTask { await owner.drain() } }
            }
        }
        closeTask = drain
        await drain.value
        captured.removeAll()
    }

}
