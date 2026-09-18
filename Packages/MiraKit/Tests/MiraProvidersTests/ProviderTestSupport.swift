import Foundation
@testable import MiraCore
@testable import MiraProviders

/// Test data selects a concrete protocol and its frozen dialect controls.
enum ProtocolFixture: String, CaseIterable, Sendable {
    case standard, deepSeek, kimi, openRouter, openAI, anthropic, responses
    var adapter: AgentAdapterIdentity {
        switch self { case .anthropic: return HTTPAdapterIdentity.anthropicMessages; case .responses: return HTTPAdapterIdentity.responses; default: return HTTPAdapterIdentity.chatCompletions }
    }
    var identity: AgentAdapterIdentity { adapter }
    var protocolID: HTTPProtocolID {
        switch self { case .anthropic: return .anthropicMessages; case .responses: return .responses; default: return .chatCompletions }
    }
    var dialect: HTTPDialectProfileID {
        switch self { case .standard: return .generic; case .deepSeek: return .deepSeek; case .kimi: return .kimi; case .openRouter: return .openRouter; case .openAI, .responses: return .openAI; case .anthropic: return .anthropic }
    }
    var isAnthropic: Bool { self == .anthropic }
}

extension HTTPModelAdapter {
    init(fixture: ProtocolFixture, credentials: any CredentialReader,
                     transport: any HTTPStreamingTransport = URLSessionStreamingTransport(),
                     now: @escaping @Sendable () -> Date = Date.init) {
        try! self.init(dialect: fixture.dialect, protocolID: fixture.protocolID,
                       credentials: credentials, transport: transport, now: now)
    }
}

extension HTTPModelConfigurationProvider {
    init(fixture: ProtocolFixture) {
        self.init(adapter: fixture.adapter, protocolID: fixture.protocolID, dialectProfileID: fixture.dialect)
    }
    func descriptor(modelID: String) throws -> AgentModelConfigurationDescriptor {
        let settings = HTTPInvocationSettings(protocolID: fixtureProtocol, dialectProfileID: fixtureDialect)
        let modes: [String] = identity == HTTPAdapterIdentity.chatCompletions && fixtureDialect == .generic
            ? ["providerDefault"] : ["providerDefault", "enabled", "disabled"]
        var thinkingProperties: [String: JSONValue] = [
            "mode": .object(["type": .string("string"), "enum": .array(modes.map(JSONValue.string))])
        ]
        if fixtureDialect != .generic {
            thinkingProperties["effort"] = .object(["type": .string("string"), "enum": .array(["low", "medium", "high", "xhigh", "max"].map(JSONValue.string))])
        }
        if fixtureDialect == .openRouter || fixtureDialect == .anthropic {
            thinkingProperties["budgetTokens"] = .object(["type": .string("integer"), "minimum": .number(1_024)])
        }
        let schema = JSONValue.object(["type": .string("object"), "properties": .object([
            "thinking": .object(["type": .string("object"), "properties": .object(thinkingProperties)])
        ]), "additionalProperties": .bool(false)])
        let invocation = AgentModelInvocationSpec(id: "fixture", revision: 1, adapter: identity, endpointID: "primary",
            contextWindow: 8_192, maximumOutputTokens: 1_024,
            capabilities: [AgentModelCapabilityID.streamingText: .declared],
            configuration: .init(schema: .init(id: "mira.http.invocation", revision: 2), value: try! SessionCodec.decode(JSONValue.self, from: SessionCodec.encode(settings))),
            parameterSchema: schema)
        return try descriptor(for: invocation)
    }
    private var fixtureProtocol: HTTPProtocolID { identity == HTTPAdapterIdentity.anthropicMessages ? .anthropicMessages : (identity == HTTPAdapterIdentity.responses ? .responses : .chatCompletions) }
    private var fixtureDialect: HTTPDialectProfileID { defaultDialect }
}

extension AgentModelMessage {
    init(role: CanonicalRole, text: String, toolCalls: [CanonicalToolCall] = [], toolCallID: String? = nil,
         thinking: ThinkingSnapshot? = nil) {
        var blocks: [AgentModelBlock] = text.isEmpty ? [.init(id: "text", content: .text(""))] : [.init(id: "text", content: .text(text))]
        if text.isEmpty { blocks.removeAll() }
        blocks += toolCalls.map { .init(id: $0.id, content: .toolCall($0)) }
        if let thinking { blocks.insert(.init(id: "thinking", content: .thinking(thinking.text)), at: 0) }
        if let toolCallID { blocks = [.init(id: "tool-result", content: .toolResult(callID: toolCallID, text: text))] }
        self.init(role: role, blocks: blocks, continuation: thinking?.continuation)
    }
}

