import Foundation

/// Owns bounded settings queries through the same library and module lifetimes as execution.
/// Discovery never writes model capabilities, route bindings, or credentials.
public actor AgentModelDiscoveryService {
    private let settings: any AgentModelSettingsStore
    private let registry: RuntimeRegistry<AgentCapability>
    private let access: AgentLibraryAccess
    private let scope: RuntimeScope
    private let maximumConcurrentRequests: Int
    private let timeout: Duration
    private var owners: [UUID: Task<AgentModelDiscoveryResult, any Error>] = [:]
    private var closed = false
    private var closeTask: Task<Void, Never>?

    public init(
        settings: any AgentModelSettingsStore, registry: RuntimeRegistry<AgentCapability>,
        access: AgentLibraryAccess, scope: RuntimeScope,
        maximumConcurrentRequests: Int = 8, timeout: Duration = .seconds(30)
    ) throws {
        guard (1...64).contains(maximumConcurrentRequests), timeout > .zero, timeout <= .seconds(120) else {
            throw MiraError(.configuration, "The model discovery service limits are invalid.")
        }
        self.settings = settings
        self.registry = registry
        self.access = access
        self.scope = scope
        self.maximumConcurrentRequests = maximumConcurrentRequests
        self.timeout = timeout
    }

    public func discover(connectionID: ConnectionID, adapter: AgentAdapterIdentity) async throws
        -> AgentModelDiscoveryResult
    {
        try Task.checkCancellation()
        try adapter.validate()
        guard !closed else { throw MiraError(.cancelled, "Model discovery was stopped.") }
        guard owners.count < maximumConcurrentRequests else {
            throw MiraError(.busy, "Too many model discovery requests are active.")
        }
        let id = UUID()
        let settings = settings
        let registry = registry
        let access = access
        let scope = scope
        let timeout = timeout
        let task = Task {
            let lease = try await access.acquire(in: scope)
            let work = Task {
                try await Self.run(
                    connectionID: connectionID, adapter: adapter, settings: settings,
                    registry: registry, lease: lease, timeout: timeout)
            }
            do {
                try lease.bindCancellation { work.cancel() }
                let result = try await withTaskCancellationHandler {
                    try Task.checkCancellation()
                    return try await work.value
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
        owners[id] = task
        defer { owners.removeValue(forKey: id) }
        return try await withTaskCancellationHandler {
            let result = try await task.value
            try Task.checkCancellation()
            return result
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
        let tasks = Array(owners.values)
        for task in tasks { task.cancel() }
        let drain = Task { for task in tasks { _ = await task.result } }
        closeTask = drain
        await drain.value
    }

    private static func run(
        connectionID: ConnectionID, adapter: AgentAdapterIdentity,
        settings: any AgentModelSettingsStore, registry: RuntimeRegistry<AgentCapability>,
        lease: AgentLibraryAccessLease, timeout: Duration
    ) async throws -> AgentModelDiscoveryResult {
        let snapshot = try await registry.freeze()
        let catalog: AgentRuntimeCatalog
        do { catalog = try AgentRuntimeCatalog(snapshot: snapshot) } catch {
            await snapshot.release()
            throw error
        }
        do {
            let connection = try await lease.read { try await settings.connection(id: connectionID) }
            guard let connection, connection.id == connectionID else {
                throw MiraError(.notFound, "The configured model connection is unavailable.")
            }
            let previous = try await lease.read { try await settings.discoverySnapshot(connectionID: connectionID) }
            let provider = try catalog.modelDiscovery(identity: adapter)
            try provider.descriptor().validate(connection)
            let resource = try await lease.start {
                let operation = provider.discover(connection: connection)
                return AgentLibraryResource(value: operation) { await operation.close() }
            }
            let models: [AgentDiscoveredModel]
            do {
                models = try await withThrowingTaskGroup(of: [AgentDiscoveredModel].self) { group in
                    group.addTask { try await resource.value.result() }
                    group.addTask {
                        try await Task.sleep(for: timeout)
                        throw MiraError(.timeout, "Model discovery timed out.")
                    }
                    do {
                        guard let result = try await group.next() else { throw CancellationError() }
                        group.cancelAll()
                        await resource.release()
                        return result
                    } catch {
                        group.cancelAll()
                        await resource.release()
                        throw error
                    }
                }
                await resource.release()
            } catch {
                await resource.release()
                throw error
            }
            let current = try await lease.read { try await settings.connection(id: connectionID) }
            guard current?.configurationRevision == connection.configurationRevision,
                current?.isEnabled == true, current?.discovery == connection.discovery else {
                throw MiraError(.conflict, "The model connection changed during discovery.")
            }
            try await lease.check()
            guard (previous?.revision ?? 0) < Int.max else {
                throw MiraError(.conflict, "The discovery snapshot revision is exhausted.")
            }
            let discoverySnapshot = AgentModelDiscoverySnapshot(
                connectionID: connectionID, configurationRevision: connection.configurationRevision,
                revision: (previous?.revision ?? 0) + 1, adapter: adapter, observedAt: Date(), models: models)
            try await settings.saveDiscoverySnapshot(discoverySnapshot, expectedRevision: previous?.revision,
                                                     authorization: lease.authorization)
            await catalog.release()
            return .init(adapter: adapter, connection: connection, models: models)
        } catch {
            await catalog.release()
            throw error
        }
    }
}
