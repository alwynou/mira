import Foundation

public enum AgentRouteScope: Codable, Sendable, Equatable, Hashable {
    case global
    case workspace(WorkspaceID)
    public var key: String {
        switch self {
        case .global: "global"
        case .workspace(let id): "workspace:\(id.rawValue.uuidString.lowercased())"
        }
    }
}

/// Purposes are module-owned identifiers; registering a new purpose requires no provider enum edit.
public struct AgentRouteBinding: Codable, Sendable, Equatable {
    public let scope: AgentRouteScope
    public let purpose: String
    public let routeID: RouteID
    public let revision: Int
    public init(scope: AgentRouteScope, purpose: String, routeID: RouteID, revision: Int) {
        self.scope = scope
        self.purpose = purpose
        self.routeID = routeID
        self.revision = revision
    }
    public func validate() throws {
        guard SessionState.validIdentifier(purpose, maximumBytes: 128), revision > 0 else {
            throw MiraError(.configuration, "The model route binding is invalid.")
        }
    }
}

public enum AgentModelPurposeID {
    public static let conversation = "mira.conversation"
    public static let memoryExtraction = "mira.memoryExtraction"
}

public struct AgentModelRouteSelection: Sendable, Equatable {
    public let candidate: AgentModelRouteCandidate
    /// Nil identifies an explicit route selection. A binding is the exact selected revision.
    public let binding: AgentRouteBinding?
    public init(candidate: AgentModelRouteCandidate, binding: AgentRouteBinding?) {
        self.candidate = candidate
        self.binding = binding
    }
}

/// Global and workspace defaults only. Session selection is a journal fact.
/// The host/domain policy validates workspace membership and current sending permission separately.
/// Reads require an available library. Mutations compare authorization with current
/// authority inside the committing transaction, including after any queued wait.
public protocol AgentModelSettingsStore: Sendable {
    func discoverySnapshot(connectionID: ConnectionID) async throws -> AgentModelDiscoverySnapshot?
    func saveDiscoverySnapshot(_ value: AgentModelDiscoverySnapshot, expectedRevision: Int?,
                               authorization: AgentLibraryAuthorization) async throws
    func connection(id: ConnectionID) async throws -> AgentConfiguredConnection?
    func model(id: ModelDescriptorID) async throws -> AgentConfiguredModel?
    func preset(id: RouteID) async throws -> AgentRoutePreset?
    func connections(after: ConnectionID?, limit: Int) async throws -> [AgentConfiguredConnection]
    func models(connectionID: ConnectionID?, after: ModelDescriptorID?, limit: Int) async throws -> [AgentConfiguredModel]
    func presets(modelID: ModelDescriptorID?, after: RouteID?, limit: Int) async throws -> [AgentRoutePreset]
    /// Initialize only an absent conversation binding from the active canonical pool.
    func ensureConversationDefault(authorization: AgentLibraryAuthorization) async throws -> AgentRouteBinding?
    func bindings(scope: AgentRouteScope) async throws -> [AgentRouteBinding]
    /// Read the selected binding, route, model and connection in one database snapshot.
    /// Explicit -> workspace -> global; a present but unusable selection never falls through.
    func select(
        purpose: String, explicitRouteID: RouteID?,
        workspaceID: WorkspaceID?
    ) async throws -> AgentModelRouteSelection
    func candidate(routeID: RouteID) async throws -> AgentModelRouteCandidate
    /// Nil expectedRevision creates revision 1. Updates require the exact previous revision and advance by one.
    /// Endpoint/schema/credential changes also advance configurationRevision by one; other changes preserve it.
    func saveConnection(_ value: AgentConfiguredConnection, expectedRevision: Int?, authorization: AgentLibraryAuthorization) async throws
    /// Capability attestations bind to the current connection configurationRevision, never a query projection.
    func saveModel(_ value: AgentConfiguredModel, expectedRevision: Int?, authorization: AgentLibraryAuthorization) async throws
    func savePreset(_ value: AgentRoutePreset, expectedRevision: Int?, authorization: AgentLibraryAuthorization) async throws
    /// A canonical pool preset uses the model UUID in the route ID domain. Both writes share one transaction.
    func savePoolModel(
        _ model: AgentConfiguredModel, preset: AgentRoutePreset,
        expectedModelRevision: Int?, expectedPresetRevision: Int?, authorization: AgentLibraryAuthorization) async throws
    func saveBinding(_ value: AgentRouteBinding, expectedRevision: Int?, authorization: AgentLibraryAuthorization) async throws
    /// Deleting configuration preserves default references and journal selection intent as invalid references.
    func deleteConnection(id: ConnectionID, expectedRevision: Int, authorization: AgentLibraryAuthorization) async throws
    func deleteModel(id: ModelDescriptorID, expectedRevision: Int, authorization: AgentLibraryAuthorization) async throws
    func deletePreset(id: RouteID, expectedRevision: Int, authorization: AgentLibraryAuthorization) async throws
    func deleteBinding(scope: AgentRouteScope, purpose: String, expectedRevision: Int, authorization: AgentLibraryAuthorization) async throws
}
