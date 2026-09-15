import Foundation

/// Advisory identities only. Discovery cannot attest execution capabilities or select a route.
public struct AgentDiscoveredModel: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let displayName: String?
    public let facts: [AgentModelMetadataFact]
    public init(id: String, displayName: String? = nil, facts: [AgentModelMetadataFact] = []) {
        self.id = id
        self.displayName = displayName
        self.facts = facts
    }
    public func validate() throws {
        for fact in facts { try fact.validate() }
        guard facts.count <= 64, !id.isEmpty, id.utf8.count <= 512,
            !id.unicodeScalars.contains(where: {
                CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
            }),
            displayName.map({
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 512
                    && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            }) ?? true
        else {
            throw MiraError(.malformedStream, "The discovered model identity is invalid.")
        }
    }
}

public struct AgentModelDiscoveryDescriptor: Sendable, Equatable {
    public let adapter: AgentAdapterIdentity
    public let title: String
    public let credential: AgentCredentialRequirement
    public let connection: AgentConfigurationSchema
    public init(
        adapter: AgentAdapterIdentity, title: String, credential: AgentCredentialRequirement,
        connection: AgentConfigurationSchema
    ) {
        self.adapter = adapter
        self.title = title
        self.credential = credential
        self.connection = connection
    }
    public func validate() throws {
        try adapter.validate()
        try connection.validate()
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.utf8.count <= 256 else {
            throw MiraError(.configuration, "The model discovery descriptor is invalid.")
        }
    }
    public func validate(_ value: AgentConfiguredConnection) throws {
        try validate()
        try value.validate()
        guard value.isEnabled else { throw MiraError(.unauthorized, "This provider connection is disabled.") }
        guard value.discovery?.adapter == adapter else {
            throw MiraError(.configuration, "The selected discovery protocol does not match this connection.")
        }
        try connection.validate(value.discoveryEndpoint.configuration)
        switch credential {
        case .required:
            guard try value.discoveryEndpoint.credential != nil else {
                throw MiraError(.credentialMissing, "The provider credential is unavailable.")
            }
        case .none:
            guard try value.discoveryEndpoint.credential == nil else {
                throw MiraError(.configuration, "This discovery provider does not accept a credential reference.")
            }
        case .optional: break
        }
    }
}

/// Closing coalesces cancellation and waits for both the producer and its underlying resources.
public final class AgentModelDiscoveryOperation: Sendable {
    private let producer: Task<[AgentDiscoveredModel], any Error>
    private let release: RuntimeRelease
    public init(
        producer: Task<[AgentDiscoveredModel], any Error>,
        cancelAndDrain: @escaping @Sendable () async -> Void
    ) {
        self.producer = producer
        release = RuntimeRelease {
            producer.cancel()
            await cancelAndDrain()
            _ = await producer.result
        }
    }
    public func result() async throws -> [AgentDiscoveredModel] {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let result = try await producer.value
            try Task.checkCancellation()
            guard result.count <= 2_000, Set(result.map(\.id)).count == result.count else {
                throw MiraError(.outputLimit, "The discovered model list is duplicated or exceeds its limit.")
            }
            for model in result { try model.validate() }
            return result.sorted { $0.id < $1.id }
        } onCancel: {
            Task { await self.close() }
        }
    }
    public func close() async { await release.release() }
}

public protocol AgentModelDiscoveryProvider: Sendable {
    var identity: AgentAdapterIdentity { get }
    /// Pure metadata; no credentials or network I/O.
    func descriptor() throws -> AgentModelDiscoveryDescriptor
    /// Starts an owned producer without synchronous I/O. The caller must close it on every exit.
    func discover(connection: AgentConfiguredConnection) -> AgentModelDiscoveryOperation
}

/// Exact settings provenance prevents a late response from being applied to an edited connection.
public struct AgentModelDiscoveryResult: Sendable, Equatable {
    public let adapter: AgentAdapterIdentity
    public let connection: AgentConfiguredConnection
    public let models: [AgentDiscoveredModel]
    public init(adapter: AgentAdapterIdentity, connection: AgentConfiguredConnection, models: [AgentDiscoveredModel]) {
        self.adapter = adapter
        self.connection = connection
        self.models = models
    }
}

/// Only a complete, validated discovery operation can replace this snapshot.
public struct AgentModelDiscoverySnapshot: Codable, Sendable, Equatable {
    public let connectionID: ConnectionID
    public let configurationRevision: Int
    public let revision: Int
    public let adapter: AgentAdapterIdentity
    public let observedAt: Date
    public let models: [AgentDiscoveredModel]
    public init(connectionID: ConnectionID, configurationRevision: Int, revision: Int,
                adapter: AgentAdapterIdentity, observedAt: Date, models: [AgentDiscoveredModel]) {
        self.connectionID = connectionID; self.configurationRevision = configurationRevision
        self.revision = revision; self.adapter = adapter; self.observedAt = observedAt; self.models = models
    }
    public func validate() throws {
        try adapter.validate()
        guard configurationRevision > 0, revision > 0, observedAt.timeIntervalSince1970.isFinite,
            models.count <= 2_000, models.map(\.id) == models.map(\.id).sorted(),
            Set(models.map(\.id)).count == models.count,
            try SessionCodec.encode(self).count <= 2_097_152 else {
            throw MiraError(.configuration, "The model discovery snapshot is invalid.")
        }
        for model in models { try model.validate() }
    }
}
