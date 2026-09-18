import Foundation

/// A schema identifies non-secret settings independently of an executable adapter.
/// Multiple adapters may deliberately accept the same connection schema.
public struct AgentConfigurationIdentity: Codable, Sendable, Equatable, Hashable {
    public let id: String
    public let revision: Int
    public init(id: String, revision: Int) {
        self.id = id
        self.revision = revision
    }
    public func validate() throws {
        guard SessionState.validIdentifier(id, maximumBytes: 128), revision > 0 else { throw Self.invalid }
    }
    private static var invalid: MiraError { .init(.configuration, "The model settings schema identity is invalid.") }
}

public struct AgentConfigurationValue: Codable, Sendable, Equatable {
    public let schema: AgentConfigurationIdentity
    public let value: JSONValue
    public init(schema: AgentConfigurationIdentity, value: JSONValue) {
        self.schema = schema
        self.value = value
    }
    public func validate() throws {
        try schema.validate()
        guard case .object = value, try SessionCodec.encode(value).count <= 65_536 else {
            throw MiraError(.configuration, "The model settings value is invalid or exceeds its limit.")
        }
    }
}

/// Generic form data. Defaults are draft values, never a claim that an endpoint or credential works.
public struct AgentConfigurationSchema: Codable, Sendable, Equatable {
    public let identity: AgentConfigurationIdentity
    public let title: String
    public let schema: JSONValue
    public let defaults: JSONValue
    public init(identity: AgentConfigurationIdentity, title: String, schema: JSONValue, defaults: JSONValue) {
        self.identity = identity
        self.title = title
        self.schema = schema
        self.defaults = defaults
    }
    public func validate() throws {
        try identity.validate()
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.utf8.count <= 256,
            schema["type"] == .string("object"), try SessionCodec.encode(self).count <= 65_536
        else {
            throw MiraError(.configuration, "The model settings schema is invalid or exceeds its limit.")
        }
        try ToolSchemaValidator.validateSchema(schema)
        try ToolSchemaValidator.validate(defaults, schema: schema)
    }
    public func validate(_ settings: AgentConfigurationValue) throws {
        try validate()
        try settings.validate()
        guard settings.schema == identity else {
            throw MiraError(.configuration, "The model settings do not match the registered schema revision.")
        }
        try ToolSchemaValidator.validate(settings.value, schema: schema)
    }
}

public enum AgentCredentialRequirement: String, Codable, Sendable { case none, optional, required }

public struct AgentModelConfigurationDescriptor: Codable, Sendable, Equatable {
    public let adapter: AgentAdapterIdentity
    public let title: String
    public let credential: AgentCredentialRequirement
    public let connection: AgentConfigurationSchema
    public let route: AgentConfigurationSchema
    public init(
        adapter: AgentAdapterIdentity, title: String, credential: AgentCredentialRequirement,
        connection: AgentConfigurationSchema, route: AgentConfigurationSchema
    ) {
        self.adapter = adapter
        self.title = title
        self.credential = credential
        self.connection = connection
        self.route = route
    }
    public func validate() throws {
        try adapter.validate()
        try connection.validate()
        try route.validate()
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.utf8.count <= 256,
            try SessionCodec.encode(self).count <= 131_072
        else {
            throw MiraError(.configuration, "The model settings descriptor is invalid or exceeds its limit.")
        }
    }
}

/// An invocation address and its credential are configured together. Metadata cannot change either.
public struct AgentModelEndpoint: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let configuration: AgentConfigurationValue
    public let credential: AgentCredentialReference?
    public init(id: String, configuration: AgentConfigurationValue, credential: AgentCredentialReference?) {
        self.id = id; self.configuration = configuration; self.credential = credential
    }
    public func validate() throws {
        try configuration.validate()
        guard SessionState.validIdentifier(id, maximumBytes: 128) else {
            throw MiraError(.configuration, "The model endpoint identity is invalid.")
        }
        if let credential {
            guard credential.version > 0, !credential.reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                credential.reference.utf8.count <= 512 else {
                throw MiraError(.configuration, "The model endpoint credential reference is invalid.")
            }
        }
    }
}

public struct AgentConnectionDiscovery: Codable, Sendable, Equatable {
    public let adapter: AgentAdapterIdentity
    public let endpointID: String
    public init(adapter: AgentAdapterIdentity, endpointID: String) {
        self.adapter = adapter; self.endpointID = endpointID
    }
}

