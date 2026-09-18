import Foundation
import XCTest
@testable import MiraCore
@testable import MiraData

final class SessionLogCodecTests: XCTestCase {
    func testSyntheticTurnRoundTripsWithSharedDefinitionsAndToolStream() throws {
        let fixture = try makeFixture()
        let encoded = try SessionLogCodec.encode(fixture.batch, previous: .initial)

        guard case .header(let header) = encoded.records.first else {
            return XCTFail("The first physical record must be the DSH session header")
        }
        XCTAssertEqual(header.version, 3)
        XCTAssertEqual(header.id, fixture.sessionID.rawValue.uuidString)

        let events = encoded.records.compactMap { record -> SessionLogEvent? in
            guard case .event(let event) = record else { return nil }
            return event
        }
        let types = events.map(\.type)
        XCTAssertLessThan(try XCTUnwrap(types.firstIndex(of: "step/start")),
                          try XCTUnwrap(types.firstIndex(of: "system/message")))
        XCTAssertLessThan(try XCTUnwrap(types.firstIndex(of: "system/message")),
                          try XCTUnwrap(types.firstIndex(of: "user/message")))
        XCTAssertEqual(types.filter { $0 == "system/message" }.count, 1)
        XCTAssertEqual(types.filter { $0 == "user/message" }.count, 1)
        XCTAssertEqual(types.filter { $0 == "assistant/message" }.count, 2)
        XCTAssertEqual(types.filter { $0 == "tool/call" }.count, 1)
        XCTAssertEqual(types.filter { $0 == "tool/result" }.count, 1)

        let json = try events.map { String(decoding: try SessionLogEventCodec.encode($0), as: UTF8.self) }.joined()
        XCTAssertFalse(json.contains("wire"))
        XCTAssertFalse(json.contains("bindings"))
        XCTAssertFalse(json.contains("draft-checkpoint"))
        XCTAssertFalse(json.contains("replayMessage"))
        XCTAssertFalse(json.contains("metadataEvidence"))
        XCTAssertFalse(json.contains("binary"), "The DSH layer must not expose binary/.bin fields")
        XCTAssertEqual(json.components(separatedBy: "Stable system prompt").count - 1, 1)
        XCTAssertEqual(json.components(separatedBy: "user question").count - 1, 1)
        XCTAssertFalse(json.contains("mira-context"), "A tool observation projection must reuse the canonical tool/result message")
        XCTAssertTrue(json.contains("toolPayload"), "The business payload must reference its canonical tool result")

        let assistantMessages = events.compactMap { event -> SessionMessage? in
            guard case .assistantMessage(_, _, let message, let stream, _, _) = event.data else { return nil }
            XCTAssertFalse(stream.isEmpty)
            return message
        }
        XCTAssertEqual(assistantMessages.count, 2)
        guard case .model(let provider, let model, let replay) = assistantMessages[0].source else {
            return XCTFail("Assistant output must retain model provenance")
        }
        XCTAssertEqual(provider, fixture.route.adapter.id)
        XCTAssertEqual(model, fixture.route.modelID)
        XCTAssertNotNil(replay)

        let decoded = try SessionLogCodec.decode(encoded.records, batchID: fixture.batchID,
                                                 sessionID: fixture.sessionID)
        XCTAssertEqual(decoded.batch.sessionID, fixture.batch.sessionID)
        XCTAssertEqual(decoded.batch.expectedSequence, fixture.batch.expectedSequence)
        XCTAssertEqual(decoded.batch.events, fixture.batch.events)
        XCTAssertEqual(decoded.state, encoded.state)
        if let path = ProcessInfo.processInfo.environment["MIRA_SESSION_LOG_SAMPLE"] {
            let frame = try FileSessionIO.frame(fixture.batch, previous: .initial)
            try (frame.bytes + Data([10])).write(to: URL(fileURLWithPath: path))
        }
    }

