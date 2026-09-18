import Foundation
import Testing
@testable import MiraCore
@testable import MiraProviders

@Suite("Responses protocol fixtures")
struct OpenAIResponsesProtocolTests {
    @Test func protocolAndDialectIdentifiersAreWireStrings() throws {
        let configuration = HTTPInvocationSettings(protocolID: .responses, dialectProfileID: .openAI,
                                                    thinking: .init(mode: .enabled, effort: .high))
        let value = try SessionCodec.decode(JSONValue.self, from: SessionCodec.encode(configuration))
        #expect(value["protocolID"] == .string("openai.responses"))
        #expect(value["dialectProfileID"] == .string("openai.chat"))
        #expect(value["thinking"]?["effort"] == .string("high"))
    }

    @Test func responsesSSESupportsSplitUTF8AndMultilineData() throws {
        var parser = ResponsesSSEParser()
        var frames: [ResponsesSSEFrame] = []
        let payload = Data("event: response.output_text.delta\ndata: {\"delta\":\"hé\"}\n\n".utf8) // i18n-fixture: split UTF-8 framing coverage.
        let split = payload.index(payload.startIndex, offsetBy: 7)
        try parser.feed(Data(payload[..<split]), emit: { frames.append($0) })
        try parser.feed(Data(payload[split...]), emit: { frames.append($0) })
        try parser.finish(emit: { frames.append($0) })
        #expect(frames.count == 1)
        #expect(frames.first?.event == "response.output_text.delta")
        #expect(frames.first?.data == "{\"delta\":\"hé\"}") // i18n-fixture: split UTF-8 framing coverage.
    }

    @Test func responsesSSERejectsOversizedEvent() {
        var parser = ResponsesSSEParser()
        let oversized = Data(("data: " + String(repeating: "x", count: 4_194_305) + "\n\n").utf8)
        #expect(throws: ResponsesProtocolError.self) { try parser.feed(oversized, emit: { _ in }) }
    }

    @Test func requestRetainsOrderedItemsAndEncryptedReasoningWithoutProviderStorage() throws {
        let priorItems: JSONValue = .array([
            .object(["type": .string("reasoning"), "id": .string("rs_1"), "encrypted_content": .string("ciphertext")]),
            .object(["type": .string("message"), "id": .string("msg_1"), "role": .string("assistant"), "content": .array([
                .object(["type": .string("output_text"), "text": .string("Earlier")])
            ])])
        ])
        let continuation = AgentModelContinuation(adapter: HTTPAdapterIdentity.responses,
                                                  format: "openai.responses.items", payload: priorItems, isComplete: true)
        let input = AgentModelInput(stepID: UUID(), executionID: ExecutionID(), instructions: "Be concise", messages: [
            .init(role: .assistant, blocks: [.init(id: "answer", content: .text("Earlier"))], continuation: continuation),
            .init(role: .user, blocks: [.init(id: "question", content: .text("Continue"))])
        ], tools: [])
        let prepared = try OpenAIResponsesAdapter(credentials: FixtureCredentials()).prepare(input, route: responsesRoute())
        #expect(prepared.wirePayload["store"] == .bool(false))
        #expect(prepared.wirePayload["include"] == .array([.string("reasoning.encrypted_content")]))
        guard case .array(let inputItems) = prepared.wirePayload["input"] else { Issue.record("Missing ordered input"); return }
        #expect(inputItems[0]["id"] == .string("rs_1"))
        #expect(inputItems[1]["id"] == .string("msg_1"))
        #expect(inputItems[2]["type"] == .string("message"))
    }