struct ThinkingSnapshot: Sendable, Equatable {
    var text: String
    var continuation: AgentModelContinuation?
    var isComplete: Bool
}

func thinkingSnapshots(_ events: [AgentModelStreamEvent]) -> [ThinkingSnapshot] {
    var text = ""
    var thinkingID: String?
    var continuation: AgentModelContinuation?
    var complete = false
    var result: [ThinkingSnapshot] = []
    for event in events {
        switch event {
        case .blockStarted(let block):
            if case .thinking(let value) = block.content {
                thinkingID = block.id
                text = value
                complete = false
            }
        case .blockDelta(let id, let value):
            if id == thinkingID { text += value }
        case .continuation(let value):
            continuation = value
            if !result.isEmpty {
                result[result.count - 1].continuation = value
                result[result.count - 1].isComplete = value.isComplete
            }
        case .blockFinished(let id):
            if id == thinkingID {
                complete = continuation?.isComplete ?? true
                result.append(.init(text: text, continuation: continuation, isComplete: complete))
                thinkingID = nil
            }
        default: break
        }
    }
    return result
}

extension AgentModelRoute {
    init(id: RouteID, revision: Int, connectionID: ConnectionID, connectionRevision: Int,
         modelDescriptorID: ModelDescriptorID, modelRevision: Int, adapter: AgentAdapterIdentity,
         modelID: String, credential: AgentCredentialReference?, contextWindow: Int,
         maximumOutputTokens: Int, capabilities: AgentModelCapabilities, configuration: JSONValue) {
        self.init(id: id, revision: revision, connectionID: connectionID, connectionRevision: connectionRevision,
                  modelDescriptorID: modelDescriptorID, modelRevision: modelRevision, modelAuthorizationRevision: modelRevision,
                  adapter: adapter, invocationID: "fixture", invocationRevision: 1, endpointID: "primary",
                  modelID: modelID, credential: credential, contextWindow: contextWindow, maximumOutputTokens: maximumOutputTokens,
                  capabilities: capabilities, configuration: configuration)
    }
}

extension AgentConfiguredConnection {
    var credential: AgentCredentialReference? { endpoints.first?.credential }
    var configuration: AgentConfigurationValue { endpoints[0].configuration }
    init(id: ConnectionID, revision: Int, configurationRevision: Int, name: String, isEnabled: Bool,
         credential: AgentCredentialReference?, configuration: AgentConfigurationValue,
         discovery: AgentConnectionDiscovery? = nil) {
        self.init(id: id, revision: revision, configurationRevision: configurationRevision, name: name, isEnabled: isEnabled,
                  definitionID: nil, endpoints: [.init(id: "primary", configuration: configuration, credential: credential)],
                  discovery: discovery, defaultInvocation: nil)
    }
}

extension HTTPModelConfiguration {
    func validatedEndpoint(fixture: ProtocolFixture) throws -> URL {
        let configured = HTTPModelConfiguration(baseURL: baseURL, allowsLoopbackHTTP: allowsLoopbackHTTP,
            protocolID: fixture.protocolID, dialectProfileID: fixture.dialect, requestsUsage: requestsUsage,
            thinking: thinking, pricing: pricing, storeResponses: storeResponses)
        return try configured.validatedEndpoint()
    }
}

