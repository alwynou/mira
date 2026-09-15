import Foundation

/// This epoch belongs to the durable business library, independently of each session's invalidation counter.
public struct AgentLibraryAuthorization: Codable, Sendable, Equatable, Hashable {
    public let libraryID: UUID
    public let epoch: UInt64
    public init(libraryID: UUID, epoch: UInt64) { self.libraryID = libraryID; self.epoch = epoch }
}

/// Maintenance intent contains identities only. The registered domain operation owns their meaning.
public enum AgentLibraryMaintenanceScope: Codable, Sendable, Equatable {
    case library
    case sources([AgentSourceReference])

    public func validate() throws {
        if case .sources(let sources) = self {
            guard !sources.isEmpty, sources.count <= 8_192, Set(sources).count == sources.count else {
                throw MiraError(.invalidInput, "The library maintenance source selection is invalid.")
            }
            for source in sources { try source.validate() }
        }
    }
}

public struct AgentLibraryMaintenanceRequest: Codable, Sendable, Equatable {
    public let id: UUID
    public let namespace: String
    public let revision: Int
    public let scope: AgentLibraryMaintenanceScope
    public let requestedAt: Date

    public init(id: UUID, namespace: String, revision: Int, scope: AgentLibraryMaintenanceScope, requestedAt: Date) {
        self.id = id; self.namespace = namespace; self.revision = revision
        self.scope = scope; self.requestedAt = requestedAt
    }

    public func validate() throws {
        guard SessionState.validIdentifier(namespace, maximumBytes: 128), revision > 0,
              requestedAt.timeIntervalSince1970.isFinite else {
            throw MiraError(.invalidInput, "The library maintenance request is invalid.")
        }
        try scope.validate()
    }
}

/// The start transaction advances authorization exactly once and remains pending across restarts.
public struct AgentLibraryMaintenanceOperation: Codable, Sendable, Equatable {
    public let request: AgentLibraryMaintenanceRequest
    public let previousAuthorization: AgentLibraryAuthorization
    public let authorization: AgentLibraryAuthorization
    public let completedAt: Date?

    public init(request: AgentLibraryMaintenanceRequest, previousAuthorization: AgentLibraryAuthorization,
                authorization: AgentLibraryAuthorization, completedAt: Date?) {
        self.request = request; self.previousAuthorization = previousAuthorization
        self.authorization = authorization; self.completedAt = completedAt
    }

    public func validate() throws {
        try request.validate()
        guard previousAuthorization.libraryID == authorization.libraryID,
              previousAuthorization.epoch < UInt64.max,
              authorization.epoch == previousAuthorization.epoch + 1,
              completedAt?.timeIntervalSince1970.isFinite ?? true else {
            throw MiraError(.invalidInput, "The library maintenance operation is invalid.")
        }
    }
}

public struct AgentLibraryMaintenanceState: Sendable, Equatable {
    public let authorization: AgentLibraryAuthorization
    public let pending: AgentLibraryMaintenanceOperation?
    public init(authorization: AgentLibraryAuthorization, pending: AgentLibraryMaintenanceOperation?) {
        self.authorization = authorization; self.pending = pending
    }
}

/// The maintenance coordinator owns completion, after domain, journal and payload cleanup is verified.
/// Reading these facts never grants a body-read, model dispatch, or business commit permission.
public protocol AgentLibraryMaintenanceStore: Sendable {
    func state() async throws -> AgentLibraryMaintenanceState
    func operation(id: UUID) async throws -> AgentLibraryMaintenanceOperation?
    func begin(_ request: AgentLibraryMaintenanceRequest, expected: AgentLibraryAuthorization) async throws -> AgentLibraryMaintenanceOperation
    func complete(_ operation: AgentLibraryMaintenanceOperation, at date: Date) async throws -> AgentLibraryMaintenanceOperation
}

extension AgentLibraryMaintenanceStore {
    public func authorization() async throws -> AgentLibraryAuthorization {
        let state = try await state()
        guard state.pending == nil else {
            throw MiraError(.unauthorized, "Library maintenance prevents new authorization.")
        }
        return state.authorization
    }
}