    func testAppendAndIndexedDecodeReuseCanonicalStateWithoutFutureReferences() throws {
        let fixture = try makeFixture()
        let first = try SessionLogCodec.encode(fixture.batch)
        let title = SessionContent(kind: .title, bytes: Data("Renamed".utf8))
        let nextEvent = SessionEvent(sequence: Int64(fixture.batch.events.count + 1), occurredAt: fixture.date.addingTimeInterval(1),
                                     fact: .renamed(title: title, revision: 2))
        let secondBatch = SessionBatch(id: UUID(), sessionID: fixture.sessionID,
                                       expectedSequence: Int64(fixture.batch.events.count), events: [nextEvent])
        let second = try SessionLogCodec.encode(secondBatch, previous: first.state)
        XCTAssertFalse(second.records.contains { if case .header = $0 { return true }; return false },
                       "A continued batch must reuse the canonical header")

        let sequential = try SessionLogCodec.decode(second.records, batchID: secondBatch.id,
                                                    sessionID: fixture.sessionID, previous: first.state)
        XCTAssertEqual(sequential.batch.events, secondBatch.events)

        let indexedPrefix = try second.state.forBatch(nextSeq: first.state.nextSeq,
                                                  nextInternalSequence: first.state.nextInternalSequence)
        let indexed = try SessionLogCodec.decode(second.records, batchID: secondBatch.id,
                                                 sessionID: fixture.sessionID, previous: indexedPrefix)
        XCTAssertEqual(indexed.batch.events, secondBatch.events)
        XCTAssertEqual(indexed.state.nextSeq, second.state.nextSeq)
    }

    func testEachCommittedFactCanBeReadFromTheFinalIndexWithoutChangingItsBytes() throws {
        let fixture = try makeFixture()
        var state = SessionLogState.initial
        var transactions: [(SessionBatch, [SessionLogRecord], Int)] = []
        for event in fixture.batch.events {
            let batch = SessionBatch(id: UUID(), sessionID: fixture.sessionID,
                expectedSequence: event.sequence - 1, events: [event])
            let firstSeq = state.nextSeq
            let encoded = try SessionLogCodec.encode(batch, previous: state)
            let decoded = try SessionLogCodec.decode(encoded.records, batchID: batch.id,
                sessionID: fixture.sessionID, previous: state)
            XCTAssertEqual(decoded.batch, batch)
            XCTAssertEqual(decoded.state, encoded.state)
            transactions.append((batch, encoded.records, firstSeq))
            state = encoded.state
        }
        for (batch, records, firstSeq) in transactions {
            let indexed = try SessionLogCodec.decode(records, batchID: batch.id,
                sessionID: fixture.sessionID,
                previous: state.forBatch(nextSeq: firstSeq, nextInternalSequence: batch.expectedSequence))
            XCTAssertEqual(indexed.batch, batch)
        }
    }

    func testRequestWatermarkCannotIncludeItsOwnEvent() throws {
        let fixture = try makeFixture()
        let encoded = try SessionLogCodec.encode(fixture.batch)
        let records = try encoded.records.map { record -> SessionLogRecord in
            guard case .event(let event) = record,
                  case .mira(let name, let data) = event.data, name == "mira/request-start" else { return record }
            return .event(.init(seq: event.seq, time: event.time,
                data: .mira(name: name, data: try logSet(data, path: ["throughSeq"], to: .number(Double(event.seq))))))
        }
        XCTAssertThrowsError(try SessionLogCodec.decode(records, batchID: fixture.batchID, sessionID: fixture.sessionID))
    }

