import Foundation

public struct AgentModelMetadataDocument: Codable, Sendable, Equatable {
    public let schema: AgentConfigurationIdentity
    public let sourceRevision: String
    public let observedAt: Date
    public let payload: JSONValue
    public init(schema: AgentConfigurationIdentity, sourceRevision: String, observedAt: Date, payload: JSONValue) {
        self.schema = schema; self.sourceRevision = sourceRevision; self.observedAt = observedAt; self.payload = payload
    }
    public func validate() throws {
        try schema.validate()
        guard !sourceRevision.isEmpty, sourceRevision.utf8.count <= 256, observedAt.timeIntervalSince1970.isFinite,
            case .object = payload, try SessionCodec.encode(self).count <= 8_388_608 else {
            throw MiraError(.configuration, "The model metadata document is invalid or too large.")
        }
    }
}

public struct AgentModelMetadataSnapshot: Codable, Sendable, Equatable {
    public let sourceID: String
    public let revision: Int
    public let document: AgentModelMetadataDocument
    public init(sourceID: String, revision: Int, document: AgentModelMetadataDocument) {
        self.sourceID = sourceID; self.revision = revision; self.document = document
    }
    public func validate() throws {
        try document.validate()
        guard SessionState.validIdentifier(sourceID, maximumBytes: 128), revision > 0 else {
            throw MiraError(.configuration, "The model metadata snapshot is invalid.")
        }
    }
}

public struct AgentModelMetadataUpdate: Sendable {
    public let connection: AgentConfiguredConnection
    public let previous: AgentConfiguredModel
    public let updated: AgentConfiguredModel
    public init(connection: AgentConfiguredConnection, previous: AgentConfiguredModel, updated: AgentConfiguredModel) {
        self.connection = connection; self.previous = previous; self.updated = updated
    }
    public func validate() throws {
        try connection.validate(); try previous.validate(); try updated.validate()
        guard previous.revision < Int.max, updated.revision == previous.revision + 1,
            previous.id == updated.id, previous.reference == updated.reference,
            previous.connectionID == connection.id, previous.displayName == updated.displayName,
            previous.isEnabled == updated.isEnabled, previous.authorizationRevision == updated.authorizationRevision,
            previous.invocations.map(\.id) == updated.invocations.map(\.id),
            previous.facts.filter({ $0.source != .catalog }) == updated.facts.filter({ $0.source != .catalog }) else {
            throw MiraError(.configuration, "Model metadata cannot replace user configuration or selection.")
        }
        for (old, new) in zip(previous.invocations, updated.invocations) {
            guard old.adapter == new.adapter, old.endpointID == new.endpointID,
                old.configuration.schema == new.configuration.schema else {
                throw MiraError(.configuration, "Model metadata cannot change the configured protocol or endpoint.")
            }
        }
    }
}

public final class AgentModelMetadataOperation: Sendable {
    private let producer: Task<AgentModelMetadataDocument, any Error>
    private let release: RuntimeRelease
    public init(producer: Task<AgentModelMetadataDocument, any Error>, cancelAndDrain: @escaping @Sendable () async -> Void) {
        self.producer = producer
        release = RuntimeRelease { producer.cancel(); await cancelAndDrain(); _ = await producer.result }
    }
    public func result() async throws -> AgentModelMetadataDocument {
        try await withTaskCancellationHandler {
            let value = try await producer.value
            try Task.checkCancellation(); try value.validate()
            return value
        } onCancel: { self.producer.cancel() }
    }
    public func close() async { await release.release() }
}

public protocol AgentModelMetadataProvider: Sendable {
    var identity: AgentAdapterIdentity { get }
    /// This request has no connection, credential, private model ID or conversation input.
    func fetch() -> AgentModelMetadataOperation
    /// Pure local interpretation by the installed module; remote data has no mutation authority.
    func updates(document: AgentModelMetadataDocument, connections: [AgentConfiguredConnection],
                 models: [AgentConfiguredModel]) throws -> [AgentModelMetadataUpdate]
}

public protocol AgentModelMetadataStore: Sendable {
    func snapshot(sourceID: String, authorization: AgentLibraryAuthorization) async throws -> AgentModelMetadataSnapshot?
    /// Publishes a complete generation and all model metadata updates in one authoritative transaction.
    func publish(_ snapshot: AgentModelMetadataSnapshot, expectedRevision: Int?, updates: [AgentModelMetadataUpdate],
                 authorization: AgentLibraryAuthorization) async throws
}