    @Test func responsesToolDefinitionsPreserveOptionalSchemasWithStrictDisabled() throws {
        let definitions = [TaskTools.mutationDefinition, KnowledgeTools.openDefinition]
        let input = AgentModelInput(stepID: UUID(), executionID: ExecutionID(), instructions: "Use local tools", messages: [
            .init(role: .user, blocks: [.init(id: "question", content: .text("Create a task"))])
        ], tools: definitions)
        let prepared = try OpenAIResponsesAdapter(credentials: FixtureCredentials()).prepare(input, route: responsesRoute())
        guard case .array(let tools) = prepared.wirePayload["tools"] else {
            Issue.record("Missing Responses tool definitions")
            return
        }
        #expect(tools.count == definitions.count)
        for (wire, definition) in zip(tools, definitions) {
            #expect(wire["strict"] == .bool(false))
            #expect(wire["parameters"] == definition.inputSchema)
        }
        #expect(tools[0]["parameters"]?["required"] == TaskTools.mutationDefinition.inputSchema["required"])
        #expect(tools[1]["parameters"]?["required"] == KnowledgeTools.openDefinition.inputSchema["required"])

        let taskArguments = try ToolSchemaValidator.decode(
            "{\"operation\":\"create\",\"title\":\"Buy milk\",\"quote\":\"Please remind me\",\"remind\":false}",
            schema: TaskTools.mutationDefinition.inputSchema)
        let sourceArguments = try ToolSchemaValidator.decode(
            "{\"source_id\":\"00000000-0000-0000-0000-000000000000\"}",
            schema: KnowledgeTools.openDefinition.inputSchema)
        #expect(taskArguments["notes"] == nil)
        #expect(sourceArguments["version_id"] == nil)
    }

    @Test func responsesCachedPrefixKeepsToolsButDisablesCallsAndBoundsOutput() throws {
        let definition = ToolDefinition(name: "memory.search", description: "Search memory",
                                         inputSchema: .object(["type": .string("object")]))
        let input = AgentModelInput(stepID: UUID(), executionID: ExecutionID(), instructions: "Extract memories.", messages: [
            .init(role: .user, text: "Earlier"), .init(role: .assistant, text: "Earlier answer"),
            .init(role: .user, text: "Current")
        ], tools: [definition], allowsToolCalls: false, prefixMessageCount: 2, outputTokenLimit: 64)
        let prepared = try OpenAIResponsesAdapter(credentials: FixtureCredentials()).prepare(input, route: responsesRoute())
        #expect(prepared.wirePayload["tool_choice"] == .string("none"))
        #expect(prepared.wirePayload["max_output_tokens"] == .number(64))
        guard case .array(let tools) = prepared.wirePayload["tools"] else {
            Issue.record("Responses request omitted the cached tool definitions.")
            return
        }
        #expect(tools.count == 1)
        #expect(tools[0]["name"] == .string("memory_search"))
    }

