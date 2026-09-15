import Foundation
import Testing
import MiraCore
@testable import MiraProviders

private final class ThinkingCredentials: CredentialReader, @unchecked Sendable {
    private(set) var reads = 0
    func read(reference: String, version: Int) throws -> String {
        reads += 1
        return "fixture-secret"
    }
}

private final class ThinkingTransport: HTTPStreamingTransport, @unchecked Sendable {
    private let responseBytes: Data
    private let lock = NSLock()
    private(set) var requests: [URLRequest] = []

    init(responseBytes: Data) { self.responseBytes = responseBytes }

    func stream(request: URLRequest) -> HTTPTransportOperation {
        lock.lock()
        requests.append(request)
        lock.unlock()
        let events = AsyncThrowingStream<HTTPTransportEvent, any Error> { continuation in
            continuation.yield(.response(HTTPTransportResponse(statusCode: 200)))
            continuation.yield(.bytes(responseBytes))
            continuation.yield(.end)
            continuation.finish()
        }
        return HTTPTransportOperation(events: events, cancelAndDrain: {})
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

private func route(
    fixture: ProtocolFixture,
    modelID: String = "fixture-model",
    thinking: ThinkingSettings = .init(),
    contextWindow: Int = 100_000,
    maximumOutputTokens: Int = 2_048
) throws -> AgentModelRoute {
    let configuration = HTTPModelConfiguration(
        baseURL: "https://fixture.test/v1", protocolID: fixture.protocolID,
        dialectProfileID: fixture.dialect, requestsUsage: true, thinking: thinking
    )
    return AgentModelRoute(
        id: RouteID(), revision: 1, connectionID: ConnectionID(), connectionRevision: 1,
        modelDescriptorID: ModelDescriptorID(), modelRevision: 1,
        adapter: fixture.adapter, modelID: modelID,
        credential: .init(reference: "fixture", version: 1), contextWindow: contextWindow,
        maximumOutputTokens: maximumOutputTokens,
        capabilities: .init(streamsText: true, callsTools: true, producesThinking: true),
        configuration: try configuration.jsonValue()
    )
}

private func input(
    messages: [AgentModelMessage] = [.init(role: .user, text: "Hello")],
    tools: [ToolDefinition] = []
) -> AgentModelInput {
    AgentModelInput(stepID: UUID(), executionID: ExecutionID(), instructions: "System",
                    messages: messages, tools: tools)
}

private func jsonObject(_ value: JSONValue) throws -> [String: Any] {
    let data = try JSONEncoder().encode(value)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func bodyObject(_ transport: ThinkingTransport) throws -> [String: Any] {
    let body = try #require(transport.requests.first?.httpBody)
    return try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
}

private func stream(
    adapter: any AgentModelAdapter,
    input: AgentModelInput,
    route: AgentModelRoute
) async throws -> ([AgentModelStreamEvent], AgentModelFailure?) {
    let prepared = try adapter.prepare(input, route: route)
    let operation = adapter.stream(prepared, route: route)
    var events: [AgentModelStreamEvent] = []
    do {
        for try await event in operation.events { events.append(event) }
        await operation.close()
        return (events, nil)
    } catch let failure as AgentModelFailure {
        await operation.close()
        try failure.validate()
        return (events, failure)
    } catch {
        await operation.close()
        throw error
    }
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
    let credentials = ThinkingCredentials()
    let adapter = HTTPModelAdapter(fixture: .anthropic, credentials: credentials, transport: transport)
    let tools = [ToolDefinition(name: "memory.search", description: "Search", inputSchema: .object([:]))]
    let route = try route(fixture: .anthropic, thinking: .init(mode: .enabled, budgetTokens: 2_048), maximumOutputTokens: 4_096)
    let prepared = try adapter.prepare(input(tools: tools), route: route)
    #expect(credentials.reads == 0)
    let operation = adapter.stream(prepared, route: route)
    var events: [AgentModelStreamEvent] = []
    for try await event in operation.events { events.append(event) }
    await operation.close()
    #expect(credentials.reads == 1)

    let thinking = try #require(thinkingSnapshots(events).last)
    #expect(thinking.isComplete)
    guard case .array(let blocks) = try #require(thinking.continuation?.payload) else {
        Issue.record("Anthropic continuation was not an ordered block array")
        return
    }
    #expect(blocks.count == 5)
    #expect(blocks[0]["thinking"]?.stringValue == "first")
    #expect(blocks[0]["signature"]?.stringValue == "sig-a-one")
    #expect(blocks[1]["thinking"]?.stringValue == "second")
    #expect(blocks[1]["signature"]?.stringValue == "sig-b-two")
    #expect(blocks[2]["data"]?.stringValue == "opaque-redacted")
    #expect(blocks[3]["text"]?.stringValue == "answer")
    #expect(blocks[4]["id"]?.stringValue == "call-1")
    #expect(containsToolCall(events, id: "call-1", name: "memory.search", arguments: "{}"))

    let assistant = AgentModelMessage(
        role: .assistant, text: "answer",
        toolCalls: [.init(id: "call-1", name: "memory.search", arguments: "{}")],
        thinking: thinking
    )
    guard case .include(let sameExecution) = try adapter.replay(
        [assistant], from: route, to: route, boundary: .sameExecution
    ) else {
        Issue.record("same-execution Anthropic continuation was omitted")
        return
    }
    #expect(sameExecution == [assistant])
    guard case .include(let previousExecution) = try adapter.replay(
        [assistant], from: route, to: route, boundary: .previousExecution
    ) else {
        Issue.record("previous-turn Anthropic answer was omitted")
        return
    }
    #expect(previousExecution == [AgentModelMessage(
        role: .assistant, text: "answer",
        toolCalls: [.init(id: "call-1", name: "memory.search", arguments: "{}")]
    )])

    let replayTransport = ThinkingTransport(responseBytes: response)
    let replayAdapter = HTTPModelAdapter(fixture: .anthropic, credentials: ThinkingCredentials(), transport: replayTransport)
    let replayInput = input(messages: [assistant, .init(role: .tool, text: "Synthetic result", toolCallID: "call-1")], tools: tools)
    let replayPrepared = try replayAdapter.prepare(replayInput, route: route)
    let replayOperation = replayAdapter.stream(replayPrepared, route: route)
    for try await _ in replayOperation.events {}
    await replayOperation.close()
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
    let adapter = HTTPModelAdapter(fixture: .anthropic, credentials: ThinkingCredentials(), transport: transport)
    let route = try route(fixture: .anthropic, thinking: .init(mode: .enabled, budgetTokens: 2_048), maximumOutputTokens: 4_096)
    let tools = [ToolDefinition(name: "memory.search", description: "Search", inputSchema: .object([:]))]
    let result = try await stream(adapter: adapter, input: input(tools: tools), route: route)
    #expect(result.0.contains { isToolCallEvent($0) } == false)
    let failure = try #require(result.1)
    #expect(failure.error.code == .malformedStream)
    #expect(failure.retryAdvice == nil)
}