    func testReturningToAnEarlierConfigurationEmitsANewActiveHeaderAndSystemMessage() throws {
        let fixture = try makeFixture()
        let encoded = try SessionLogCodec.encode(fixture.batch)
        let writer = SessionLogWriter(state: encoded.state)
        writer.date = fixture.date
        let alternate = try logDecode(AgentModelRoute.self,
            logSet(logJSON(fixture.route), path: ["modelID"], to: .string("alternate-model")))
        try writer.append(.turnStart(turn: 2))
        try writer.append(.stepStart(turn: 2, step: 1))
        let executionID = ExecutionID()
        let userID = try XCTUnwrap(writer.state.messages.values.first { $0.message.source == .user }?.message.id.value)
        writer.state.userMessages[executionID] = userID
        for route in [fixture.route, alternate, fixture.route] {
            _ = try writer.request(build(sessionID: fixture.sessionID, executionID: executionID,
                stepID: UUID(), userText: "user question", route: route), turn: 2, step: 1)
        }
        let configs = writer.records.compactMap { record -> JSONValue? in
            guard case .event(let event) = record, case .requestHeader(let header, _, _) = event.data else { return nil }
            return header["config"]
        }
        XCTAssertEqual(configs.map { $0["model"] }, [.string("alternate-model"), .string(fixture.route.modelID)])
        let changed = try writer.system("Changed instructions", turn: 2, step: 1)
        try writer.append(.stepEnd(turn: 2, step: 1))
        try writer.append(.turnEnd(turn: 2, reason: .completed))
        try writer.append(.turnStart(turn: 3))
        try writer.append(.stepStart(turn: 3, step: 1))
        let restored = try writer.system("Stable system prompt", turn: 3, step: 1)
        XCTAssertNotEqual(changed, restored)
        XCTAssertNotEqual(restored, encoded.state.activeSystemID)
        XCTAssertEqual(try writer.system("Stable system prompt", turn: 3, step: 2), restored)
        XCTAssertEqual(writer.state.activeSystemID, restored)
    }

    func testControlTimeCannotDisagreeWithItsOriginalCommandTime() throws {
        let fixture = try makeFixture()
        var records = try SessionLogCodec.encode(fixture.batch).records
        guard case .event(let event) = records[1] else { return XCTFail("Missing opening fact") }
        records[1] = .event(.init(seq: event.seq, time: event.time + 1, data: event.data))
        XCTAssertThrowsError(try SessionLogCodec.decode(records, batchID: fixture.batchID, sessionID: fixture.sessionID))
    }

    func testEveryToolOutcomeHasACanonicalResultBeforeTheStepEnds() throws {
        let statuses: [ToolResultStatus] = [.succeeded, .invalidArguments, .notFound, .denied, .timedOut, .cancelledBeforeDispatch, .cancelled, .failed, .outputLimit, .interrupted]
        for status in statuses {
            let fixture = try makeFixture(status: status)
            let encoded = try SessionLogCodec.encode(fixture.batch)
            let events = encoded.records.compactMap { if case .event(let e) = $0 { return e }; return nil }
            let result = try XCTUnwrap(events.first { $0.type == "tool/result" })
            let call = try XCTUnwrap(events.first { $0.type == "tool/call" })
            let end = try XCTUnwrap(events.first { $0.type == "step/end" })
            XCTAssertEqual(result.sourceEventSeqs, [call.seq])
            XCTAssertLessThan(call.seq, result.seq)
            XCTAssertLessThan(result.seq, end.seq)
            XCTAssertEqual(events.filter { $0.type == "user/message" }.count, 1)
            guard case .toolResult(let turn, let step, let message, let error, _) = result.data,
                  case .tool(let sourceCall) = message.source,
                  case .toolResult(let blockCall, let children, let isError) = message.content.first,
                  case .text(let text) = children.first else { return XCTFail("Missing canonical tool result") }
            XCTAssertEqual(turn, 1); XCTAssertEqual(step, 1)
            XCTAssertEqual(sourceCall, blockCall)
            XCTAssertEqual(isError, status == .succeeded ? nil : true)
            let envelope = try SessionCodec.decode(JSONValue.self, from: Data(text.utf8))
            XCTAssertEqual(envelope["status"], .string(status.rawValue))
            XCTAssertEqual(error?.code, status == .succeeded ? nil : "unauthorized")
            XCTAssertEqual(try SessionLogCodec.decode(encoded.records, batchID: fixture.batchID,
                                                     sessionID: fixture.sessionID).batch, fixture.batch)
        }
    }