    @Test func tamperedVisibleTextCannotReuseResponsesContinuation() throws {
        let priorItems: JSONValue = .array([
            .object(["type": .string("message"), "id": .string("msg_1"), "role": .string("assistant"),
                     "content": .array([.object(["type": .string("output_text"), "text": .string("Earlier")])])])
        ])
        let continuation = AgentModelContinuation(adapter: HTTPAdapterIdentity.responses,
            format: "openai.responses.items", payload: priorItems, isComplete: true)
        let input = AgentModelInput(stepID: UUID(), executionID: ExecutionID(), instructions: "Be concise", messages: [
            .init(role: .assistant, blocks: [.init(id: "answer", content: .text("Tampered"))], continuation: continuation),
            .init(role: .user, blocks: [.init(id: "question", content: .text("Continue"))])
        ], tools: [])
        #expect(throws: ResponsesProtocolError.self) {
            _ = try OpenAIResponsesAdapter(credentials: FixtureCredentials()).prepare(input, route: responsesRoute())
        }
    }

    @Test func completeResponsePreservesReasoningToolAndUsageBoundaries() async throws {
        let body = """
        event: response.created
        data: {"type":"response.created","response":{"id":"resp_1","type":"response","status":"in_progress"}}

        event: response.output_item.added
        data: {"type":"response.output_item.added","item":{"id":"rs_1","type":"reasoning","encrypted_content":null}}

        event: response.reasoning_summary_text.delta
        data: {"type":"response.reasoning_summary_text.delta","item_id":"rs_1","delta":"plan"}

        event: response.output_item.added
        data: {"type":"response.output_item.added","item":{"id":"msg_1","type":"message","role":"assistant"}}

        event: response.output_text.delta
        data: {"type":"response.output_text.delta","item_id":"msg_1","delta":"answer"}

        event: response.output_item.added
        data: {"type":"response.output_item.added","item":{"id":"fc_1","type":"function_call","call_id":"call_1","name":"memory_search"}}

        event: response.function_call_arguments.delta
        data: {"type":"response.function_call_arguments.delta","item_id":"fc_1","delta":"{}"}

        event: response.output_item.done
        data: {"type":"response.output_item.done","item":{"id":"rs_1","type":"reasoning","encrypted_content":"ciphertext"}}

        event: response.output_item.done
        data: {"type":"response.output_item.done","item":{"id":"msg_1","type":"message","role":"assistant"}}

        event: response.output_item.done
        data: {"type":"response.output_item.done","item":{"id":"fc_1","type":"function_call","call_id":"call_1","name":"memory_search","arguments":"{}"}}

        event: response.completed
        data: {"type":"response.completed","response":{"id":"resp_1","status":"completed","output":[{"id":"rs_1","type":"reasoning","encrypted_content":"ciphertext"},{"id":"msg_1","type":"message","content":[{"type":"output_text","text":"answer","annotations":[]}]},{"id":"fc_1","type":"function_call","call_id":"call_1","name":"memory_search","arguments":"{}"}],"usage":{"input_tokens":11,"output_tokens":7,"output_tokens_details":{"reasoning_tokens":3}}}}

        """
        let transport = FixtureResponsesTransport(bytes: Data(body.utf8))
        let adapter = OpenAIResponsesAdapter(credentials: FixtureCredentials(), transport: transport)
        let input = AgentModelInput(stepID: UUID(), executionID: ExecutionID(), instructions: "", messages: [
            .init(role: .user, blocks: [.init(id: "q", content: .text("Hi"))])
        ], tools: [.init(name: "memory.search", description: "Search", inputSchema: .object([:]))])
        let route = try responsesRoute()
        let request = try adapter.prepare(input, route: route)
        let operation = adapter.stream(request, route: route)
        var events: [AgentModelStreamEvent] = []
        for try await event in operation.events { events.append(event) }
        await operation.close()
        #expect(events.contains { if case .blockStarted(let block) = $0, case .thinking = block.content { return block.id == "rs_1" }; return false })
        #expect(events.contains { if case .blockStarted(let block) = $0, case .toolCall(let call) = block.content { return call.id == "call_1" }; return false })
        #expect(events.contains(.usage(.init(inputTokens: 11, outputTokens: 7, reasoningTokens: 3))))
        #expect(events.contains { if case .finished(.toolCalls) = $0 { return true }; return false })
        let continuation = try #require(events.compactMap { event -> AgentModelContinuation? in
            if case .continuation(let value) = event { return value }; return nil
        }.first)
        #expect(continuation.isComplete)
        guard case .array(let items) = continuation.payload else { Issue.record("Missing continuation items"); return }
        #expect(items[0]["encrypted_content"] == .string("ciphertext"))
        #expect(transport.closeCount == 1)
    }

    @Test func omittedTerminalItemStatusRequiresPriorDoneBoundary() async throws {
        let body = """
        event: response.output_item.added
        data: {"type":"response.output_item.added","item":{"id":"msg_1","type":"message","role":"assistant"}}

        event: response.completed
        data: {"type":"response.completed","response":{"id":"resp_1","status":"completed","output":[{"id":"msg_1","type":"message"}]}}
        """
        let failure = try await streamFailure(body: body)
        #expect(failure.error.code == .malformedStream)
    }

    @Test func terminalItemStatusRejectsNonStringAndContradictoryDoneStatus() async throws {
        let nullStatus = """
        event: response.output_item.added
        data: {"type":"response.output_item.added","item":{"id":"msg_1","type":"message","role":"assistant"}}

        event: response.output_item.done
        data: {"type":"response.output_item.done","item":{"id":"msg_1","type":"message","role":"assistant"}}

        event: response.completed
        data: {"type":"response.completed","response":{"id":"resp_1","status":"completed","output":[{"id":"msg_1","type":"message","status":null}]}}
        """
        let nullFailure = try await streamFailure(body: nullStatus)
        #expect(nullFailure.error.code == .malformedStream)

        let contradictoryDoneStatus = """
        event: response.output_item.added
        data: {"type":"response.output_item.added","item":{"id":"msg_1","type":"message","role":"assistant"}}

        event: response.output_item.done
        data: {"type":"response.output_item.done","item":{"id":"msg_1","type":"message","role":"assistant","status":"incomplete"}}

        event: response.completed
        data: {"type":"response.completed","response":{"id":"resp_1","status":"completed","output":[{"id":"msg_1","type":"message"}]}}
        """
        let contradictoryFailure = try await streamFailure(body: contradictoryDoneStatus)
        #expect(contradictoryFailure.error.code == .malformedStream)
    }

    @Test func providerErrorEventMapsToSafeProviderRejection() async throws {
        let body = """
        event: error
        data: {"type":"error","code":"provider_secret","message":"do not persist this user content"}
        """
        let failure = try await streamFailure(body: body)
        #expect(failure.error.code == .providerRejected)
        #expect(failure.error.message == "The provider rejected the request.")
    }

    @Test func responsesEOFBeforeCompletedIsInterruptedAndClosesTransport() async throws {
        let bytes = Data("event: response.output_text.delta\ndata: {\"type\":\"response.output_text.delta\",\"item_id\":\"msg_1\",\"delta\":\"partial\"}\n\n".utf8)
        let transport = FixtureResponsesTransport(bytes: bytes)
        let adapter = OpenAIResponsesAdapter(credentials: FixtureCredentials(), transport: transport)
        let route = try responsesRoute()
        let input = AgentModelInput(stepID: UUID(), executionID: ExecutionID(), instructions: "", messages: [
            .init(role: .user, blocks: [.init(id: "q", content: .text("Hi"))])
        ], tools: [])
        let request = try adapter.prepare(input, route: route)
        let operation = adapter.stream(request, route: route)
        var failure: AgentModelFailure?
        do { for try await _ in operation.events {} }
        catch let error as AgentModelFailure { failure = error }
        await operation.close()
        #expect(failure?.error.code == .malformedStream)
        #expect(transport.closeCount == 1)
    }

    @Test func malformedUsageAndTerminalOutputFailClosed() async throws {
        let usage = """
        event: response.output_item.added
        data: {"type":"response.output_item.added","item":{"id":"msg_1","type":"message","role":"assistant"}}

        event: response.output_text.delta
        data: {"type":"response.output_text.delta","item_id":"msg_1","delta":"answer"}

        event: response.output_item.done
        data: {"type":"response.output_item.done","item":{"id":"msg_1","type":"message","role":"assistant"}}

        event: response.completed
        data: {"type":"response.completed","response":{"id":"resp_1","status":"completed","output":[{"id":"msg_1","type":"message","status":"completed","role":"assistant"}],"usage":{"input_tokens":1.25}}}
        """
        let usageFailure = try await streamFailure(body: usage)
        #expect(usageFailure.error.code == .malformedStream)

        let terminal = """
        event: response.output_item.added
        data: {"type":"response.output_item.added","item":{"id":"msg_1","type":"message","role":"assistant"}}

        event: response.output_text.delta
        data: {"type":"response.output_text.delta","item_id":"msg_1","delta":"answer"}

        event: response.completed
        data: {"type":"response.completed","response":{"id":"resp_1","status":"completed","output":[{"id":"msg_1","type":"message","status":"completed","role":"assistant","content":[{"type":"output_text","text":"tampered"}]}]}}
        """
        let terminalFailure = try await streamFailure(body: terminal)
        #expect(terminalFailure.error.code == .malformedStream)
    }

    @Test func incompleteResponseNeverProposesToolCalls() async throws {
        let body = """
        event: response.output_item.added
        data: {"type":"response.output_item.added","item":{"id":"fc_1","type":"function_call","call_id":"call_1","name":"memory_search"}}

        event: response.function_call_arguments.delta
        data: {"type":"response.function_call_arguments.delta","item_id":"fc_1","delta":"{}"}

        event: response.output_item.done
        data: {"type":"response.output_item.done","item":{"id":"fc_1","type":"function_call","call_id":"call_1","name":"memory_search","arguments":"{}"}}

        event: response.output_item.added
        data: {"type":"response.output_item.added","item":{"id":"msg_1","type":"message","role":"assistant"}}

        event: response.output_text.delta
        data: {"type":"response.output_text.delta","item_id":"msg_1","delta":"partial after tool"}

        event: response.output_item.done
        data: {"type":"response.output_item.done","item":{"id":"msg_1","type":"message","role":"assistant"}}

        event: response.incomplete
        data: {"type":"response.incomplete","response":{"id":"resp_1","status":"incomplete","output":[{"id":"fc_1","type":"function_call","status":"incomplete","call_id":"call_1","name":"memory_search","arguments":"{}"},{"id":"msg_1","type":"message","status":"incomplete","content":[{"type":"output_text","text":"partial after tool","annotations":[]}] }]}}
        """
        let events = try await streamEvents(body: body)
        #expect(!events.contains { if case .blockStarted(let block) = $0, case .toolCall = block.content { return true }; return false })
        #expect(events.contains { if case .blockDelta(id: "msg_1", text: "partial after tool") = $0 { return true }; return false })
        #expect(events.contains { if case .finished(.outputLimit) = $0 { return true }; return false })
    }

    @Test func functionCallRequiresWireFieldsAndPreservesOrder() async throws {
        let missingID = """
        event: response.output_item.added
        data: {"type":"response.output_item.added","item":{"id":"fc_1","type":"function_call","name":"memory_search"}}

        event: response.function_call_arguments.delta
        data: {"type":"response.function_call_arguments.delta","item_id":"fc_1","delta":"{}"}

        event: response.output_item.done
        data: {"type":"response.output_item.done","item":{"id":"fc_1","type":"function_call","name":"memory_search","arguments":"{}"}}

        event: response.completed
        data: {"type":"response.completed","response":{"id":"resp_1","status":"completed","output":[{"id":"fc_1","type":"function_call","status":"completed","name":"memory_search","arguments":"{}"}]}}
        """
        let missingIDFailure = try await streamFailure(body: missingID)
        #expect(missingIDFailure.error.code == .malformedStream)

        let outOfOrder = """
        event: response.output_item.added
        data: {"type":"response.output_item.added","item":{"id":"fc_1","type":"function_call","call_id":"call_1","name":"memory_search"}}

        event: response.function_call_arguments.delta
        data: {"type":"response.function_call_arguments.delta","item_id":"fc_1","delta":"{}"}

        event: response.output_item.done
        data: {"type":"response.output_item.done","item":{"id":"fc_1","type":"function_call","call_id":"call_1","name":"memory_search","arguments":"{}"}}

        event: response.output_item.added
        data: {"type":"response.output_item.added","item":{"id":"msg_1","type":"message","role":"assistant"}}

        event: response.output_text.delta
        data: {"type":"response.output_text.delta","item_id":"msg_1","delta":"after tool"}

        event: response.output_item.done
        data: {"type":"response.output_item.done","item":{"id":"msg_1","type":"message","role":"assistant"}}

        event: response.completed
        data: {"type":"response.completed","response":{"id":"resp_1","status":"completed","output":[{"id":"fc_1","type":"function_call","status":"completed","call_id":"call_1","name":"memory_search","arguments":"{}"},{"id":"msg_1","type":"message","status":"completed","content":[{"type":"output_text","text":"after tool","annotations":[]}]}]}}
        """
        let events = try await streamEvents(body: outOfOrder)
        let blockEvents = events.compactMap { event -> String? in
            guard case .blockStarted(let block) = event else { return nil }
            switch block.content { case .toolCall: return "tool"; case .text: return "text"; default: return nil }
        }
        #expect(blockEvents == ["tool", "text"])
    }

    @Test func responsesRetryAfterIsBoundedAndPreserved() async throws {
        let transport = FixtureResponsesTransport(bytes: Data(), status: 429, headers: ["Retry-After": "12"])
        let adapter = OpenAIResponsesAdapter(credentials: FixtureCredentials(), transport: transport, now: { Date(timeIntervalSince1970: 0) })
        let route = try responsesRoute()
        let input = AgentModelInput(stepID: UUID(), executionID: ExecutionID(), instructions: "", messages: [.init(role: .user, blocks: [.init(id: "q", content: .text("Hi"))])], tools: [])
        let request = try adapter.prepare(input, route: route)
        let operation = adapter.stream(request, route: route)
        var failure: AgentModelFailure?
        do { for try await _ in operation.events {} } catch let value as AgentModelFailure { failure = value }
        await operation.close()
        #expect(failure?.error.code == .rateLimited)
        #expect(failure?.retryAdvice == .transient(minimumDelayMilliseconds: 12_000))
    }

    @Test func responseArgumentAggregateLimitIsEnforcedDuringStreaming() async throws {
        let fragment = String(repeating: "x", count: 65_537)
        let body = """
        event: response.output_item.added
        data: {"type":"response.output_item.added","item":{"id":"fc_1","type":"function_call","call_id":"call_1","name":"memory_search"}}

        event: response.function_call_arguments.delta
        data: {"type":"response.function_call_arguments.delta","item_id":"fc_1","delta":"\(fragment)"}
        """
        let failure = try await streamFailure(body: body)
        #expect(failure.error.code == .malformedStream)
    }

    @Test func refusalDeltasBecomeVisibleTextAndAreValidatedAtDone() async throws {
        let body = """
        event: response.output_item.added
        data: {"type":"response.output_item.added","item":{"id":"msg_1","type":"message","role":"assistant"}}

        event: response.refusal.delta
        data: {"type":"response.refusal.delta","item_id":"msg_1","output_index":0,"content_index":0,"delta":"I cannot help"}

        event: response.refusal.done
        data: {"type":"response.refusal.done","item_id":"msg_1","output_index":0,"content_index":0,"refusal":"I cannot help"}

        event: response.output_item.done
        data: {"type":"response.output_item.done","item":{"id":"msg_1","type":"message","role":"assistant"}}

        event: response.completed
        data: {"type":"response.completed","response":{"id":"resp_1","status":"completed","output":[{"id":"msg_1","type":"message","status":"completed","role":"assistant","content":[{"type":"refusal","refusal":"I cannot help"}]}]}}
        """
        let events = try await streamEvents(body: body)
        #expect(events.contains { if case .blockDelta(id: "msg_1", text: "I cannot help") = $0 { return true }; return false })
        #expect(events.contains { if case .finished(.stop) = $0 { return true }; return false })
    }

    @Test func responseTerminalIdentityAndStatusAreRequired() async throws {
        let body = """
        event: response.created
        data: {"type":"response.created","response":{"id":"resp_1","type":"response","status":"in_progress"}}

        event: response.output_item.added
        data: {"type":"response.output_item.added","item":{"id":"msg_1","type":"message","role":"assistant"}}

        event: response.completed
        data: {"type":"response.completed","response":{"id":"resp_2","status":"completed","output":[{"id":"msg_1","type":"message","status":"completed"}]}}
        """
        let failure = try await streamFailure(body: body)
        #expect(failure.error.code == .malformedStream)
    }

    @Test func ownedContinuationWithWrongFormatIsRejected() throws {
        let continuation = AgentModelContinuation(adapter: HTTPAdapterIdentity.responses,
            format: "openai.responses.unknown", payload: .array([]), isComplete: true)
        let input = AgentModelInput(stepID: UUID(), executionID: ExecutionID(), instructions: "", messages: [
            .init(role: .assistant, blocks: [.init(id: "answer", content: .text("Earlier"))], continuation: continuation)
        ], tools: [])
        #expect(throws: ResponsesProtocolError.self) {
            _ = try OpenAIResponsesAdapter(credentials: FixtureCredentials()).prepare(input, route: responsesRoute())
        }
    }

    @Test func previousExecutionReplayUsesDescriptorAndEndpointIdentity() throws {
        let continuation = AgentModelContinuation(adapter: HTTPAdapterIdentity.responses,
            format: "openai.responses.items", payload: .array([]), isComplete: true)
        let message = AgentModelMessage(role: .assistant, blocks: [
            .init(id: "thinking", content: .thinking("plan")),
            .init(id: "answer", content: .text("Answer"))
        ], continuation: continuation)
        let adapter = OpenAIResponsesAdapter(credentials: FixtureCredentials())
        let source = try responsesRoute()
        let refreshed = try responsesRoute(invocationRevision: 2, descriptorID: source.modelDescriptorID, connectionID: source.connectionID)
        guard case .include(let retained) = try adapter.replay([message], from: source, to: refreshed, boundary: .previousExecution) else {
            Issue.record("A metadata-only invocation revision refreshed the route unexpectedly."); return
        }
        #expect(retained == [message])
        let changedEndpoint = try responsesRoute(baseURL: "https://api.openai.com/v2", descriptorID: source.modelDescriptorID, connectionID: source.connectionID)
        guard case .include(let stripped) = try adapter.replay([message], from: source, to: changedEndpoint, boundary: .previousExecution) else {
            Issue.record("Ordinary visible history was not retained after endpoint change."); return
        }
        #expect(stripped.first?.continuation == nil)
        #expect(stripped.first?.thinkingText == "")
        #expect(stripped.first?.text == "Answer")
    }

    private func streamEvents(body: String) async throws -> [AgentModelStreamEvent] {
        let transport = FixtureResponsesTransport(bytes: Data(body.utf8))
        let adapter = OpenAIResponsesAdapter(credentials: FixtureCredentials(), transport: transport)
        let route = try responsesRoute()
        let input = AgentModelInput(stepID: UUID(), executionID: ExecutionID(), instructions: "", messages: [.init(role: .user, blocks: [.init(id: "q", content: .text("Hi"))])], tools: [.init(name: "memory.search", description: "Search", inputSchema: .object([:]))])
        let request = try adapter.prepare(input, route: route)
        let operation = adapter.stream(request, route: route)
        var events: [AgentModelStreamEvent] = []
        for try await event in operation.events { events.append(event) }
        await operation.close()
        return events
    }

    private func streamFailure(body: String) async throws -> AgentModelFailure {
        do {
            _ = try await streamEvents(body: body)
            throw ExpectedFailure()
        } catch let failure as AgentModelFailure {
            return failure
        }
    }

    private func responsesRoute(baseURL: String = "https://api.openai.com/v1", invocationRevision: Int = 1, descriptorID: ModelDescriptorID = ModelDescriptorID(), connectionID: ConnectionID = ConnectionID()) throws -> AgentModelRoute {
        let configuration = HTTPModelConfiguration(baseURL: baseURL, protocolID: .responses,
                                                    dialectProfileID: .openAI, thinking: .init(mode: .enabled, effort: .high))
        return AgentModelRoute(id: RouteID(), revision: 1, connectionID: connectionID, connectionRevision: 1,
                               modelDescriptorID: descriptorID, modelRevision: 1, modelAuthorizationRevision: 1,
                               adapter: HTTPAdapterIdentity.responses, invocationID: "responses", invocationRevision: invocationRevision,
                               endpointID: "primary", modelID: "gpt-5",
                               credential: .init(reference: "fixture", version: 1), contextWindow: 16_384,
                               maximumOutputTokens: 2_048, capabilities: .init(streamsText: true, callsTools: true, producesThinking: true),
                               configuration: try configuration.jsonValue())
    }
}

private struct FixtureCredentials: CredentialReader {
    func read(reference: String, version: Int) throws -> String { "fixture-secret" }
}

private final class FixtureResponsesTransport: HTTPStreamingTransport, @unchecked Sendable {
    let bytes: Data
    let status: Int
    let headers: [String: String]
    private(set) var closeCount = 0
    init(bytes: Data, status: Int = 200, headers: [String: String] = [:]) {
        self.bytes = bytes; self.status = status; self.headers = headers
    }
    func stream(request: URLRequest) -> HTTPTransportOperation {
        let (events, continuation) = AsyncThrowingStream<HTTPTransportEvent, any Error>.makeStream()
        continuation.yield(.response(.init(statusCode: status, headers: headers)))
        if !bytes.isEmpty { continuation.yield(.bytes(bytes)) }
        continuation.yield(.end)
        continuation.finish()
        return HTTPTransportOperation(events: events) { [weak self] in self?.closeCount += 1 }
    }
}

private struct ExpectedFailure: Error {}