@Test("OpenRouter keeps 600 reasoning details ordered, deduplicates visible aliases, and stays bounded")
func openRouterLargeReasoningDetails() async throws {
    var frames: [(String, String)] = []
    for index in 0..<600 {
        let fragment: JSONValue
        switch index % 3 {
        case 0: fragment = .object(["type": .string("reasoning.text"), "id": .string("repeat"), "text": .string("visible")])
        case 1: fragment = .object(["type": .string("reasoning.summary"), "id": .string("repeat"), "summary": .string("summary")])
        default: fragment = .object(["type": .string("reasoning.encrypted"), "id": .string("repeat"), "data": .string("opaque")])
        }
        var delta: [String: JSONValue] = ["reasoning_details": .array([fragment])]
        if index == 0 { delta["reasoning_content"] = .string("visible") }
        let envelope = JSONValue.object(["choices": .array([.object(["delta": .object(delta)])])])
        frames.append(("", try envelope.jsonString()))
    }
    frames.append(("", #"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#))
    frames.append(("", "[DONE]"))
    let transport = ThinkingTransport(responseBytes: sse(frames))
    let adapter = HTTPModelAdapter(fixture: .openRouter, credentials: ThinkingCredentials(), transport: transport)
    let result = try await stream(adapter: adapter, input: input(), route: try route(fixture: .openRouter))
    #expect(result.1 == nil)
    let snapshots = thinkingSnapshots(result.0)
    let complete = try #require(snapshots.last)
    #expect(snapshots.count < 128)
    #expect(complete.isComplete)
    guard case .array(let blocks) = try #require(complete.continuation?.payload) else {
        Issue.record("OpenRouter continuation was not an ordered detail array")
        return
    }
    #expect(blocks.count == 600)
    #expect(blocks.first?["id"]?.stringValue == "repeat")
    #expect(blocks.last?["type"]?.stringValue == "reasoning.encrypted")
    #expect(complete.text.components(separatedBy: "visible").count - 1 == 200)
    #expect(complete.text.components(separatedBy: "summary").count - 1 == 200)
}

@Test("Partial OpenAI reasoning is emitted as incomplete before premature EOF")
func partialReasoningPrematureEOF() async throws {
    let transport = ThinkingTransport(responseBytes: sse([("", #"{"choices":[{"delta":{"reasoning_content":"partial"}}]}"#)]))
    let adapter = HTTPModelAdapter(fixture: .openAI, credentials: ThinkingCredentials(), transport: transport)
    let result = try await stream(adapter: adapter, input: input(), route: try route(fixture: .openAI, modelID: "gpt-5.1"))
    let thinking = try #require(thinkingSnapshots(result.0).first)
    #expect(thinking.text == "partial")
    #expect(thinking.isComplete == false)
    #expect(result.0.contains { if case .finished = $0 { true } else { false } } == false)
    let failure = try #require(result.1)
    #expect(failure.error.code == .interrupted)
    #expect(failure.retryAdvice == nil)
}

@Test("Thinking payload table preserves provider defaults and explicit controls")
func thinkingPayloadTable() async throws {
    struct Case { let fixture: ProtocolFixture; let route: AgentModelRoute; let anthropic: Bool; let check: ([String: Any]) -> Bool }
    let cases: [Case] = [
        Case(fixture: .deepSeek, route: try route(fixture: .deepSeek, modelID: "deepseek-v4-pro"), anthropic: false, check: { body in body["thinking"] == nil && body["reasoning_effort"] == nil }),
        Case(fixture: .deepSeek, route: try route(fixture: .deepSeek, modelID: "deepseek-v4-pro", thinking: .init(mode: .enabled, effort: .high)), anthropic: false, check: { body in (body["thinking"] as? [String: String]) == ["type": "enabled"] && body["reasoning_effort"] as? String == "high" }),
        Case(fixture: .kimi, route: try route(fixture: .kimi, modelID: "kimi-k3", thinking: .init(mode: .providerDefault, effort: .max)), anthropic: false, check: { body in body["thinking"] == nil && body["reasoning_effort"] as? String == "max" && body["max_completion_tokens"] as? Int == 2_048 && body["max_tokens"] == nil }),
        Case(fixture: .kimi, route: try route(fixture: .kimi, modelID: "k3-256k", thinking: .init(mode: .providerDefault, effort: .high)), anthropic: false, check: { body in body["thinking"] == nil && body["reasoning_effort"] as? String == "high" && body["max_completion_tokens"] as? Int == 2_048 && body["max_tokens"] == nil }),
        Case(fixture: .kimi, route: try route(fixture: .kimi, modelID: "kimi-for-coding", thinking: .init(mode: .enabled)), anthropic: false, check: { body in (body["thinking"] as? [String: String]) == ["type": "enabled", "keep": "all"] && body["max_completion_tokens"] as? Int == 2_048 && body["max_tokens"] == nil }),
        Case(fixture: .kimi, route: try route(fixture: .kimi, modelID: "kimi-k2.6", thinking: .init(mode: .enabled)), anthropic: false, check: { body in (body["thinking"] as? [String: String]) == ["type": "enabled", "keep": "all"] }),
        Case(fixture: .openAI, route: try route(fixture: .openAI, modelID: "gpt-5.1"), anthropic: false, check: { body in body["reasoning_effort"] == nil && body["max_completion_tokens"] as? Int == 2_048 && body["max_tokens"] == nil }),
        Case(fixture: .openAI, route: try route(fixture: .openAI, modelID: "gpt-5.1", thinking: .init(mode: .providerDefault, effort: .high)), anthropic: false, check: { body in body["reasoning_effort"] as? String == "high" }),
        Case(fixture: .anthropic, route: try route(fixture: .anthropic, thinking: .init(mode: .disabled), maximumOutputTokens: 4_096), anthropic: true, check: { body in (body["thinking"] as? [String: String]) == ["type": "disabled"] }),
        Case(fixture: .anthropic, route: try route(fixture: .anthropic, thinking: .init(mode: .providerDefault, budgetTokens: 2_048), maximumOutputTokens: 4_096), anthropic: true, check: { body in (body["thinking"] as? [String: Any])?["type"] as? String == "enabled" && (body["thinking"] as? [String: Any])?["budget_tokens"] as? Int == 2_048 }),
        Case(fixture: .anthropic, route: try route(fixture: .anthropic, modelID: "claude-sonnet-4-6", thinking: .init(mode: .providerDefault, effort: .high), maximumOutputTokens: 4_096), anthropic: true, check: { body in (body["thinking"] as? [String: String]) == ["type": "adaptive"] && (body["output_config"] as? [String: String]) == ["effort": "high"] })
    ]
    for testCase in cases {
        let transport = ThinkingTransport(responseBytes: testCase.anthropic ? anthropicStopStream() : openAIStopStream())
        let credentials = ThinkingCredentials()
        let adapter = HTTPModelAdapter(fixture: testCase.fixture, credentials: credentials, transport: transport)
        let prepared = try adapter.prepare(input(), route: testCase.route)
        #expect(credentials.reads == 0)
        #expect(testCase.check(try jsonObject(prepared.wirePayload)))
        let operation = adapter.stream(prepared, route: testCase.route)
        for try await _ in operation.events {}
        await operation.close()
        #expect(testCase.check(try bodyObject(transport)))
    }
}

@Test("Conflicting OpenRouter controls fail before dispatch")
func conflictingOpenRouterControls() async throws {
    let transport = ThinkingTransport(responseBytes: openAIStopStream())
    let adapter = HTTPModelAdapter(fixture: .openRouter, credentials: ThinkingCredentials(), transport: transport)
    let route = try route(fixture: .openRouter, thinking: .init(mode: .enabled, effort: .high, budgetTokens: 1_024))
    do {
        _ = try adapter.prepare(input(), route: route)
        Issue.record("Expected conflicting OpenRouter controls to fail during preparation.")
    } catch let error as MiraError {
        #expect(error.code == .configuration)
    }
    #expect(transport.requests.isEmpty)
}

@Test("Kimi provider defaults preserve reasoning history when replaying a tool turn")
func kimiProviderDefaultPreservesReasoningHistory() throws {
    let transport = ThinkingTransport(responseBytes: openAIStopStream())
    let adapter = HTTPModelAdapter(fixture: .kimi, credentials: ThinkingCredentials(), transport: transport)
    let route = try route(fixture: .kimi, modelID: "kimi-k2.6")
    let continuation = AgentModelContinuation(adapter: route.adapter, format: "openai.content",
        payload: .array([.object(["text": .string("plan")])]), isComplete: true)
    let history = AgentModelMessage(role: .assistant, text: "answer",
        thinking: .init(text: "plan", continuation: continuation, isComplete: true))
    let prepared = try adapter.prepare(input(messages: [history, .init(role: .user, text: "Continue")]), route: route)
    let body = try jsonObject(prepared.wirePayload)
    #expect((body["thinking"] as? [String: String]) == ["type": "enabled", "keep": "all"])
    let messages = try #require(body["messages"] as? [[String: Any]])
    #expect(messages[1]["reasoning_content"] as? String == "plan")
}
