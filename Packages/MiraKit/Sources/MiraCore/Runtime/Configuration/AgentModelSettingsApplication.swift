import Foundation

/// Host-facing settings operations. The application owns operation lifetime and
/// keeps the runtime catalog frozen only for the call that uses it.
public actor AgentModelSettingsApplication {
    private enum OperationKind { case read, write }

    private let store: any AgentModelSettingsStore
    private let registry: RuntimeRegistry<AgentCapability>
    private let access: AgentLibraryAccess
    private let scope: RuntimeScope
    private let maximumConcurrentOperations: Int
    private var operations: [UUID: @Sendable () async -> Void] = [:]
    private var closed = false
    private var closeTask: Task<Void, Never>?

    public init(
        store: any AgentModelSettingsStore,
        registry: RuntimeRegistry<AgentCapability>,
        access: AgentLibraryAccess,
        scope: RuntimeScope,
        maximumConcurrentOperations: Int = 64
    ) throws {
        guard (1...256).contains(maximumConcurrentOperations) else {
            throw MiraError(.configuration, "The model settings application operation limit is invalid.")
        }
        self.store = store
        self.registry = registry
        self.access = access
        self.scope = scope
        self.maximumConcurrentOperations = maximumConcurrentOperations
    }

    public func discoverySnapshot(connectionID: ConnectionID) async throws -> AgentModelDiscoverySnapshot? {
        try await run(.read) { lease in
            try await lease.read { try await self.store.discoverySnapshot(connectionID: connectionID) }
        }
    }

    public func connection(id: ConnectionID) async throws -> AgentConfiguredConnection? {
        try await run(.read) { lease in
            try await lease.read { try await self.store.connection(id: id) }
        }
    }

    public func model(id: ModelDescriptorID) async throws -> AgentConfiguredModel? {
        try await run(.read) { lease in
            try await lease.read { try await self.store.model(id: id) }
        }
    }

    public func preset(id: RouteID) async throws -> AgentRoutePreset? {
        try await run(.read) { lease in
            try await lease.read { try await self.store.preset(id: id) }
        }
    }

    public func connections(after: ConnectionID?, limit: Int) async throws -> [AgentConfiguredConnection] {
        try await run(.read) { lease in
            try await lease.read { try await self.store.connections(after: after, limit: limit) }
        }
    }

    public func models(connectionID: ConnectionID?, after: ModelDescriptorID?, limit: Int) async throws
        -> [AgentConfiguredModel]
    {
        try await run(.read) { lease in
            try await lease.read {
                try await self.store.models(connectionID: connectionID, after: after, limit: limit)
            }
        }
    }

    public func presets(modelID: ModelDescriptorID?, after: RouteID?, limit: Int) async throws
        -> [AgentRoutePreset]
    {
        try await run(.read) { lease in
            try await lease.read { try await self.store.presets(modelID: modelID, after: after, limit: limit) }
        }
    }

    public func bindings(scope: AgentRouteScope) async throws -> [AgentRouteBinding] {
        try await run(.read) { lease in
            try await lease.read { try await self.store.bindings(scope: scope) }
        }
    }

    public func candidate(routeID: RouteID) async throws -> AgentModelRouteCandidate {
        try await run(.read) { lease in
            try await lease.read { try await self.store.candidate(routeID: routeID) }
        }
    }

    public func configurationDescriptors(for invocation: AgentModelInvocationSpec) async throws -> [AgentModelConfigurationDescriptor] {
        try await run(.read) { lease in
            try await lease.read {
                try await self.withCatalog { catalog in
                    try catalog.modelConfigurationDescriptors(for: invocation)
                }
            }
        }
    }

    public func discoveryDescriptors() async throws -> [AgentModelDiscoveryDescriptor] {
        try await run(.read) { lease in
            try await lease.read {
                try await self.withCatalog { catalog in
                    try catalog.modelDiscoveryDescriptors()
                }
            }
        }
    }

    public func resolve(
        purpose: String,
        explicitRouteID: RouteID?,
        sessionSelection: AgentSessionModelSelection,
        workspaceID: WorkspaceID?,
        requiredCapabilities: Set<String> = []
    ) async throws -> AgentModelRouteResolution {
        try await run(.read) { lease in
            try await lease.read {
                try await self.withCatalog { catalog in
                    try await AgentModelRouteResolver(settings: self.store).resolve(
                        purpose: purpose, explicitRouteID: explicitRouteID, sessionSelection: sessionSelection,
                        workspaceID: workspaceID, catalog: catalog, requiredCapabilities: requiredCapabilities)
                }
            }
        }
    }

    public func ensureConversationDefault() async throws -> AgentRouteBinding? {
        try await run(.write) { lease in
            try await lease.check()
            return try await self.store.ensureConversationDefault(authorization: lease.authorization)
        }
    }

    public func saveConnection(_ value: AgentConfiguredConnection, expectedRevision: Int?) async throws {
        try await run(.write) { lease in
            try await lease.check()
            try await self.store.saveConnection(
                value, expectedRevision: expectedRevision,
                authorization: lease.authorization)
        }
    }

    public func saveModel(_ value: AgentConfiguredModel, expectedRevision: Int?) async throws {
        try await run(.write) { lease in
            try await lease.check()
            try await self.store.saveModel(
                value, expectedRevision: expectedRevision,
                authorization: lease.authorization)
        }
    }

    public func savePreset(_ value: AgentRoutePreset, expectedRevision: Int?) async throws {
        try await run(.write) { lease in
            try await lease.check()
            try await self.store.savePreset(
                value, expectedRevision: expectedRevision,
                authorization: lease.authorization)
        }
    }

    public func savePoolModel(
        _ model: AgentConfiguredModel,
        preset: AgentRoutePreset,
        expectedModelRevision: Int?,
        expectedPresetRevision: Int?
    ) async throws {
        try await run(.write) { lease in
            try await lease.check()
            try await self.store.savePoolModel(
                model, preset: preset, expectedModelRevision: expectedModelRevision,
                expectedPresetRevision: expectedPresetRevision, authorization: lease.authorization)
        }
    }

    public func saveBinding(_ value: AgentRouteBinding, expectedRevision: Int?) async throws {
        try await run(.write) { lease in
            try await lease.check()
            try await self.store.saveBinding(
                value, expectedRevision: expectedRevision,
                authorization: lease.authorization)
        }
    }

    public func deleteConnection(id: ConnectionID, expectedRevision: Int) async throws {
        try await run(.write) { lease in
            try await lease.check()
            try await self.store.deleteConnection(
                id: id, expectedRevision: expectedRevision,
                authorization: lease.authorization)
        }
    }

    public func deleteModel(id: ModelDescriptorID, expectedRevision: Int) async throws {
        try await run(.write) { lease in
            try await lease.check()
            try await self.store.deleteModel(
                id: id, expectedRevision: expectedRevision,
                authorization: lease.authorization)
        }
    }

    public func deletePreset(id: RouteID, expectedRevision: Int) async throws {
        try await run(.write) { lease in
            try await lease.check()
            try await self.store.deletePreset(
                id: id, expectedRevision: expectedRevision,
                authorization: lease.authorization)
        }
    }

    public func deleteBinding(scope: AgentRouteScope, purpose: String, expectedRevision: Int) async throws {
        try await run(.write) { lease in
            try await lease.check()
            try await self.store.deleteBinding(
                scope: scope, purpose: purpose,
                expectedRevision: expectedRevision,
                authorization: lease.authorization)
        }
    }

    public func close() async {
        if let closeTask {
            await closeTask.value
            return
        }
        closed = true
        let drains = Array(operations.values)
        let task = Task {
            await withTaskGroup(of: Void.self) { group in
                for drain in drains { group.addTask { await drain() } }
            }
        }
        closeTask = task
        await task.value
    }

    private func run<T: Sendable>(
        _ kind: OperationKind,
        _ operation: @escaping @Sendable (AgentLibraryAccessLease) async throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        guard !closed else { throw MiraError(.busy, "The model settings application is closed.") }
        guard operations.count < maximumConcurrentOperations else {
            throw MiraError(.busy, "Too many model settings operations are active.")
        }

        let id = UUID()
        let task = Task {
            defer { self.operations[id] = nil }
            return try await self.perform(operation)
        }
        operations[id] = {
            task.cancel()
            _ = await task.result
        }

        switch kind {
        case .read:
            return try await withTaskCancellationHandler {
                let value = try await task.value
                try Task.checkCancellation()
                return value
            } onCancel: {
                task.cancel()
            }
        case .write:
            return try await task.value
        }
    }

    private nonisolated func perform<T: Sendable>(
        _ operation: @escaping @Sendable (AgentLibraryAccessLease) async throws -> T
    ) async throws -> T {
        let lease = try await access.acquire(in: scope)
        let resource: AgentLibraryResourceLease<Task<T, any Error>>
        do {
            resource = try await lease.start {
                let task = Task { try await operation(lease) }
                return AgentLibraryResource(
                    value: task,
                    cleanup: {
                        task.cancel()
                        _ = await task.result
                    })
            }
        } catch {
            await lease.release()
            throw error
        }

        do {
            try lease.bindCancellation { resource.value.cancel() }
            let value = try await withTaskCancellationHandler {
                try await resource.value.value
            } onCancel: {
                resource.value.cancel()
            }
            await resource.release()
            await lease.release()
            return value
        } catch {
            await resource.release()
            await lease.release()
            throw error
        }
    }

    private nonisolated func withCatalog<T: Sendable>(
        _ operation: @escaping @Sendable (AgentRuntimeCatalog) async throws -> T
    ) async throws -> T {
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
            let value = try await operation(catalog)
            await catalog.release()
            return value
        } catch {
            await catalog.release()
            throw error
        }
    }
}
