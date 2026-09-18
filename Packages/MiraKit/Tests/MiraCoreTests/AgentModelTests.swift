import Foundation
import Testing
@testable import MiraCore

struct AgentModelTests {
    @Test func transcriptAcceptsOrderedPairedTools() throws {
        let route = makeRoute(adapterID: "family.alpha")
        let calls = [
            CanonicalToolCall(id: "call-1", name: "lookup", arguments: "{\"value\":1}"),
            CanonicalToolCall(id: "call-2", name: "lookup", arguments: "{\"value\":2}")
        ]
        let input = makeInput(route: route, messages: [
            message(.user, text: "Do both"),
            AgentModelMessage(role: .assistant, blocks: calls.enumerated().map {
                .init(id: "call-block-\($0.offset)", content: .toolCall($0.element))
            }),
            message(.tool, resultFor: "call-1", text: "one"),
            message(.tool, resultFor: "call-2", text: "two")
        ])
        try input.validate(for: route)
    }

    @Test func transcriptRejectsDuplicateAndOutOfOrderTools() throws {
        let route = makeRoute(adapterID: "family.alpha")
        let first = CanonicalToolCall(id: "call-1", name: "lookup", arguments: "{\"value\":1}")
        let second = CanonicalToolCall(id: "call-2", name: "lookup", arguments: "{}")
        let assistant = AgentModelMessage(role: .assistant, blocks: [
            .init(id: "one", content: .toolCall(first)), .init(id: "two", content: .toolCall(second))
        ])
        let duplicate = makeInput(route: route, messages: [message(.user, text: "x"), assistant,
            message(.tool, resultFor: "call-1", text: "x"), message(.tool, resultFor: "call-1", text: "x")])
        #expect(throws: MiraError.self) { try duplicate.validate(for: route) }
        let outOfOrder = makeInput(route: route, messages: [message(.user, text: "x"), assistant,
            message(.tool, resultFor: "call-2", text: "x"), message(.tool, resultFor: "call-1", text: "x")])
        #expect(throws: MiraError.self) { try outOfOrder.validate(for: route) }
    }

    @Test func cachedPrefixRequiresOneFinalUserAndUsesPrefixContextBoundary() throws {
        let route = makeRoute(adapterID: "family.alpha")
        let valid = AgentModelInput(stepID: UUID(), executionID: ExecutionID(), instructions: "Instructions", messages: [
            message(.context, text: "Retrieved context"), message(.user, text: "Earlier"),
            message(.assistant, text: "Earlier answer"), message(.user, text: "Current")
        ], tools: [], allowsToolCalls: false, prefixMessageCount: 3)
        try valid.validate(for: route)

        let badSuffix = AgentModelInput(stepID: valid.stepID, executionID: valid.executionID,
            instructions: valid.instructions, messages: Array(valid.messages.dropLast()) + [message(.assistant, text: "wrong")],
            tools: [], allowsToolCalls: false, prefixMessageCount: 3)
        #expect(throws: MiraError.self) { try badSuffix.validate(for: route) }

        let badContext = AgentModelInput(stepID: UUID(), executionID: ExecutionID(), instructions: "Instructions", messages: [
            message(.context, text: "Retrieved context"), message(.assistant, text: "Earlier answer"), message(.user, text: "Current")
        ], tools: [], allowsToolCalls: false, prefixMessageCount: 2)
        #expect(throws: MiraError.self) { try badContext.validate(for: route) }
    }

    @Test func perRequestOutputLimitIsBoundedByFrozenRoute() throws {
        let route = makeRoute(adapterID: "family.alpha", maximumOutputTokens: 128)
        let valid = AgentModelInput(stepID: UUID(), executionID: ExecutionID(), instructions: "Instructions",
            messages: [message(.user, text: "Hello")], tools: [], outputTokenLimit: 64)
        try valid.validate(for: route)
        let invalid = AgentModelInput(stepID: UUID(), executionID: ExecutionID(), instructions: "Instructions",
            messages: [message(.user, text: "Hello")], tools: [], outputTokenLimit: 129)
        #expect(throws: MiraError.self) { try invalid.validate(for: route) }
    }

    @Test func messageRolesAndReplayContinuationAreValidated() throws {
        let route = makeRoute(adapterID: "family.alpha")
        let adapter = route.adapter
        let complete = AgentModelContinuation(adapter: adapter, format: "family.alpha.blocks",
            payload: .object(["signed": .string("opaque")]), isComplete: true)
        let incomplete = AgentModelContinuation(adapter: adapter, format: "family.alpha.blocks",
            payload: .object(["signed": .string("opaque")]), isComplete: false)
        let valid = AgentModelMessage(role: .assistant,
            blocks: [.init(id: "answer", content: .text("answer"))], continuation: complete)
        try valid.validate(for: adapter, replay: true)
        let invalid = AgentModelMessage(role: .assistant,
            blocks: [.init(id: "answer", content: .text("answer"))], continuation: incomplete)
        #expect(throws: MiraError.self) { try invalid.validate(for: adapter, replay: true) }
        let toolWithContinuation = AgentModelMessage(role: .tool,
            blocks: [.init(id: "result", content: .toolResult(callID: "call", text: "x"))], continuation: complete)
        #expect(throws: MiraError.self) { try toolWithContinuation.validate(for: adapter, replay: false) }
    }

