import Foundation
import Testing
import MiraCore
@testable import MiraProviders

private final class ThinkingCredentials: CredentialReader, @unchecked Sendable {
    func read(reference: String, version: Int) throws -> String { "fixture-secret" }
}

private final class ThinkingTransport: HTTPStreamingTransport, @unchecked Sendable {
    private let responseBytes: Data
    private let lock = NSLock()
    private(set) var requests: [URLRequest] = []

    init(responseBytes: Data) { self.responseBytes = responseBytes }

    func stream(request: URLRequest) -> AsyncThrowingStream<HTTPTransportEvent, any Error> {
        lock.lock(); requests.append(request); lock.unlock()
        return AsyncThrowingStream { continuation in
            continuation.yield(.response(HTTPTransportResponse(statusCode: 200)))
            continuation.yield(.bytes(responseBytes))
            continuation.yield(.end)
            continuation.finish()
        }
    }
}

private func sse(_ frames: [(String, String)]) -> Data {
    Data(frames.map { event, data in
        "\(event.isEmpty ? "" : "event: \(event)\n")data: \(data)\n\n"
    }.joined().utf8)
}

private func openAIStopStream() -> Data {
    sse([
        ("", #"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#),
        ("", "[DONE]")
    ])
}

private func anthropicStopStream() -> Data {
    sse([
        ("message_start", #"{"type":"message_start","message":{"usage":{}}}"#),
        ("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#),
        ("content_block_stop", #"{"type":"content_block_stop","index":0}"#),
        ("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#),
        ("message_stop", #"{"type":"message_stop"}"#)
    ])
}

private func openAIRoute(
    modelID: String = "fixture-model",
    protocolMode: ModelProtocolMode = .standard,
    thinking: ThinkingSettings = .init()
) -> ResolvedModelRouteSnapshot {
    var route = ResolvedModelRouteSnapshot(
        name: "Fixture", providerKind: .openAICompatible, baseURL: "https://fixture.test/v1",
        modelID: modelID, credentialReference: "fixture", contextWindow: 100_000,
        maxOutputTokens: 2_048, protocolMode: protocolMode, thinking: thinking
    )
    route.toolCapability = .declared
    return route
}

private func anthropicRoute(
    modelID: String = "claude-sonnet-4-5",
    protocolMode: ModelProtocolMode = .anthropicManual,
    thinking: ThinkingSettings = .init()
) -> ResolvedModelRouteSnapshot {
    var route = ResolvedModelRouteSnapshot(
        name: "Fixture", providerKind: .anthropic, baseURL: "https://fixture.test/v1",
        modelID: modelID, credentialReference: "fixture", contextWindow: 200_000,
        maxOutputTokens: 4_096, protocolMode: protocolMode, thinking: thinking
    )
    route.toolCapability = .declared
    return route
}

private func request(
    messages: [CanonicalMessage] = [CanonicalMessage(role: .user, text: "Hello")],
    tools: [ToolDefinition]? = nil
) -> CanonicalModelRequest {
    CanonicalModelRequest(executionID: ExecutionID(), system: "System", messages: messages, tools: tools)
}

private func bodyObject(_ transport: ThinkingTransport) throws -> [String: Any] {
    let body = try #require(transport.requests.first?.httpBody)
    return try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
}

@Test("Anthropic preserves multiple signed and redacted thinking blocks for exact replay")
func anthropicOrderedThinkingReplay() async throws {
    let response = sse([
        ("message_start", #"{"type":"message_start","message":{"usage":{}}}"#),
        ("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#),
        ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"first"}}"#),
        ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig-a"}}"#),
        ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"-one"}}"#),
        ("content_block_stop", #"{"type":"content_block_stop","index":0}"#),
        ("content_block_start", #"{"type":"content_block_start","index":1,"content_block":{"type":"thinking","thinking":""}}"#),
        ("content_block_delta", #"{"type":"content_block_delta","index":1,"delta":{"type":"thinking_delta","thinking":"second"}}"#),
        ("content_block_delta", #"{"type":"content_block_delta","index":1,"delta":{"type":"signature_delta","signature":"sig-b"}}"#),
        ("content_block_delta", #"{"type":"content_block_delta","index":1,"delta":{"type":"signature_delta","signature":"-two"}}"#),
        ("content_block_stop", #"{"type":"content_block_stop","index":1}"#),
        ("content_block_start", #"{"type":"content_block_start","index":2,"content_block":{"type":"redacted_thinking","data":"opaque-redacted"}}"#),
        ("content_block_stop", #"{"type":"content_block_stop","index":2}"#),
        ("content_block_start", #"{"type":"content_block_start","index":3,"content_block":{"type":"text","text":"answer"}}"#),
        ("content_block_stop", #"{"type":"content_block_stop","index":3}"#),
        ("content_block_start", #"{"type":"content_block_start","index":4,"content_block":{"type":"tool_use","id":"call-1","name":"memory_search","input":{}}}"#),
        ("content_block_stop", #"{"type":"content_block_stop","index":4}"#),
        ("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"tool_use"}}"#),
        ("message_stop", #"{"type":"message_stop"}"#)
    ])
    let transport = ThinkingTransport(responseBytes: response)
    let provider = HTTPModelProvider(credentials: ThinkingCredentials(), transport: transport)
    let tools = [ToolDefinition(name: "memory.search", description: "Search", inputSchema: .object([:]))]
    var events: [CanonicalStreamEvent] = []
    for try await event in provider.stream(request: request(tools: tools), route: anthropicRoute(thinking: ThinkingSettings(mode: .enabled, budgetTokens: 2_048))) {
        events.append(event)
    }
    let reasoning = try #require(events.compactMap { event -> ReasoningContent? in
        guard case .reasoning(let value) = event else { return nil }
        return value
    }.last)
    #expect(reasoning.isComplete)
    #expect(reasoning.blocks.count == 5)
    #expect(reasoning.blocks[0]["thinking"]?.stringValue == "first")
    #expect(reasoning.blocks[0]["signature"]?.stringValue == "sig-a-one")
    #expect(reasoning.blocks[1]["thinking"]?.stringValue == "second")
    #expect(reasoning.blocks[1]["signature"]?.stringValue == "sig-b-two")
    #expect(reasoning.blocks[2]["data"]?.stringValue == "opaque-redacted")
    #expect(reasoning.blocks[3]["text"]?.stringValue == "answer")
    #expect(reasoning.blocks[4]["id"]?.stringValue == "call-1")
    #expect(events.contains(.toolCalls([CanonicalToolCall(id: "call-1", name: "memory.search", arguments: "{}")])) )

    let assistant = CanonicalMessage(
        role: .assistant, text: "answer",
        toolCalls: [CanonicalToolCall(id: "call-1", name: "memory.search", arguments: "{}")],
        reasoning: reasoning
    )
    let replayTransport = ThinkingTransport(responseBytes: response)
    let replayProvider = HTTPModelProvider(credentials: ThinkingCredentials(), transport: replayTransport)
    for try await _ in replayProvider.stream(
        request: request(messages: [assistant, .init(role: .tool, text: "Synthetic result", toolCallID: "call-1")], tools: tools),
        route: anthropicRoute(thinking: ThinkingSettings(mode: .enabled, budgetTokens: 2_048))
    ) {}
    let replay = try bodyObject(replayTransport)
    let messages = try #require(replay["messages"] as? [[String: Any]])
    let content = try #require(messages.first?["content"] as? [[String: Any]])
    #expect(content.map { $0["type"] as? String } == ["thinking", "thinking", "redacted_thinking", "text", "tool_use"])
    #expect(content[0]["thinking"] as? String == "first")
    #expect(content[1]["thinking"] as? String == "second")
    #expect(content[0]["signature"] as? String == "sig-a-one")
    #expect(content[1]["signature"] as? String == "sig-b-two")
    #expect(content[2]["data"] as? String == "opaque-redacted")
}

@Test("Anthropic rejects incomplete thinking before exposing tool calls", arguments: [false, true])
func anthropicIncompleteThinkingBeforeToolCalls(redacted: Bool) async throws {
    let incompleteBlock = redacted ? #"{"type":"redacted_thinking"}"# : #"{"type":"thinking","thinking":"plan"}"#
    let response = sse([
        ("message_start", #"{"type":"message_start","message":{"usage":{}}}"#),
        ("content_block_start", "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":" + incompleteBlock + "}"),
        ("content_block_stop", #"{"type":"content_block_stop","index":0}"#),
        ("content_block_start", #"{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"call-1","name":"memory_search","input":{}}}"#),
        ("content_block_stop", #"{"type":"content_block_stop","index":1}"#),
        ("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"tool_use"}}"#),
        ("message_stop", #"{"type":"message_stop"}"#)
    ])
    let transport = ThinkingTransport(responseBytes: response)
    let provider = HTTPModelProvider(credentials: ThinkingCredentials(), transport: transport)
    let tools = [ToolDefinition(name: "memory.search", description: "Search", inputSchema: .object([:]))]
    var sawToolCalls = false
    var failure: (any Error)?
    do {
        for try await event in provider.stream(
            request: request(tools: tools),
            route: anthropicRoute(thinking: ThinkingSettings(mode: .enabled, budgetTokens: 2_048))
        ) {
            if case .toolCalls = event { sawToolCalls = true }
        }
    } catch {
        failure = error
    }
    #expect(sawToolCalls == false)
    #expect(failure is MiraError)
    #expect((failure as? MiraError)?.code == .malformedStream)
}

@Test("OpenRouter keeps 600 reasoning details ordered, deduplicates visible aliases, and stays bounded")
func openRouterLargeReasoningDetails() async throws {
    var frames: [(String, String)] = []
    for index in 0..<600 {
        let fragment: JSONValue
        switch index % 3 {
        case 0:
            fragment = .object(["type": .string("reasoning.text"), "id": .string("repeat"), "text": .string("visible")])
        case 1:
            fragment = .object(["type": .string("reasoning.summary"), "id": .string("repeat"), "summary": .string("summary")])
        default:
            fragment = .object(["type": .string("reasoning.encrypted"), "id": .string("repeat"), "data": .string("opaque")])
        }
        var delta: [String: JSONValue] = ["reasoning_details": .array([fragment])]
        if index == 0 { delta["reasoning_content"] = .string("visible") }
        let envelope = JSONValue.object(["choices": .array([.object(["delta": .object(delta)])])])
        frames.append(("", try envelope.jsonString()))
    }
    frames.append(("", #"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#))
    frames.append(("", "[DONE]"))
    let transport = ThinkingTransport(responseBytes: sse(frames))
    let provider = HTTPModelProvider(credentials: ThinkingCredentials(), transport: transport)
    var events: [CanonicalStreamEvent] = []
    for try await event in provider.stream(request: request(), route: openAIRoute(modelID: "openrouter/fixture", protocolMode: .openRouter)) {
        events.append(event)
    }
    let snapshots = events.compactMap { event -> ReasoningContent? in
        guard case .reasoning(let value) = event else { return nil }
        return value
    }
    let complete = try #require(snapshots.last)
    #expect(snapshots.count < 128)
    #expect(complete.isComplete)
    #expect(complete.blocks.count == 600)
    #expect(complete.blocks.first?["id"]?.stringValue == "repeat")
    #expect(complete.blocks.last?["type"]?.stringValue == "reasoning.encrypted")
    #expect(complete.text.components(separatedBy: "visible").count - 1 == 200)
    #expect(complete.text.components(separatedBy: "summary").count - 1 == 200)
}

@Test("Partial OpenAI reasoning is emitted as incomplete before premature EOF")
func partialReasoningPrematureEOF() async throws {
    let transport = ThinkingTransport(responseBytes: sse([
        ("", #"{"choices":[{"delta":{"reasoning_content":"partial"}}]}"#)
    ]))
    let provider = HTTPModelProvider(credentials: ThinkingCredentials(), transport: transport)
    var events: [CanonicalStreamEvent] = []
    var failure: (any Error)?
    do {
        for try await event in provider.stream(request: request(), route: openAIRoute()) { events.append(event) }
    } catch {
        failure = error
    }
    let reasoning = try #require(events.compactMap { event -> ReasoningContent? in
        guard case .reasoning(let value) = event else { return nil }
        return value
    }.first)
    #expect(reasoning.text == "partial")
    #expect(reasoning.isComplete == false)
    #expect(events.contains { if case .finished = $0 { true } else { false } } == false)
    #expect((failure as? MiraError)?.code == .interrupted)
}

@Test("Thinking payload table preserves provider defaults and explicit controls")
func thinkingPayloadTable() async throws {
    struct Case {
        let route: ResolvedModelRouteSnapshot
        let anthropic: Bool
        let check: ([String: Any]) -> Bool
    }
    let cases: [Case] = [
        Case(route: openAIRoute(modelID: "deepseek-v4-pro", protocolMode: .deepSeek), anthropic: false, check: { body in body["thinking"] == nil && body["reasoning_effort"] == nil }),
        Case(route: openAIRoute(modelID: "deepseek-v4-pro", protocolMode: .deepSeek, thinking: ThinkingSettings(mode: .enabled, effort: .high)), anthropic: false, check: { body in (body["thinking"] as? [String: String]) == ["type": "enabled"] && body["reasoning_effort"] as? String == "high" }),
        Case(route: openAIRoute(modelID: "kimi-k3", protocolMode: .kimi, thinking: ThinkingSettings(mode: .providerDefault, effort: .max)), anthropic: false, check: { body in body["thinking"] == nil && body["reasoning_effort"] as? String == "max" && body["max_completion_tokens"] as? Int == 2_048 && body["max_tokens"] == nil }),
        Case(route: openAIRoute(modelID: "kimi-k2.6", protocolMode: .kimi, thinking: ThinkingSettings(mode: .enabled)), anthropic: false, check: { body in (body["thinking"] as? [String: String]) == ["type": "enabled", "keep": "all"] }),
        Case(route: openAIRoute(modelID: "gpt-5.1", protocolMode: .openAI), anthropic: false, check: { body in body["reasoning_effort"] == nil && body["max_completion_tokens"] as? Int == 2_048 && body["max_tokens"] == nil }),
        Case(route: openAIRoute(modelID: "gpt-5.1", protocolMode: .openAI, thinking: ThinkingSettings(mode: .providerDefault, effort: .high)), anthropic: false, check: { body in body["reasoning_effort"] as? String == "high" }),
        Case(route: anthropicRoute(thinking: ThinkingSettings(mode: .disabled)), anthropic: true, check: { body in (body["thinking"] as? [String: String]) == ["type": "disabled"] }),
        Case(route: anthropicRoute(thinking: ThinkingSettings(mode: .providerDefault, budgetTokens: 2_048)), anthropic: true, check: { body in (body["thinking"] as? [String: Any])?["type"] as? String == "enabled" && (body["thinking"] as? [String: Any])?["budget_tokens"] as? Int == 2_048 }),
        Case(route: anthropicRoute(modelID: "claude-sonnet-4-6", protocolMode: .anthropicAdaptive, thinking: ThinkingSettings(mode: .providerDefault, effort: .high)), anthropic: true, check: { body in (body["thinking"] as? [String: String]) == ["type": "adaptive"] && (body["output_config"] as? [String: String]) == ["effort": "high"] })
    ]
    for testCase in cases {
        let transport = ThinkingTransport(responseBytes: testCase.anthropic ? anthropicStopStream() : openAIStopStream())
        let provider = HTTPModelProvider(credentials: ThinkingCredentials(), transport: transport)
        for try await _ in provider.stream(request: request(), route: testCase.route) {}
        #expect(testCase.check(try bodyObject(transport)))
    }
}

@Test("Conflicting OpenRouter controls fail before dispatch")
func conflictingOpenRouterControls() async throws {
    let transport = ThinkingTransport(responseBytes: openAIStopStream())
    let provider = HTTPModelProvider(credentials: ThinkingCredentials(), transport: transport)
    let route = openAIRoute(protocolMode: .openRouter, thinking: .init(mode: .enabled, effort: .high, budgetTokens: 1024))
    await #expect(throws: MiraError.self) {
        for try await _ in provider.stream(request: request(), route: route) {}
    }
    #expect(transport.requests.isEmpty)
}