/// The connection's explicit default for newly discovered IDs, independent of model metadata.
public struct AgentModelInvocationTemplate: Codable, Sendable, Equatable {
    public let adapter: AgentAdapterIdentity
    public let endpointID: String
    public let configuration: AgentConfigurationValue
    public init(adapter: AgentAdapterIdentity, endpointID: String, configuration: AgentConfigurationValue) {
        self.adapter = adapter; self.endpointID = endpointID; self.configuration = configuration
    }
}

public struct AgentConfiguredConnection: Codable, Sendable, Equatable, Identifiable {
    public let id: ConnectionID
    public let revision: Int
    /// Authorization revision: endpoint, credential and enablement changes advance this value.
    public let configurationRevision: Int
    public let name: String
    public let isEnabled: Bool
    public let definitionID: String?
    public let endpoints: [AgentModelEndpoint]
    public let discovery: AgentConnectionDiscovery?
    public let defaultInvocation: AgentModelInvocationTemplate?
    public init(id: ConnectionID, revision: Int, configurationRevision: Int, name: String, isEnabled: Bool,
                definitionID: String?, endpoints: [AgentModelEndpoint], discovery: AgentConnectionDiscovery?,
                defaultInvocation: AgentModelInvocationTemplate?) {
        self.id = id; self.revision = revision; self.configurationRevision = configurationRevision
        self.name = name; self.isEnabled = isEnabled; self.definitionID = definitionID
        self.endpoints = endpoints; self.discovery = discovery; self.defaultInvocation = defaultInvocation
    }
    public func endpoint(id: String) throws -> AgentModelEndpoint {
        guard let value = endpoints.first(where: { $0.id == id }) else {
            throw MiraError(.configuration, "The selected model endpoint is unavailable.")
        }
        return value
    }
    public var discoveryEndpoint: AgentModelEndpoint {
        get throws {
            guard let discovery else { throw MiraError(.configuration, "Model discovery is not configured for this connection.") }
            return try endpoint(id: discovery.endpointID)
        }
    }
    public func validate() throws {
        guard revision > 0, configurationRevision > 0, configurationRevision <= revision,
            !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 256,
            definitionID.map({ SessionState.validIdentifier($0, maximumBytes: 128) }) ?? true,
            (1...16).contains(endpoints.count), Set(endpoints.map(\.id)).count == endpoints.count else {
            throw MiraError(.configuration, "The configured model connection is invalid.")
        }
        for endpoint in endpoints { try endpoint.validate() }
        if let discovery { try discovery.adapter.validate(); _ = try endpoint(id: discovery.endpointID) }
        if let template = defaultInvocation {
            try template.adapter.validate(); try template.configuration.validate()
            _ = try endpoint(id: template.endpointID)
        }
    }
}

/// A remote model identity is scoped to the user's actual connection, not a global catalog.
public struct AgentModelReference: Codable, Sendable, Equatable, Hashable {
    public let connectionID: ConnectionID
    public let modelID: String
    public init(connectionID: ConnectionID, modelID: String) { self.connectionID = connectionID; self.modelID = modelID }
    public func validate() throws {
        guard !modelID.isEmpty, modelID.utf8.count <= 512,
            !modelID.unicodeScalars.contains(where: {
                CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
            }) else { throw MiraError(.configuration, "The model reference is invalid.") }
    }
}

/// One supported way to invoke a model. A model may expose multiple independent protocols.
public struct AgentModelInvocationSpec: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let revision: Int
    public let adapter: AgentAdapterIdentity
    public let endpointID: String
    public let maximumInputTokens: Int?
    public let contextWindow: Int?
    public let maximumOutputTokens: Int?
    public let capabilities: [String: CapabilityState]
    public let configuration: AgentConfigurationValue
    public let parameterSchema: JSONValue
    public init(id: String, revision: Int, adapter: AgentAdapterIdentity, endpointID: String,
                contextWindow: Int?, maximumOutputTokens: Int?, capabilities: [String: CapabilityState],
                configuration: AgentConfigurationValue, parameterSchema: JSONValue, maximumInputTokens: Int? = nil) {
        self.id = id; self.revision = revision; self.adapter = adapter; self.endpointID = endpointID
        self.contextWindow = contextWindow; self.maximumOutputTokens = maximumOutputTokens
        self.maximumInputTokens = maximumInputTokens
        self.capabilities = capabilities; self.configuration = configuration; self.parameterSchema = parameterSchema
    }
    public func supports(_ capability: String) -> Bool {
        capabilities[capability] == .declared || capabilities[capability] == .verified
    }
    public func validate() throws {
        try adapter.validate(); try configuration.validate(); try ToolSchemaValidator.validateSchema(parameterSchema)
        guard SessionState.validIdentifier(id, maximumBytes: 128), revision > 0,
            SessionState.validIdentifier(endpointID, maximumBytes: 128),
            contextWindow.map({ (1...10_000_000).contains($0) }) ?? true,
            maximumInputTokens.map({ (1...10_000_000).contains($0) }) ?? true,
            maximumOutputTokens.map({ (1...10_000_000).contains($0) }) ?? true,
            capabilities.count <= 64,
            capabilities.keys.allSatisfy({ SessionState.validIdentifier($0, maximumBytes: 128) }),
            parameterSchema["type"] == .string("object"), try SessionCodec.encode(self).count <= 65_536 else {
            throw MiraError(.configuration, "The model invocation specification is invalid.")
        }
    }
}

