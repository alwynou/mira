import Foundation

public enum ProviderKind: String, Codable, CaseIterable, Sendable { case openAICompatible, anthropic }
public enum CapabilityState: String, Codable, Sendable { case unknown, declared, verified, failed }

/// Non-secret configuration. A copy is frozen in each execution before context construction.
public struct ResolvedModelRouteSnapshot: Identifiable, Codable, Sendable, Equatable {
    public var id: RouteID
    public var connectionID: ConnectionID
    public var connectionRevision: Int
    public var modelDescriptorID: ModelDescriptorID
    public var modelRevision: Int
    public var purpose: ModelPurpose
    public var selectionSource: RouteSelectionSource
    public var adapterVersion: String
    public var revision: Int
    public var name: String
    public var providerKind: ProviderKind
    public var baseURL: String
    public var modelID: String
    public var credentialReference: String
    public var credentialVersion: Int
    public var contextWindow: Int?
    public var maxOutputTokens: Int
    public var textCapability: CapabilityState
    public var allowsLoopbackHTTP: Bool
    public var requestsUsage: Bool
    /// Tools are exposed only after explicit declaration or a successful probe.
    public var toolCapability: CapabilityState
    /// Last explicit capability probe result; absent until the first probe.
    public var probeObservation: ProbeObservation?
    public init(id: RouteID = RouteID(), revision: Int = 1, name: String, providerKind: ProviderKind, baseURL: String, modelID: String, credentialReference: String, credentialVersion: Int = 1, contextWindow: Int? = nil, maxOutputTokens: Int = 1024, textCapability: CapabilityState = .declared, allowsLoopbackHTTP: Bool = false, requestsUsage: Bool = true, connectionID: ConnectionID = .init(), connectionRevision: Int = 1, modelDescriptorID: ModelDescriptorID = .init(), modelRevision: Int = 1, purpose: ModelPurpose = .conversation, selectionSource: RouteSelectionSource = .explicit) {
        self.connectionID = connectionID; self.connectionRevision = connectionRevision
        self.modelDescriptorID = modelDescriptorID; self.modelRevision = modelRevision
        self.purpose = purpose; self.selectionSource = selectionSource
        self.adapterVersion = providerKind == .anthropic ? "anthropic-messages/1" : "openai-chat-completions/1"
        self.id = id; self.revision = revision; self.name = name; self.providerKind = providerKind
        self.baseURL = baseURL; self.modelID = modelID; self.credentialReference = credentialReference
        self.credentialVersion = credentialVersion; self.contextWindow = contextWindow
        self.maxOutputTokens = maxOutputTokens; self.textCapability = textCapability
        self.allowsLoopbackHTTP = allowsLoopbackHTTP; self.requestsUsage = requestsUsage
        self.toolCapability = .unknown
        self.probeObservation = nil
    }

    public init(route: ModelRoute, model: ModelDescriptor, connection: ProviderConnection, purpose: ModelPurpose, selection: RouteSelectionSource) {
        self.init(id: route.id, revision: route.revision, name: route.name, providerKind: connection.providerKind,
                  baseURL: connection.baseURL, modelID: model.modelID, credentialReference: connection.credentialReference,
                  credentialVersion: connection.credentialVersion, contextWindow: model.contextWindow,
                  maxOutputTokens: route.maxOutputTokens, textCapability: model.connectionRevision == connection.revision ? model.textCapability : .unknown,
                  allowsLoopbackHTTP: connection.allowsLoopbackHTTP, requestsUsage: route.requestsUsage,
                  connectionID: connection.id, connectionRevision: connection.revision,
                  modelDescriptorID: model.id, modelRevision: model.revision, purpose: purpose, selectionSource: selection)
        self.toolCapability = model.connectionRevision == connection.revision ? model.toolCapability : .unknown
        self.probeObservation = model.connectionRevision == connection.revision ? model.probeObservation : nil
    }

    public func validatedEndpoint() throws -> URL {
        try ProviderEndpoint.resolve(kind: providerKind, baseURL: baseURL, allowsLoopbackHTTP: allowsLoopbackHTTP)
    }

    public var origin: String {
        guard let endpoint = URLComponents(string: baseURL) else { return "" }
        var origin = URLComponents()
        origin.scheme = endpoint.scheme; origin.host = endpoint.host; origin.port = endpoint.port
        return origin.url?.absoluteString ?? ""
    }

    public func validateForSending() throws {
        _ = try validatedEndpoint()
        guard !credentialReference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, credentialVersion > 0 else {
            throw MiraError(.configuration, "The provider credential reference is invalid.")
        }
        guard !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MiraError(.configuration, "Enter a Model ID.") }
        guard let window = contextWindow, window > 0, window <= 10_000_000,
              maxOutputTokens > 0, maxOutputTokens < window else { throw MiraError(.configuration, "Configure a valid context window and maximum output token count.") }
        guard textCapability == .declared || textCapability == .verified else { throw MiraError(.configuration, "Confirm that this model supports streaming text conversations.") }
    }
}

public enum CanonicalRole: String, Codable, Sendable { case user, assistant, tool }
public struct CanonicalMessage: Codable, Sendable, Equatable {
    public var role: CanonicalRole
    public var text: String
    public var toolCalls: [CanonicalToolCall]?
    public var toolCallID: String?
    public init(role: CanonicalRole, text: String, toolCalls: [CanonicalToolCall]? = nil, toolCallID: String? = nil) {
        self.role = role; self.text = text; self.toolCalls = toolCalls; self.toolCallID = toolCallID
    }
}
public struct CanonicalModelRequest: Codable, Sendable, Equatable {
    public var executionID: ExecutionID
    public var system: String
    public var messages: [CanonicalMessage]
    public var requestID: UUID?
    public var tools: [ToolDefinition]?
    public var contextInfo: RequestContextInfo?
    public var dispatchID: UUID { requestID ?? executionID.rawValue }
    public init(executionID: ExecutionID, system: String, messages: [CanonicalMessage], requestID: UUID? = nil, tools: [ToolDefinition]? = nil) {
        self.executionID = executionID; self.system = system; self.messages = messages
        self.requestID = requestID; self.tools = tools
    }
}
public enum StreamFinishReason: String, Codable, Sendable { case stop, outputLimit, toolCalls }
public enum CanonicalStreamEvent: Sendable, Equatable {
    case textDelta(String)
    /// One ordered, completely assembled batch. Never execute partial JSON from a stream.
    case toolCalls([CanonicalToolCall])
    case usage(TokenUsage)
    case finished(StreamFinishReason)
}

public protocol CredentialReader: Sendable {
    /// Read at dispatch time. Implementations must enforce reference/version identity.
    func read(reference: String, version: Int) throws -> String
}
public protocol ModelProviderPort: Sendable {
    /// The consumer task cancellation must cancel its URLSession task. EOF without a protocol terminal event is an error.
    func stream(request: CanonicalModelRequest, route: ResolvedModelRouteSnapshot) -> AsyncThrowingStream<CanonicalStreamEvent, any Error>
}