    func testReplayRejectsMessagesOutsideTheirStepAndMissingToolResults() throws {
        let fixture = try makeFixture()
        let encoded = try SessionLogCodec.encode(fixture.batch)
        var misplaced = encoded.records
        let stepIndex = try XCTUnwrap(misplaced.firstIndex { if case .event(let e) = $0 { return e.type == "step/start" }; return false })
        let systemIndex = try XCTUnwrap(misplaced.firstIndex { if case .event(let e) = $0 { return e.type == "system/message" }; return false })
        guard case .event(let step) = misplaced[stepIndex], case .event(let system) = misplaced[systemIndex] else { return XCTFail() }
        misplaced[stepIndex] = .event(.init(seq: step.seq, time: step.time, data: system.data, surfaceOp: system.surfaceOp))
        misplaced[systemIndex] = .event(.init(seq: system.seq, time: system.time, data: step.data))
        XCTAssertThrowsError(try SessionLogCodec.decode(misplaced, batchID: fixture.batchID, sessionID: fixture.sessionID))

        let missing = encoded.records.map { record -> SessionLogRecord in
            guard case .event(let e) = record, e.type == "tool/result" else { return record }
            return .event(.init(seq: e.seq, time: e.time, data: .unknown(type: "fixture/ignored", data: .object([:])), ignorable: true))
        }
        XCTAssertThrowsError(try SessionLogCodec.decode(missing, batchID: fixture.batchID, sessionID: fixture.sessionID))
        let wrongSource = encoded.records.map { record -> SessionLogRecord in
            guard case .event(let e) = record, e.type == "tool/result" else { return record }
            return .event(.init(seq: e.seq, time: e.time, data: e.data, surfaceOp: e.surfaceOp, sourceEventSeqs: [0]))
        }
        XCTAssertThrowsError(try SessionLogCodec.decode(wrongSource, batchID: fixture.batchID, sessionID: fixture.sessionID))
    }

    func testRepeatedProviderCallIDAcrossTurnsKeepsEachOriginalCallInIndexedReads() throws {
        let one = try makeFixture(callArguments: "{\"q\":\"first\"}")
        let two = try makeFixture(callArguments: "{\"q\":\"second\"}")
        let facts = one.batch.events + two.batch.events.dropFirst().enumerated().map { index, event in
            SessionEvent(id: event.id, sequence: Int64(one.batch.events.count + index + 1), occurredAt: event.occurredAt, fact: event.fact)
        }
        var state = SessionLogState.initial
        var transactions: [(SessionBatch, [SessionLogRecord], Int)] = []
        for event in facts {
            let batch = SessionBatch(id: UUID(), sessionID: one.sessionID, expectedSequence: event.sequence - 1, events: [event])
            let firstSeq = state.nextSeq
            let encoded = try SessionLogCodec.encode(batch, previous: state)
            transactions.append((batch, encoded.records, firstSeq)); state = encoded.state
        }
        for (batch, records, seq) in transactions {
            let decoded = try SessionLogCodec.decode(records, batchID: batch.id, sessionID: one.sessionID,
                previous: state.forBatch(nextSeq: seq, nextInternalSequence: batch.expectedSequence))
            XCTAssertEqual(decoded.batch, batch)
        }
    }

    private struct Fixture {
        let sessionID: ConversationID
        let batchID: UUID
        let date: Date
        let route: AgentModelRoute
        let batch: SessionBatch
    }