/// This UUID identifies a saved configuration incarnation, not another layer of model identity.
public struct AgentConfiguredModel: Codable, Sendable, Equatable, Identifiable {
    public let id: ModelDescriptorID
    public let revision: Int
    public let authorizationRevision: Int
    public let reference: AgentModelReference
    public let displayName: String?
    public let isEnabled: Bool
    public let invocations: [AgentModelInvocationSpec]
    public let facts: [AgentModelMetadataFact]
    public var connectionID: ConnectionID { reference.connectionID }
    public var modelID: String { reference.modelID }
    /// Removal or replacement revokes earlier frozen executions, including after a later re-add.
    public func authorizationRevision(replacing previous: AgentConfiguredModel) throws -> Int {
        let revoked = isEnabled != previous.isEnabled || previous.invocations.contains { old in
            !invocations.contains { $0.id == old.id && $0.adapter == old.adapter && $0.endpointID == old.endpointID }
        }
        guard !revoked || previous.authorizationRevision < Int.max else {
            throw MiraError(.conflict, "The model authorization revision is exhausted.")
        }
        return previous.authorizationRevision + (revoked ? 1 : 0)
    }
    public init(id: ModelDescriptorID, revision: Int, authorizationRevision: Int, reference: AgentModelReference, displayName: String?,
                isEnabled: Bool, invocations: [AgentModelInvocationSpec], facts: [AgentModelMetadataFact]) {
        self.id = id; self.revision = revision; self.authorizationRevision = authorizationRevision; self.reference = reference; self.displayName = displayName
        self.isEnabled = isEnabled; self.invocations = invocations; self.facts = facts
    }
    public func validate() throws {
        try reference.validate()
        guard revision > 0, authorizationRevision > 0, authorizationRevision <= revision, displayName.map({ !$0.isEmpty && $0.utf8.count <= 512 }) ?? true,
            invocations.count <= 16, Set(invocations.map(\.id)).count == invocations.count,
            facts.count <= 256 else {
            throw MiraError(.configuration, "The configured model is invalid.")
        }
        for invocation in invocations { try invocation.validate() }
        for fact in facts { try fact.validate() }
    }
}

public enum AgentModelCapabilityID {
    public static let streamingText = "mira.streamingText"
    public static let toolCalls = "mira.toolCalls"
    public static let thinking = "mira.thinking"
    public static let jsonOutput = "mira.jsonOutput"
}

public struct AgentRoutePreset: Codable, Sendable, Equatable, Identifiable {
    public let id: RouteID
    public let revision: Int
    public let name: String
    public let modelDescriptorID: ModelDescriptorID
    public let invocationID: String
    public let maximumOutputTokens: Int
    public let configuration: AgentConfigurationValue
    public init(
        id: RouteID, revision: Int, name: String, modelDescriptorID: ModelDescriptorID, invocationID: String,
        maximumOutputTokens: Int, configuration: AgentConfigurationValue
    ) {
        self.id = id
        self.revision = revision
        self.name = name
        self.modelDescriptorID = modelDescriptorID
        self.invocationID = invocationID
        self.maximumOutputTokens = maximumOutputTokens
        self.configuration = configuration
    }
    public func validate() throws {
        try configuration.validate()
        guard revision > 0, SessionState.validIdentifier(invocationID, maximumBytes: 128), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 256,
            (1...10_000_000).contains(maximumOutputTokens)
        else {
            throw MiraError(.configuration, "The configured model route is invalid.")
        }
    }
}

