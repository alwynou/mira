import Foundation

public enum ProviderKind: String, Codable, CaseIterable, Sendable { case openAICompatible, anthropic }
public enum CapabilityState: String, Codable, Sendable { case unknown, declared, verified, failed }
public enum ModelProtocolMode: String, Codable, CaseIterable, Sendable { case standard, deepSeek, kimi, anthropicManual, anthropicAdaptive, openAI, openRouter }

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
    public var extractionCapability: CapabilityState
    public var protocolMode: ModelProtocolMode
    public var catalogMetadata: ModelCatalogMetadata?
    public var thinking: ThinkingSettings
    public init(id: RouteID = RouteID(), revision: Int = 1, name: String, providerKind: ProviderKind, baseURL: String, modelID: String, credentialReference: String, credentialVersion: Int = 1, contextWindow: Int? = nil, maxOutputTokens: Int = 1024, textCapability: CapabilityState = .declared, allowsLoopbackHTTP: Bool = false, requestsUsage: Bool = true, connectionID: ConnectionID = .init(), connectionRevision: Int = 1, modelDescriptorID: ModelDescriptorID = .init(), modelRevision: Int = 1, purpose: ModelPurpose = .conversation, selectionSource: RouteSelectionSource = .explicit, extractionCapability: CapabilityState = .unknown, protocolMode: ModelProtocolMode = .standard, catalogMetadata: ModelCatalogMetadata? = nil, thinking: ThinkingSettings = .init()) {
        self.connectionID = connectionID; self.connectionRevision = connectionRevision
        self.modelDescriptorID = modelDescriptorID; self.modelRevision = modelRevision
        self.purpose = purpose; self.selectionSource = selectionSource
        self.adapterVersion = providerKind == .anthropic ? "anthropic-messages/2" : "openai-chat-completions/3"
        self.id = id; self.revision = revision; self.name = name; self.providerKind = providerKind
        self.baseURL = baseURL; self.modelID = modelID; self.credentialReference = credentialReference
        self.credentialVersion = credentialVersion; self.contextWindow = contextWindow
        self.maxOutputTokens = maxOutputTokens; self.textCapability = textCapability
        self.allowsLoopbackHTTP = allowsLoopbackHTTP; self.requestsUsage = requestsUsage
        self.toolCapability = .unknown
        self.probeObservation = nil
        self.extractionCapability = extractionCapability
        self.protocolMode = protocolMode
        self.catalogMetadata = catalogMetadata
        self.thinking = thinking
    }

    public init(route: ModelRoute, model: ModelDescriptor, connection: ProviderConnection, purpose: ModelPurpose, selection: RouteSelectionSource) {
        self.init(id: route.id, revision: route.revision, name: route.name, providerKind: connection.providerKind,
                  baseURL: connection.baseURL, modelID: model.modelID, credentialReference: connection.credentialReference,
                  credentialVersion: connection.credentialVersion, contextWindow: model.contextWindow,
                  maxOutputTokens: route.maxOutputTokens, textCapability: model.connectionRevision == connection.revision ? model.textCapability : .unknown,
                  allowsLoopbackHTTP: connection.allowsLoopbackHTTP, requestsUsage: route.requestsUsage,
                  connectionID: connection.id, connectionRevision: connection.revision,
                  modelDescriptorID: model.id, modelRevision: model.revision, purpose: purpose, selectionSource: selection,
                  extractionCapability: model.connectionRevision == connection.revision ? model.extractionCapability : .unknown,
                  protocolMode: model.protocolMode, catalogMetadata: model.catalogMetadata, thinking: route.thinking)
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
        try validateThinkingSettings()
        if let catalogMetadata {
            try catalogMetadata.validate()
            guard catalogMetadata.task == .textGeneration || catalogMetadata.task == .unknown else {
                throw MiraError(.unsupported, "The provider catalog does not advertise a text-generation model.")
            }
            guard catalogMetadata.modelID == modelID else { throw MiraError(.configuration, "The model catalog metadata does not match the configured model ID.") }
            if !catalogMetadata.inputModalities.isEmpty {
                guard catalogMetadata.inputModalities.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "text" }) else { throw MiraError(.unsupported, "The provider catalog does not advertise text input for this model.") }
            }
            if !catalogMetadata.outputModalities.isEmpty {
                guard catalogMetadata.outputModalities.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "text" }) else { throw MiraError(.unsupported, "The provider catalog does not advertise text output for this model.") }
            }
            if let catalogLimit = catalogMetadata.maxOutputTokens {
                guard catalogLimit > 0, maxOutputTokens <= catalogLimit else { throw MiraError(.configuration, "The route output limit exceeds the provider catalog limit.") }
            }
        }
        if purpose == .memoryExtraction {
            guard extractionCapability == .declared || extractionCapability == .verified else { throw MiraError(.configuration, "Confirm that this model supports memory extraction.") }
        }
    }

    public var thinkingCapabilities: ThinkingCapabilities {
        ThinkingCapabilities(protocolMode: protocolMode, modelID: modelID)
    }

    public func validateThinkingSettings() throws {
        let anthropicMode = protocolMode == .anthropicManual || protocolMode == .anthropicAdaptive
        guard protocolMode == .standard || anthropicMode == (providerKind == .anthropic) else {
            throw MiraError(.configuration, "The thinking protocol does not match the provider interface.")
        }
        let capabilities = thinkingCapabilities
        guard capabilities.modes.contains(thinking.mode) else {
            throw MiraError(.configuration, "This model does not support the selected thinking mode.")
        }
        if let effort = thinking.effort {
            guard thinking.mode != .disabled, capabilities.efforts.contains(effort) else {
                throw MiraError(.configuration, "This model does not support the selected thinking effort.")
            }
        }
        if protocolMode == .openRouter, thinking.effort != nil, thinking.budgetTokens != nil {
            throw MiraError(.configuration, "Choose either thinking effort or a token budget.")
        }
        if let budget = thinking.budgetTokens {
            guard capabilities.supportsBudget, thinking.mode != .disabled,
                  budget >= 1024, budget < maxOutputTokens else {
                throw MiraError(.configuration, "The thinking budget must be at least 1024 tokens and smaller than maximum output tokens.")
            }
        }
        if protocolMode == .anthropicManual && thinking.mode == .enabled {
            guard (thinking.budgetTokens ?? 2048) < maxOutputTokens else {
                throw MiraError(.configuration, "Maximum output tokens must leave room for both the thinking budget and the answer.")
            }
        }
    }

    /// Opaque continuation data is never transferred to a different model,
    /// connection or endpoint. Ordinary completed answer text remains history.
    public func sharesReasoningContext(with other: Self) -> Bool {
        connectionID == other.connectionID && providerKind == other.providerKind &&
        credentialReference == other.credentialReference && credentialVersion == other.credentialVersion &&
        modelID == other.modelID && protocolMode == other.protocolMode &&
        (try? validatedEndpoint()) == (try? other.validatedEndpoint())
    }
}

public enum CanonicalRole: String, Codable, Sendable { case user, assistant, tool }
public struct CanonicalMessage: Codable, Sendable, Equatable {
    public var role: CanonicalRole
    public var text: String
    public var toolCalls: [CanonicalToolCall]?
    public var toolCallID: String?
    public var reasoning: ReasoningContent?
    public init(role: CanonicalRole, text: String, toolCalls: [CanonicalToolCall]? = nil, toolCallID: String? = nil, reasoning: ReasoningContent? = nil) {
        self.reasoning = reasoning
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
    /// A cumulative snapshot; incomplete snapshots are displayable but never replayable.
    case reasoning(ReasoningContent)
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