    private func makeFixture(status: ToolResultStatus = .succeeded, callArguments: String = "{ \"q\": \"Mira\" }") throws -> Fixture {
        let sessionID = ConversationID(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!)
        let executionID = ExecutionID(UUID())
        let route = AgentModelRoute(id: RouteID(), revision: 1, connectionID: ConnectionID(), connectionRevision: 1,
            modelDescriptorID: ModelDescriptorID(), modelRevision: 1, modelAuthorizationRevision: 1,
            adapter: .init(id: "fixture.adapter", revision: 1), invocationID: "fixture-invocation",
            invocationRevision: 1, endpointID: "fixture-endpoint", modelID: "fixture-model",
            credential: nil, contextWindow: 8_192, maximumOutputTokens: 1_024,
            capabilities: .init(streamsText: true, callsTools: true, producesThinking: true),
            configuration: .object(["temperature": .number(0.2)]))
        let plan = AgentExecutionPlan(runtimeID: UUID(), catalogGeneration: 1, driverID: "fixture.driver",
            driverRevision: 1, instructions: "Stable system prompt", limits: .init(), priority: .foreground, route: route)
        let planReference = try reference(plan, kind: .executionPlan)
        let userID = MessageID(UUID())
        let userReference = SessionContent(id: UUID(), kind: .userText, bytes: Data("user question".utf8))
        let titleReference = SessionContent(id: UUID(), kind: .title, bytes: Data("Session".utf8))
        let date = Date(timeIntervalSince1970: 1_800_144_000)
        let opened = SessionEvent(sequence: 1, occurredAt: date,
                                  fact: .opened(.init(workspaceID: nil, title: titleReference)))
        let admission = SessionAdmission(executionID: executionID, userMessageID: userID, userBody: userReference,
            plan: planReference, hasModelRoute: true, authorizationEpoch: 0, timeZoneIdentifier: "UTC")
        let attemptOne = UUID()
        let attemptTwo = UUID()
        let stepOne = UUID()
        let stepTwo = UUID()
        let firstBuild = build(sessionID: sessionID, executionID: executionID, stepID: stepOne, userText: "user question", route: route)
        let firstRequest = try reference(firstBuild, kind: .request)
        let call = CanonicalToolCall(id: "call-1", name: "lookup", arguments: callArguments)
        let callReference = try reference(call, kind: .toolCall)
        let toolResult = SessionContent(id: UUID(), kind: .toolResult, bytes: Data("{\"answer\":\"ok\"}".utf8))
        let invocationID = UUID()
        let resolution = SessionToolResolution(invocationID: invocationID, status: status, result: status == .succeeded ? toolResult : nil, error: status == .succeeded ? nil : .init(.unauthorized, "Synthetic tool denial."))
        let toolObservation = String(decoding: try SessionCodec.encode(SessionToolObservation.value(resolution)), as: UTF8.self)
        let replay = AgentModelContinuation(adapter: route.adapter, format: "fixture-v1", payload: .object(["token": .string("opaque-fixture-state")]), isComplete: true)
        let firstOutput = AgentModelOutput(blocks: [.init(id: "call-block", content: .toolCall(call))], continuation: replay,
            usage: .init(inputTokens: 12, outputTokens: 3), finishReason: .toolCalls)
        let secondOutput = AgentModelOutput(blocks: [.init(id: "answer-block", content: .text("Final answer"))], continuation: nil,
            usage: .init(inputTokens: 18, outputTokens: 2), finishReason: .stop)
        let secondBuild = build(sessionID: sessionID, executionID: executionID, stepID: stepTwo, userText: "user question", route: route, history: [
            .init(role: .assistant, blocks: firstOutput.blocks, continuation: replay),
            .init(role: .tool, blocks: [.init(id: "result-block", content: .toolResult(callID: call.id, text: toolObservation))])])
        let secondRequest = try reference(secondBuild, kind: .request)
        let firstOutputReference = try reference(firstOutput, kind: .modelOutput)
        let secondOutputReference = try reference(secondOutput, kind: .modelOutput)
        let stream: SessionMessageStream = [
            .chunk(time: 10, chunk: .blockStart(index: 0, blockType: "tool-call")),
            .chunk(time: 11, chunk: .toolCallDelta(index: 0, id: "call-1", name: "lookup", argumentsDelta: call.arguments)),
            .chunk(time: 12, chunk: .blockEnd(index: 0, block: .toolCall(id: "call-1", name: "lookup", arguments: call.arguments))),
            .chunk(time: 13, chunk: .finish(reason: .toolCalls)),
        ]
        let secondStream: SessionMessageStream = [
            .chunk(time: 20, chunk: .blockStart(index: 0, blockType: "text")),
            .textChunks(time0: 21, index: 0, dt: [], texts: ["Final answer"]),
            .chunk(time: 22, chunk: .blockEnd(index: 0, block: .text("Final answer"))),
            .chunk(time: 23, chunk: .finish(reason: .stop)),
        ]
        var sequence: Int64 = 2
        func event(_ fact: SessionFact) -> SessionEvent {
            defer { sequence += 1 }
            return SessionEvent(sequence: sequence, occurredAt: date.addingTimeInterval(TimeInterval(sequence)), fact: fact)
        }
        let events: [SessionEvent] = [opened,
            event(.admitted(admission)), event(.phaseChanged(executionID: executionID, phase: .preparing)),
            event(.attemptStarted(.init(id: attemptOne, executionID: executionID, stepID: stepOne, stepIndex: 1, attemptIndex: 1, request: firstRequest))),
            event(.attemptResolved(.init(attemptID: attemptOne, status: .completed, output: firstOutputReference, usage: firstOutput.usage, stream: stream))),
            event(.toolProposed(.init(id: invocationID, attemptID: attemptOne, modelOrder: 0, toolName: "lookup", effect: .read, call: callReference))),
            event(.phaseChanged(executionID: executionID, phase: .waitingForTools)),
            event(.toolResolved(resolution)),
            event(.phaseChanged(executionID: executionID, phase: .preparing)),
            event(.attemptStarted(.init(id: attemptTwo, executionID: executionID, stepID: stepTwo, stepIndex: 2, attemptIndex: 1, request: secondRequest))),
            event(.attemptResolved(.init(attemptID: attemptTwo, status: .completed, output: secondOutputReference, usage: secondOutput.usage, stream: secondStream))),
            event(.phaseChanged(executionID: executionID, phase: .settling)),
            event(.finished(.init(executionID: executionID, status: .completed, assistantMessageID: MessageID(attemptTwo), answer: SessionContent(id: UUID(), kind: .visibleAnswer, bytes: Data("Final answer".utf8)), usage: secondOutput.usage)))
        ]
        let batchID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        return Fixture(sessionID: sessionID, batchID: batchID, date: date, route: route,
                       batch: SessionBatch(id: batchID, sessionID: sessionID, expectedSequence: 0, events: events))
    }