    @Test func arbitraryAdapterIdentitiesRemainGenericAndDistinct() throws {
        let alpha = makeRoute(adapterID: "family.alpha")
        let beta = makeRoute(adapterID: "family.beta")
        try alpha.validate(); try beta.validate()
        let adapter = FakeAdapter(identity: beta.adapter)
        let input = makeInput(route: beta)
        let prepared = try adapter.prepare(input, route: beta)
        #expect(prepared.adapter == beta.adapter)
    }

    @Test func opaqueContinuationPreservesRawJSONAndCompletion() throws {
        let adapter = AgentAdapterIdentity(id: "family.alpha", revision: 7)
        let raw = JSONValue.object(["signed": .string("opaque-value"), "nested": .array([.number(3), .bool(true), .null])])
        let complete = AgentModelContinuation(adapter: adapter, format: "family.alpha.blocks", payload: raw, isComplete: true)
        let incomplete = AgentModelContinuation(adapter: adapter, format: "family.alpha.blocks", payload: raw, isComplete: false)
        try complete.validate(); try incomplete.validate()
        let data = try SessionCodec.encode(complete)
        #expect(try SessionCodec.decode(AgentModelContinuation.self, from: data) == complete)
        let message = AgentModelMessage(role: .assistant,
            blocks: [.init(id: "answer", content: .text("private"))], continuation: complete)
        try message.validate(for: adapter, replay: true)
        #expect(throws: MiraError.self) {
            try AgentModelMessage(role: .assistant,
                blocks: [.init(id: "answer", content: .text("private"))], continuation: incomplete)
                .validate(for: adapter, replay: true)
        }
    }

    private func makeRoute(adapterID: String, contextWindow: Int = 8_192, maximumOutputTokens: Int = 1_024) -> AgentModelRoute {
        AgentModelRoute(id: RouteID(), revision: 1, connectionID: ConnectionID(), connectionRevision: 1,
            modelDescriptorID: ModelDescriptorID(), modelRevision: 1, modelAuthorizationRevision: 1,
            adapter: AgentAdapterIdentity(id: adapterID, revision: 1), invocationID: "invocation-\(adapterID)",
            invocationRevision: 1, endpointID: "endpoint-\(adapterID)", modelID: "model-1",
            credential: AgentCredentialReference(reference: "credential-ref", version: 1), contextWindow: contextWindow,
            maximumOutputTokens: maximumOutputTokens,
            capabilities: .init(streamsText: true, callsTools: true, producesThinking: true), configuration: .object(["opaque": .string("raw")]))
    }

    private func makeInput(route: AgentModelRoute, messages: [AgentModelMessage] = [message(.user, text: "Hello")]) -> AgentModelInput {
        AgentModelInput(stepID: UUID(), executionID: ExecutionID(), instructions: "Instructions", messages: messages,
            tools: [.init(name: "lookup", description: "Lookup", inputSchema: .object(["type": .string("object")]))])
    }

    private static func message(_ role: CanonicalRole, text: String) -> AgentModelMessage {
        .init(role: role, blocks: [.init(id: "text", content: .text(text))])
    }

    private func message(_ role: CanonicalRole, text: String) -> AgentModelMessage { Self.message(role, text: text) }
    private func message(_ role: CanonicalRole, resultFor callID: String, text: String) -> AgentModelMessage {
        .init(role: role, blocks: [.init(id: "result-\(callID)", content: .toolResult(callID: callID, text: text))])
    }
}

private struct FakeAdapter: AgentModelAdapter {
    let identity: AgentAdapterIdentity
    func prepare(_ input: AgentModelInput, route: AgentModelRoute) throws -> AgentPreparedModelRequest {
        try input.validate(for: route)
        return AgentPreparedModelRequest(adapter: identity, input: input, wirePayload: .object(["adapter": .string(identity.id)]), estimatedInputTokens: 1)
    }
    func stream(_ request: AgentPreparedModelRequest, route: AgentModelRoute) -> AgentModelOperation {
        .init(events: AsyncThrowingStream { continuation in continuation.finish() }, cancelAndDrain: {})
    }
    func replay(_ messages: [AgentModelMessage], from source: AgentModelRoute, to target: AgentModelRoute,
                boundary: AgentReplayBoundary) throws -> AgentReplayDecision {
        source.adapter == target.adapter ? .include(messages) : .omit
    }
}