extension AgentConfiguredModel {
    init(id: ModelDescriptorID, revision: Int, connectionID: ConnectionID, connectionConfigurationRevision: Int,
         adapter: AgentAdapterIdentity, modelID: String, isEnabled: Bool, contextWindow: Int,
         capabilities: [String: CapabilityState], dialect explicitDialect: HTTPDialectProfileID? = nil) {
        let schema = AgentConfigurationIdentity(id: "mira.http.invocation", revision: 2)
        let dialect: String
        if let explicitDialect { dialect = explicitDialect.rawValue }
        else if adapter == HTTPAdapterIdentity.anthropicMessages { dialect = HTTPDialectProfileID.anthropic.rawValue }
        else if adapter == HTTPAdapterIdentity.responses { dialect = HTTPDialectProfileID.openAI.rawValue }
        else if modelID.lowercased().contains("deepseek") { dialect = HTTPDialectProfileID.deepSeek.rawValue }
        else if modelID.lowercased().contains("kimi") { dialect = HTTPDialectProfileID.kimi.rawValue }
        else if modelID == "openrouter-model" { dialect = HTTPDialectProfileID.openRouter.rawValue }
        else if modelID == "model" { dialect = HTTPDialectProfileID.generic.rawValue }
        else { dialect = HTTPDialectProfileID.openAI.rawValue }
        let configuration = AgentConfigurationValue(schema: schema, value: .object([
            "protocolID": .string(adapter == HTTPAdapterIdentity.anthropicMessages ? "anthropic.messages" : adapter == HTTPAdapterIdentity.responses ? "openai.responses" : "chat.completions"),
            "dialectProfileID": .string(dialect),
            "requestsUsage": .bool(true), "thinking": .object(["mode": .string("providerDefault")]), "storeResponses": .bool(false)
        ]))
        let parameterSchema: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "thinking": .object(["type": .string("object"), "properties": .object([
                    "mode": .object(["type": .string("string")]),
                    "effort": .object(["type": .string("string")]),
                    "budgetTokens": .object(["type": .string("integer")])
                ]), "required": .array([]), "additionalProperties": .bool(false)])
            ]),
            "required": .array([]),
            "additionalProperties": .bool(false)
        ])
        let invocation = AgentModelInvocationSpec(id: "default", revision: 1, adapter: adapter, endpointID: "primary",
            contextWindow: contextWindow, maximumOutputTokens: contextWindow - 1, capabilities: capabilities,
            configuration: configuration,
            parameterSchema: parameterSchema)
        self.init(id: id, revision: revision, authorizationRevision: 1,
                  reference: .init(connectionID: connectionID, modelID: modelID), displayName: nil,
                  isEnabled: isEnabled, invocations: [invocation], facts: [])
    }
}

extension AgentRoutePreset {
    init(id: RouteID, revision: Int, name: String, modelDescriptorID: ModelDescriptorID,
         maximumOutputTokens: Int, configuration: AgentConfigurationValue) {
        self.init(id: id, revision: revision, name: name, modelDescriptorID: modelDescriptorID,
                  invocationID: "default", maximumOutputTokens: maximumOutputTokens, configuration: configuration)
    }
}

extension HTTPModelPolicy {
    init(route: AgentModelRoute, fixture: ProtocolFixture) throws {
        try self.init(route: route, kind: try HTTPInvocationKind(protocolID: fixture.protocolID, dialectProfileID: fixture.dialect))
    }
}

extension HTTPThinkingCapabilities {
    init(fixture: ProtocolFixture, modelID: String) {
        switch fixture {
        case .standard: self.init(modes: [.providerDefault])
        case .anthropic: self.init(modes: [.providerDefault, .enabled, .disabled, .adaptive], efforts: [.low, .medium, .high, .max], supportsBudget: true)
        case .deepSeek, .kimi: self.init(efforts: [.low, .high, .max])
        case .openRouter: self.init(efforts: [.low, .medium, .high, .max], supportsBudget: true)
        case .openAI, .responses: self.init(efforts: [.low, .medium, .high])
        }
    }
}

extension AgentModelInput {
    static func fixture(messages: [AgentModelMessage] = [.init(role: .user, text: "Hello")], tools: [ToolDefinition] = []) -> Self {
        .init(stepID: UUID(), executionID: ExecutionID(), instructions: "Fixture", messages: messages, tools: tools)
    }
}

func isToolCallEvent(_ event: AgentModelStreamEvent) -> Bool {
    if case .blockStarted(let block) = event, case .toolCall = block.content { return true }
    return false
}

func containsToolCall(
    _ events: [AgentModelStreamEvent],
    id: String,
    name: String,
    arguments: String
) -> Bool {
    events.contains { event in
        guard case .blockStarted(let block) = event,
              case .toolCall(let call) = block.content else { return false }
        return call == CanonicalToolCall(id: id, name: name, arguments: arguments)
    }
}

func textDeltas(_ events: [AgentModelStreamEvent]) -> [String] {
    events.compactMap { event in
        guard case .blockDelta(_, let text) = event else { return nil }
        return text
    }
}
