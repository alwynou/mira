import Foundation

public enum ConnectionTag: Sendable {}
public enum ModelDescriptorTag: Sendable {}
public typealias ConnectionID = EntityID<ConnectionTag>
public typealias ModelDescriptorID = EntityID<ModelDescriptorTag>

public enum ModelPurpose: String, Codable, CaseIterable, Sendable { case conversation, memoryExtraction }
public enum RouteSelectionSource: String, Codable, Sendable { case explicit, conversation, workspace, global }

public struct ProviderConnection: Identifiable, Codable, Sendable, Equatable {
    public var id: ConnectionID
    public var revision: Int
    public var name: String
    public var providerKind: ProviderKind
    public var baseURL: String
    public var credentialReference: String
    public var credentialVersion: Int
    public var allowsLoopbackHTTP: Bool
    public var isEnabled: Bool
    public init(id: ConnectionID = .init(), revision: Int = 1, name: String, providerKind: ProviderKind, baseURL: String, credentialReference: String, credentialVersion: Int = 1, allowsLoopbackHTTP: Bool = false, isEnabled: Bool = true) {
        self.id = id; self.revision = revision; self.name = name; self.providerKind = providerKind
        self.baseURL = baseURL; self.credentialReference = credentialReference
        self.credentialVersion = credentialVersion; self.allowsLoopbackHTTP = allowsLoopbackHTTP; self.isEnabled = isEnabled
    }
    public func validate() throws {
        guard revision > 0, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.count <= 100, !credentialReference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              credentialVersion > 0 else {
            throw MiraError(.configuration, "Connection name and credential reference are required.")
        }
        _ = try validatedEndpoint()
    }
    public func validatedEndpoint() throws -> URL {
        try ProviderEndpoint.resolve(kind: providerKind, baseURL: baseURL, allowsLoopbackHTTP: allowsLoopbackHTTP)
    }
}

public struct ModelDescriptor: Identifiable, Codable, Sendable, Equatable {
    public var id: ModelDescriptorID
    public var revision: Int
    public var connectionID: ConnectionID
    public var connectionRevision: Int
    public var modelID: String
    public var contextWindow: Int?
    public var textCapability: CapabilityState
    public var toolCapability: CapabilityState
    public var probeObservation: ProbeObservation?
    public var isEnabled: Bool
    public var poolRouteID: RouteID { RouteID(id.rawValue) }
    public init(id: ModelDescriptorID = .init(), revision: Int = 1, connectionID: ConnectionID, connectionRevision: Int = 1, modelID: String, contextWindow: Int? = nil, textCapability: CapabilityState = .unknown, toolCapability: CapabilityState = .unknown, probeObservation: ProbeObservation? = nil, isEnabled: Bool = true) {
        self.id = id; self.revision = revision; self.connectionID = connectionID; self.modelID = modelID
        self.connectionRevision = connectionRevision
        self.contextWindow = contextWindow; self.textCapability = textCapability
        self.toolCapability = toolCapability; self.probeObservation = probeObservation; self.isEnabled = isEnabled
    }
    public func validate() throws {
        guard revision > 0, connectionRevision > 0, !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, modelID.count <= 300,
              contextWindow.map({ $0 > 0 && $0 <= 10_000_000 }) ?? true else {
            throw MiraError(.configuration, "Enter a model ID and a valid context window, or leave the window unknown.")
        }
    }
}

public struct ModelPoolEntry: Identifiable, Sendable {
    public let model: ModelDescriptor
    public let connection: ProviderConnection
    public let route: ModelRoute
    public var id: ModelDescriptorID { model.id }

    public init(model: ModelDescriptor, connection: ProviderConnection, route: ModelRoute) {
        self.model = model; self.connection = connection; self.route = route
    }
}

/// A reusable model preset. Purpose and scope selection belong to RouteBinding.
public struct ModelRoute: Identifiable, Codable, Sendable, Equatable {
    public var id: RouteID
    public var revision: Int
    public var name: String
    public var modelDescriptorID: ModelDescriptorID
    public var maxOutputTokens: Int
    public var requestsUsage: Bool
    public init(id: RouteID = .init(), revision: Int = 1, name: String, modelDescriptorID: ModelDescriptorID, maxOutputTokens: Int = 1024, requestsUsage: Bool = true) {
        self.id = id; self.revision = revision; self.name = name; self.modelDescriptorID = modelDescriptorID
        self.maxOutputTokens = maxOutputTokens; self.requestsUsage = requestsUsage
    }
    public func validate() throws {
        guard revision > 0, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 100,
              maxOutputTokens > 0, maxOutputTokens <= 10_000_000 else {
            throw MiraError(.configuration, "Enter a route name and a valid maximum output token count.")
        }
    }
}

public enum RouteScope: Codable, Sendable, Equatable, Hashable {
    case global
    case workspace(WorkspaceID)
    case conversation(ConversationID)
    public var key: String {
        switch self {
        case .global: "global"
        case .workspace(let id): "workspace:\(id.rawValue.uuidString.lowercased())"
        case .conversation(let id): "conversation:\(id.rawValue.uuidString.lowercased())"
        }
    }
}

public struct RouteBinding: Identifiable, Codable, Sendable, Equatable {
    public var scope: RouteScope
    public var purpose: ModelPurpose
    public var routeID: RouteID
    public var revision: Int
    public var id: String { "\(scope.key):\(purpose.rawValue)" }
    public init(scope: RouteScope, purpose: ModelPurpose, routeID: RouteID, revision: Int = 1) {
        self.scope = scope; self.purpose = purpose; self.routeID = routeID; self.revision = revision
    }
}