/// A consistent configuration read, not permission to send workspace data.
public struct AgentModelRouteCandidate: Codable, Sendable, Equatable {
    public let connection: AgentConfiguredConnection
    public let model: AgentConfiguredModel
    public let preset: AgentRoutePreset
    public init(connection: AgentConfiguredConnection, model: AgentConfiguredModel, preset: AgentRoutePreset) {
        self.connection = connection
        self.model = model
        self.preset = preset
    }
    public var invocation: AgentModelInvocationSpec {
        get throws {
            guard let value = model.invocations.first(where: { $0.id == preset.invocationID }) else {
                throw MiraError(.configuration, "The selected model invocation is unavailable.")
            }
            return try AgentModelMetadataResolver.resolve(value, facts: model.facts)
        }
    }
    public var endpoint: AgentModelEndpoint {
        get throws { try connection.endpoint(id: invocation.endpointID) }
    }
    public func validate(requiredCapabilities: Set<String> = []) throws {
        try connection.validate(); try model.validate(); try preset.validate()
        guard requiredCapabilities.count <= 64,
            requiredCapabilities.allSatisfy({ SessionState.validIdentifier($0, maximumBytes: 128) }) else {
            throw MiraError(.configuration, "The required model capabilities are invalid.")
        }
        guard model.connectionID == connection.id, preset.modelDescriptorID == model.id else {
            throw MiraError(.configuration, "The selected model configuration identity is invalid.")
        }
        guard connection.isEnabled else { throw MiraError(.configuration, "The selected provider connection is disabled.") }
        guard model.isEnabled else { throw MiraError(.configuration, "The selected model is disabled.") }
        let spec = try invocation
        _ = try endpoint
        guard let window = spec.contextWindow else {
            throw MiraError(.configuration, "The selected model is missing its context window limit.")
        }
        guard preset.maximumOutputTokens < window,
            spec.maximumOutputTokens.map({ preset.maximumOutputTokens <= $0 }) ?? true else {
            throw MiraError(.configuration, "The selected output budget exceeds the model limits.")
        }
        guard spec.supports(AgentModelCapabilityID.streamingText) else {
            throw MiraError(.unsupported, "The selected invocation does not declare streaming text support.")
        }
        guard requiredCapabilities.allSatisfy(spec.supports) else {
            throw MiraError(.unsupported, "The selected invocation does not support the required capabilities.")
        }
    }
    /// Display, metadata and parameter edits affect future executions. Revoked configuration cannot dispatch.
    public func validateAuthorization(for route: AgentModelRoute) throws {
        try route.validate()
        guard connection.isEnabled, model.isEnabled,
            connection.id == route.connectionID, connection.configurationRevision == route.connectionRevision,
            model.id == route.modelDescriptorID, model.authorizationRevision == route.modelAuthorizationRevision,
            model.reference == AgentModelReference(connectionID: route.connectionID, modelID: route.modelID),
            preset.id == route.id, preset.modelDescriptorID == model.id,
            let spec = model.invocations.first(where: { $0.id == route.invocationID }),
            spec.adapter == route.adapter, spec.endpointID == route.endpointID,
            try connection.endpoint(id: route.endpointID).credential == route.credential else {
            throw MiraError(.unauthorized, "The frozen model route is no longer authorized.")
        }
    }

    public func freeze(configuration: JSONValue) throws -> AgentModelRoute {
        try validate()
        let spec = try invocation
        guard let window = spec.contextWindow else { throw MiraError(.configuration, "The selected model is missing its context window limit.") }
        let route = AgentModelRoute(
            id: preset.id, revision: preset.revision,
            connectionID: connection.id, connectionRevision: connection.configurationRevision,
            modelDescriptorID: model.id, modelRevision: model.revision, modelAuthorizationRevision: model.authorizationRevision, adapter: spec.adapter,
            invocationID: spec.id, invocationRevision: spec.revision, endpointID: spec.endpointID,
            modelID: model.modelID, credential: try endpoint.credential, contextWindow: window,
            maximumOutputTokens: preset.maximumOutputTokens,
            capabilities: .init(streamsText: true, callsTools: spec.supports(AgentModelCapabilityID.toolCalls),
                                producesThinking: spec.supports(AgentModelCapabilityID.thinking)),
            configuration: configuration, maximumInputTokens: spec.maximumInputTokens)
        try route.validate()
        return route
    }

}

/// Pure settings validation and assembly. Implementations neither read secrets nor perform I/O.
public protocol AgentModelConfigurationProvider: Sendable {
    var identity: AgentAdapterIdentity { get }
    /// Describes all settings the generic host needs for the selected model, including thinking controls.
    func descriptor(for invocation: AgentModelInvocationSpec) throws -> AgentModelConfigurationDescriptor
    /// Must validate protocol semantics before returning the exact non-secret frozen configuration.
    func configuration(for candidate: AgentModelRouteCandidate) throws -> JSONValue
}