    private func build(sessionID: ConversationID, executionID: ExecutionID, stepID: UUID,
                       userText: String, route: AgentModelRoute, history: [AgentModelMessage] = []) -> AgentSessionRequest {
        let request = AgentContextRequest(sessionID: sessionID, executionID: executionID, workspaceID: nil,
            userText: userText, authorizationEpoch: 0, destination: .model(route))
        let input = AgentModelInput(stepID: stepID, executionID: executionID, instructions: "Stable system prompt",
            messages: [.init(role: .user, blocks: [.init(id: "user-block", content: .text(userText))])] + history, tools: [
                .init(name: "lookup", description: "Look up fixture data.", inputSchema: .object(["type": .string("object")]))])
        let prepared = AgentPreparedModelRequest(adapter: route.adapter, input: input,
            wirePayload: .object(["prompt": .string(userText), "instructions": .string("Stable system prompt"),
                "history": .array(history.map { .object(["role": .string($0.role.rawValue), "text": .string($0.text), "thinking": .string($0.thinkingText)]) })]), estimatedInputTokens: 1)
        return AgentSessionRequest(AgentContextBuild(request: request, prepared: prepared, inheritedSources: [], evidence: [], omissions: []))
    }

    private func reference<T: Encodable>(_ value: T, kind: SessionContentKind) throws -> SessionContent {
        SessionContent(id: UUID(), kind: kind, bytes: try SessionCodec.encode(value))
    }
}