public struct ModelConfiguration: Sendable, Equatable {
    public var connections: [ProviderConnection]
    public var models: [ModelDescriptor]
    public var routes: [ModelRoute]
    public var bindings: [RouteBinding]
    public init(connections: [ProviderConnection], models: [ModelDescriptor], routes: [ModelRoute], bindings: [RouteBinding]) {
        self.connections = connections; self.models = models; self.routes = routes; self.bindings = bindings
    }

    /// Every active model has one stable route for the normal model picker. The
    /// pool intentionally includes models with unknown capabilities; sending
    /// remains gated by route resolution and capability validation.
    public var modelPool: [ModelPoolEntry] {
        let connectionsByID = Dictionary(uniqueKeysWithValues: connections.map { ($0.id, $0) })
        let routesByID = Dictionary(uniqueKeysWithValues: routes.map { ($0.id, $0) })
        return models.compactMap { model in
            guard model.isEnabled, let connection = connectionsByID[model.connectionID], connection.isEnabled,
                  let route = routesByID[model.poolRouteID], route.modelDescriptorID == model.id else { return nil }
            return ModelPoolEntry(model: model, connection: connection, route: route)
        }.sorted {
            let lhsProvider = $0.connection.name.lowercased(), rhsProvider = $1.connection.name.lowercased()
            if lhsProvider != rhsProvider { return lhsProvider < rhsProvider }
            let lhsModel = $0.model.modelID.lowercased(), rhsModel = $1.model.modelID.lowercased()
            if lhsModel != rhsModel { return lhsModel < rhsModel }
            return $0.model.id.rawValue.uuidString.lowercased() < $1.model.id.rawValue.uuidString.lowercased()
        }
    }

    public func resolve(purpose: ModelPurpose, explicitRouteID: RouteID? = nil, conversation: Conversation? = nil, workspace: Workspace? = nil) throws -> ResolvedModelRouteSnapshot {
        if let workspace, !workspace.allowsRemoteSend {
            throw MiraError(.unauthorized, "This workspace does not allow sending to model services. Change this in workspace settings.")
        }
        if let conversation, conversation.workspaceID != workspace?.id {
            throw MiraError(.unauthorized, "The conversation does not match the routing workspace.")
        }
        let candidates: [(RouteID?, RouteSelectionSource)] = [
            (explicitRouteID, .explicit),
            (conversation.flatMap { item in bindings.first { $0.scope == .conversation(item.id) && $0.purpose == purpose }?.routeID }, .conversation),
            (workspace.flatMap { item in bindings.first { $0.scope == .workspace(item.id) && $0.purpose == purpose }?.routeID }, .workspace),
            (bindings.first { $0.scope == .global && $0.purpose == purpose }?.routeID, .global)
        ]
        guard let selected = candidates.first(where: { $0.0 != nil }), let routeID = selected.0 else {
            throw MiraError(.configuration, "Configure a model route for this purpose in Settings.")
        }
        let snapshot = try snapshot(routeID: routeID, purpose: purpose, selection: selected.1)
        if let allowed = workspace?.allowedConnectionIDs, !allowed.contains(snapshot.connectionID) {
            throw MiraError(.unauthorized, "This workspace does not allow the selected provider connection.")
        }
        try snapshot.validateForSending()
        return snapshot
    }

    public func snapshot(routeID: RouteID, purpose: ModelPurpose = .conversation, selection: RouteSelectionSource = .explicit) throws -> ResolvedModelRouteSnapshot {
        guard let route = routes.first(where: { $0.id == routeID }),
              let model = models.first(where: { $0.id == route.modelDescriptorID }),
              let connection = connections.first(where: { $0.id == model.connectionID }) else {
            throw MiraError(.configuration, "The route, model, or provider connection no longer exists.")
        }
        try route.validate(); try model.validate(); try connection.validate()
        guard connection.isEnabled else { throw MiraError(.configuration, "The provider connection is disabled.") }
        guard model.isEnabled else { throw MiraError(.configuration, "The provider model is disabled.") }
        return ResolvedModelRouteSnapshot(route: route, model: model, connection: connection, purpose: purpose, selection: selection)
    }
}

enum ProviderEndpoint {
    static func resolve(kind: ProviderKind, baseURL: String, allowsLoopbackHTTP: Bool) throws -> URL {
        guard let components = URLComponents(string: baseURL), let host = components.host?.lowercased(),
              !host.isEmpty, components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            throw MiraError(.configuration, "Enter a service URL without credentials, query parameters, or fragments.")
        }
        let loopback = ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host)
        guard components.scheme == "https" || (components.scheme == "http" && loopback && allowsLoopbackHTTP) else {
            throw MiraError(.configuration, "Service URL must use HTTPS; explicitly enable HTTP for loopback services.")
        }
        guard var url = components.url else { throw MiraError(.configuration, "Service URL is invalid.") }
        if url.path.hasSuffix("/chat/completions") || url.path.hasSuffix("/messages") {
            throw MiraError(.configuration, "Enter a base URL without chat/completions or messages.")
        }
        if kind == .anthropic && !url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).hasSuffix("v1") {
            url.appendPathComponent("v1")
        }
        url.appendPathComponent(kind == .anthropic ? "messages" : "chat/completions")
        return url
    }
}