/// Owns explicit refreshes. Startup and dispatch never require a remote catalog request.
public actor AgentModelMetadataService {
    private let settings: any AgentModelSettingsStore
    private let store: any AgentModelMetadataStore
    private let registry: RuntimeRegistry<AgentCapability>
    private let access: AgentLibraryAccess
    private let scope: RuntimeScope
    private let timeout: Duration
    private var owners: [UUID: Task<AgentModelMetadataSnapshot?, any Error>] = [:]
    private var closed = false
    private var closeTask: Task<Void, Never>?

    public init(settings: any AgentModelSettingsStore, store: any AgentModelMetadataStore,
                registry: RuntimeRegistry<AgentCapability>, access: AgentLibraryAccess, scope: RuntimeScope,
                timeout: Duration = .seconds(45)) throws {
        guard timeout > .zero, timeout <= .seconds(120) else {
            throw MiraError(.configuration, "The model metadata timeout is invalid.")
        }
        self.settings = settings; self.store = store; self.registry = registry
        self.access = access; self.scope = scope; self.timeout = timeout
    }
    public func snapshot(sourceID: String) async throws -> AgentModelMetadataSnapshot? {
        try await owned(sourceID: sourceID, refresh: false)
    }
    public func refresh(sourceID: String) async throws -> AgentModelMetadataSnapshot {
        guard let result = try await owned(sourceID: sourceID, refresh: true) else {
            throw MiraError(.storage, "The model metadata refresh did not produce a snapshot.")
        }
        return result
    }
    public func close() async {
        if let closeTask { await closeTask.value; return }
        closed = true
        let tasks = Array(owners.values)
        for task in tasks { task.cancel() }
        let drain = Task { for task in tasks { _ = await task.result } }
        closeTask = drain
        await drain.value
    }
    private func owned(sourceID: String, refresh: Bool) async throws -> AgentModelMetadataSnapshot? {
        try Task.checkCancellation()
        guard !closed, owners.count < 8 else { throw MiraError(.busy, "The model metadata service is unavailable or busy.") }
        try AgentAdapterIdentity(id: sourceID, revision: 1).validate()
        let id = UUID(), access = access, scope = scope, settings = settings, store = store, registry = registry, timeout = timeout
        let task = Task<AgentModelMetadataSnapshot?, any Error> {
            let lease = try await access.acquire(in: scope)
            let work = Task {
                let previous = try await store.snapshot(sourceID: sourceID, authorization: lease.authorization)
                guard refresh else { return previous }
                return try await Self.refresh(sourceID: sourceID, previous: previous, settings: settings,
                                              store: store, registry: registry, lease: lease, timeout: timeout)
            }
            do {
                try lease.bindCancellation { work.cancel() }
                let result = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                await lease.release()
                return result
            } catch {
                work.cancel(); _ = await work.result; await lease.release(); throw error
            }
        }
        owners[id] = task
        defer { owners[id] = nil }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    private static func refresh(sourceID: String, previous: AgentModelMetadataSnapshot?,
                                settings: any AgentModelSettingsStore, store: any AgentModelMetadataStore,
                                registry: RuntimeRegistry<AgentCapability>, lease: AgentLibraryAccessLease,
                                timeout: Duration) async throws -> AgentModelMetadataSnapshot {
        let frozen = try await registry.freeze()
        let catalog: AgentRuntimeCatalog
        do { catalog = try AgentRuntimeCatalog(snapshot: frozen) } catch { await frozen.release(); throw error }
        do {
            let provider = try catalog.modelMetadata(id: sourceID)
            let resource = try await lease.start {
                let operation = provider.fetch()
                return AgentLibraryResource(value: operation) { await operation.close() }
            }
            let document: AgentModelMetadataDocument
            do {
                document = try await withThrowingTaskGroup(of: AgentModelMetadataDocument.self) { group in
                    group.addTask { try await resource.value.result() }
                    group.addTask { try await Task.sleep(for: timeout); throw MiraError(.timeout, "The model metadata refresh timed out.") }
                    do {
                        guard let value = try await group.next() else { throw CancellationError() }
                        group.cancelAll()
                        await resource.release()
                        return value
                    } catch {
                        group.cancelAll()
                        // Close the owned transport before waiting for a cancellation-insensitive child.
                        await resource.release()
                        throw error
                    }
                }
                await resource.release()
            } catch { await resource.release(); throw error }
            try document.validate()
            var connections: [AgentConfiguredConnection] = []
            while true {
                let cursor = connections.last?.id
                let page = try await lease.read { try await settings.connections(after: cursor, limit: 128) }
                connections += page
                guard connections.count <= 128 else { throw MiraError(.outputLimit, "The model metadata connection limit was exceeded.") }
                if page.count < 128 { break }
            }
            var models: [AgentConfiguredModel] = []
            while true {
                let cursor = models.last?.id
                let page = try await lease.read { try await settings.models(connectionID: nil, after: cursor, limit: 128) }
                models += page
                guard models.count <= 4_096 else { throw MiraError(.outputLimit, "The model metadata model limit was exceeded.") }
                if page.count < 128 { break }
            }
            let updates = try provider.updates(document: document, connections: connections, models: models)
            guard updates.count <= 4_096, Set(updates.map { $0.previous.id }).count == updates.count,
                (previous?.revision ?? 0) < Int.max else {
                throw MiraError(.configuration, "The model metadata update set is invalid.")
            }
            for update in updates { try update.validate() }
            try Task.checkCancellation(); try await lease.check()
            let snapshot = AgentModelMetadataSnapshot(sourceID: sourceID, revision: (previous?.revision ?? 0) + 1, document: document)
            try await store.publish(snapshot, expectedRevision: previous?.revision, updates: updates, authorization: lease.authorization)
            await catalog.release()
            return snapshot
        } catch { await catalog.release(); throw error }
    }
}
