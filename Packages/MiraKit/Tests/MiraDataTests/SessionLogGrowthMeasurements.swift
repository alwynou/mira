import Foundation
import Testing
@testable import MiraCore
@testable import MiraData

/// Opt-in measurements for the inline session log.  The fixture deliberately
/// goes through FileSessionLibrary and valid model/request/turn facts so the
/// result describes the journal that the product actually writes.
@Suite("Session log growth measurements", .serialized)
struct SessionLogGrowthMeasurements {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MIRA_SESSION_LOG_GROWTH"] == "1"))
    func measureInlineJournalGrowthAndRoundTrips() async throws {
        var rows: [GrowthRow] = []
        for turns in [1, 10, 100] {
            let fixture = try await GrowthFixture.make()
            let row: GrowthRow
            do {
                try await fixture.append(turns: turns)
                row = try await fixture.measure(turns: turns)
            } catch {
                await fixture.close()
                throw error
            }
            await fixture.close()
            rows.append(row)
        }

        let result = GrowthReport(rows: rows, generatedAt: ISO8601DateFormatter().string(from: Date()))
        let data = try SessionCodec.encode(result)
        let output = URL(fileURLWithPath: "/tmp/mira-session-log-growth.json")
        try data.write(to: output, options: .atomic)
        print("MIRA_SESSION_LOG_GROWTH " + String(decoding: data, as: UTF8.self))

        #expect(rows.map(\.turns) == [1, 10, 100])
        #expect(rows.allSatisfy { $0.rawBytes > 0 && $0.compressedBytes > 0 })
        #expect(rows.allSatisfy { $0.requestCount == $0.requestEvidenceRoundTrips })
        #expect(rows.allSatisfy { $0.payloadDirectoryPresent == false })
        #expect(rows[1].rawBytes > rows[0].rawBytes)
        #expect(rows[2].rawBytes > rows[1].rawBytes)
    }
}

private struct GrowthReport: Encodable {
    let rows: [GrowthRow]
    let generatedAt: String
}

private struct GrowthRow: Encodable {
    let turns: Int
    let rawBytes: Int
    let compressedBytes: Int
    let indexBytes: Int
    let checkpointBytes: Int
    let lineCount: Int
    let commitMarkers: Int
    let requestCount: Int
    let requestEvidenceRoundTrips: Int
    let streamChunkCount: Int
    let metadataRecordCount: Int
    let stableSystemMessageCount: Int
    let payloadDirectoryPresent: Bool
    let requestContentDefinitions: Int
    let requestContentReferences: Int
}

private final class GrowthFixture {
    let root: URL
    let library: FileSessionLibrary
    let sessionID: ConversationID
    private var nextSequence: Int64 = 0
    private let route: AgentModelRoute
    private let baseDate = Date(timeIntervalSince1970: 1_800_000_000)
    private var conversationHistory: [AgentModelMessage] = []
    private var expectedRequests: [UUID: AgentSessionRequest] = [:]

    private init(root: URL, library: FileSessionLibrary, sessionID: ConversationID,
                 route: AgentModelRoute) {
        self.root = root; self.library = library; self.sessionID = sessionID; self.route = route
    }

    static func make() async throws -> GrowthFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mira-session-log-growth-\(UUID().uuidString)")
        let library = try FileSessionLibrary(directory: root)
        let route = AgentModelRoute(id: RouteID(), revision: 1, connectionID: ConnectionID(),
            connectionRevision: 1, modelDescriptorID: ModelDescriptorID(), modelRevision: 1,
            modelAuthorizationRevision: 1, adapter: .init(id: "fixture.adapter", revision: 1),
            invocationID: "fixture-invocation", invocationRevision: 1,
            endpointID: "fixture-endpoint", modelID: "fixture-model",
            credential: nil, contextWindow: 1_000_000, maximumOutputTokens: 4_096,
            capabilities: .init(streamsText: true, callsTools: true, producesThinking: true),
            configuration: .object(["temperature": .number(0.2)]))
        return GrowthFixture(root: root, library: library, sessionID: ConversationID(), route: route)
    }

    func append(turns: Int) async throws {
        for turn in 1...turns {
            if turn == 1 {
                try await appendToolTurn(turn: turn, includeOpened: true)
            } else if turn == 3 {
                try await appendRetryTurn(turn: turn)
            } else {
                try await appendNormalTurn(turn: turn, includeOpened: false)
            }
        }
    }

    func measure(turns: Int) async throws -> GrowthRow {
        // Include the durable cache after its normal flush boundary, rather
        // than reporting zero for workloads below the automatic write threshold.
        try await library.flush()
        let journal = root.appendingPathComponent("sessions").appendingPathComponent(sessionID.rawValue.uuidString + ".jsonl")
        let bytes = try Data(contentsOf: journal)
        try bytes.write(to: URL(fileURLWithPath: "/tmp/mira-session-log-growth-\(turns).jsonl"), options: .atomic)
        let lines = bytes.split(separator: 10, omittingEmptySubsequences: true)
        let values = try lines.map { try JSONSerialization.jsonObject(with: Data($0)) as! [String: Any] }
        let compressed = try gzip(bytes)
        let requestValues = values.filter { $0["type"] as? String == "mira/request-start" }
        let requestContents = requestValues.compactMap { ($0["data"] as? [String: Any])?["request"] as? [String: Any] }
        let requestDefinitions = requestContents.filter { $0["value"] != nil }.count
        let requestReferences = requestContents.filter { $0["ref"] != nil }.count
        var roundTrips = 0
        var decodedAttemptIDs: Set<UUID> = []
        let batches = try await library.read(sessionID: sessionID, after: 0, limit: SessionFormatLimits.maximumReadBatches)
        for batch in batches {
            for event in batch.events {
                if case .attemptStarted(let attempt) = event.fact {
                    let decoded = try SessionCodec.decode(AgentSessionRequest.self, from: attempt.request.bytes)
                    let expected = try #require(expectedRequests[attempt.id])
                    #expect(decoded == expected)
                    decodedAttemptIDs.insert(attempt.id)
                    roundTrips += 1
                }
            }
        }
        #expect(decodedAttemptIDs == Set(expectedRequests.keys))
        let types = values.compactMap { $0["type"] as? String }
        let metadata = values.filter {
            guard let type = $0["type"] as? String else { return false }
            return type == "session" || type == "system/message" || type == "mira/route-snapshot"
        }.count
        let streamChunks = values.reduce(into: 0) { count, value in count += streamCount(value) }
        let payloadDirectory = FileManager.default.fileExists(atPath: root.appendingPathComponent("payloads").path)
        let indexBytes = try fileSize(root.appendingPathComponent("indexes").appendingPathComponent(sessionID.rawValue.uuidString + ".index"))
        let checkpointBytes = try fileSize(root.appendingPathComponent("checkpoints").appendingPathComponent(sessionID.rawValue.uuidString + ".state"))
        #expect(types.filter { $0 == "system/message" }.count == 1)
        #expect(types.filter { $0 == "mira/route-snapshot" }.count == 1)
        #expect(types.filter { $0 == "request/header" }.count == 1)
        #expect(types.filter { $0 == "request/context" }.count == 1)
        return GrowthRow(turns: turns, rawBytes: bytes.count, compressedBytes: compressed,
            indexBytes: indexBytes, checkpointBytes: checkpointBytes,
            lineCount: lines.count, commitMarkers: types.filter { $0 == "mira/commit" }.count,
            requestCount: requestValues.count, requestEvidenceRoundTrips: roundTrips,
            streamChunkCount: streamChunks,
            metadataRecordCount: metadata,
            stableSystemMessageCount: types.filter { $0 == "system/message" }.count,
            payloadDirectoryPresent: payloadDirectory, requestContentDefinitions: requestDefinitions,
            requestContentReferences: requestReferences)
    }

    func close() async {
        try? await library.close()
        try? FileManager.default.removeItem(at: root)
    }

    private func appendNormalTurn(turn: Int, includeOpened: Bool) async throws {
        let executionID = ExecutionID(), messageID = MessageID()
        let batchID = UUID()
        let prompt = "Stable synthetic prompt turn \(turn)"
        let body = try await library.stage(Data(prompt.utf8),
                                           sessionID: sessionID, batchID: batchID, kind: .userText)
        let title = includeOpened ? try await library.stage(Data("Growth fixture".utf8), sessionID: sessionID,
                                                            batchID: batchID, kind: .title) : nil
        let plan = try await stagePlan(batchID: batchID)
        let attemptID = UUID(), stepID = UUID()
        let build = makeBuild(executionID: executionID, stepID: stepID, text: prompt,
                              history: conversationHistory)
        expectedRequests[attemptID] = build
        let request = try await stageJSON(build, batchID: batchID, kind: .request)
        let output = AgentModelOutput(blocks: [.init(id: "answer-\(turn)", content: .text("Stable answer \(turn)"))],
            continuation: nil, usage: .init(inputTokens: 12, outputTokens: 3), finishReason: .stop)
        let outputReference = try await stageJSON(output, batchID: batchID, kind: .modelOutput)
        let answer = try await library.stage(Data("Stable answer \(turn)".utf8), sessionID: sessionID,
                                             batchID: batchID, kind: .visibleAnswer)
        var facts: [SessionFact] = []
        if let title { facts.append(.opened(.init(workspaceID: nil, title: title))) }
        facts += [.admitted(.init(executionID: executionID, userMessageID: messageID, userBody: body,
                                  plan: plan, hasModelRoute: true, authorizationEpoch: 0, timeZoneIdentifier: "UTC")),
                  .phaseChanged(executionID: executionID, phase: .preparing),
                  .attemptStarted(.init(id: attemptID, executionID: executionID, stepID: stepID,
                                       stepIndex: 1, attemptIndex: 1, request: request)),
                  .attemptResolved(.init(attemptID: attemptID, status: .completed, output: outputReference,
                                         usage: output.usage, stream: textStream("Stable answer \(turn)"))),
                  .phaseChanged(executionID: executionID, phase: .settling),
                  .finished(.init(executionID: executionID, status: .completed,
                                  assistantMessageID: MessageID(attemptID), answer: answer, usage: output.usage))]
        try await append(facts, batchID: batchID)
        conversationHistory += [userMessage(prompt), output.message]
    }

    private func appendToolTurn(turn: Int, includeOpened: Bool) async throws {
        let executionID = ExecutionID(), messageID = MessageID(), batchID = UUID()
        let prompt = "Stable synthetic prompt turn \(turn)"
        let body = try await library.stage(Data(prompt.utf8), sessionID: sessionID, batchID: batchID, kind: .userText)
        let title = includeOpened ? try await library.stage(Data("Growth fixture".utf8), sessionID: sessionID,
                                                            batchID: batchID, kind: .title) : nil
        let plan = try await stagePlan(batchID: batchID)
        let firstAttempt = UUID(), firstStep = UUID(), secondAttempt = UUID(), secondStep = UUID()
        let call = CanonicalToolCall(id: "lookup-\(turn)", name: "lookup", arguments: "{\"q\":\"Mira\"}")
        let firstBuild = makeBuild(executionID: executionID, stepID: firstStep, text: prompt,
                                   history: conversationHistory)
        expectedRequests[firstAttempt] = firstBuild
        let firstRequest = try await stageJSON(firstBuild, batchID: batchID, kind: .request)
        let firstOutput = AgentModelOutput(blocks: [.init(id: "call-\(turn)", content: .toolCall(call))], continuation: nil,
            usage: .init(inputTokens: 12, outputTokens: 3), finishReason: .toolCalls)
        let firstOutputReference = try await stageJSON(firstOutput, batchID: batchID, kind: .modelOutput)
        let callReference = try await stageJSON(call, batchID: batchID, kind: .toolCall)
        let observation = "{\"authority\":\"untrusted_tool_observation\",\"content\":{\"answer\":\"ok\"},\"status\":\"succeeded\"}"
        let toolResult = try await library.stage(Data("{\"answer\":\"ok\"}".utf8), sessionID: sessionID,
                                                 batchID: batchID, kind: .toolResult)
        let toolMessage = AgentModelMessage(role: .tool, blocks: [
            .init(id: "result-\(turn)", content: .toolResult(callID: call.id, text: observation))])
        let secondBuild = makeBuild(executionID: executionID, stepID: secondStep, text: prompt,
                                    history: conversationHistory,
                                    currentRound: [firstOutput.message, toolMessage])
        expectedRequests[secondAttempt] = secondBuild
        let secondRequest = try await stageJSON(secondBuild, batchID: batchID, kind: .request)
        let secondOutput = AgentModelOutput(blocks: [.init(id: "answer-\(turn)", content: .text("Stable tool answer \(turn)"))],
            continuation: nil, usage: .init(inputTokens: 18, outputTokens: 2), finishReason: .stop)
        let secondOutputReference = try await stageJSON(secondOutput, batchID: batchID, kind: .modelOutput)
        let answer = try await library.stage(Data("Stable tool answer \(turn)".utf8), sessionID: sessionID,
                                             batchID: batchID, kind: .visibleAnswer)
        let invocationID = UUID()
        var facts: [SessionFact] = []
        if let title { facts.append(.opened(.init(workspaceID: nil, title: title))) }
        facts += [.admitted(.init(executionID: executionID, userMessageID: messageID, userBody: body,
                                  plan: plan, hasModelRoute: true, authorizationEpoch: 0, timeZoneIdentifier: "UTC")),
                  .phaseChanged(executionID: executionID, phase: .preparing),
                  .attemptStarted(.init(id: firstAttempt, executionID: executionID, stepID: firstStep,
                                       stepIndex: 1, attemptIndex: 1, request: firstRequest)),
                  .attemptResolved(.init(attemptID: firstAttempt, status: .completed, output: firstOutputReference,
                                         usage: firstOutput.usage, stream: toolStream(call: call))),
                  .toolProposed(.init(id: invocationID, attemptID: firstAttempt, modelOrder: 0,
                                      toolName: call.name, effect: .read, call: callReference)),
                  .phaseChanged(executionID: executionID, phase: .waitingForTools),
                  .toolResolved(.init(invocationID: invocationID, status: .succeeded, result: toolResult)),
                  .phaseChanged(executionID: executionID, phase: .preparing),
                  .attemptStarted(.init(id: secondAttempt, executionID: executionID, stepID: secondStep,
                                       stepIndex: 2, attemptIndex: 1, request: secondRequest)),
                  .attemptResolved(.init(attemptID: secondAttempt, status: .completed, output: secondOutputReference,
                                         usage: secondOutput.usage, stream: textStream("Stable tool answer \(turn)"))),
                  .phaseChanged(executionID: executionID, phase: .settling),
                  .finished(.init(executionID: executionID, status: .completed,
                                  assistantMessageID: MessageID(secondAttempt), answer: answer, usage: secondOutput.usage))]
        try await append(facts, batchID: batchID)
        conversationHistory += [userMessage(prompt), firstOutput.message, toolMessage, secondOutput.message]
    }

    private func appendRetryTurn(turn: Int) async throws {
        let sourceID = ExecutionID(), retryID = ExecutionID(), messageID = MessageID(), batchID = UUID()
        let prompt = "Stable synthetic prompt turn \(turn)"
        let body = try await library.stage(Data(prompt.utf8), sessionID: sessionID, batchID: batchID, kind: .userText)
        let plan = try await stagePlan(batchID: batchID)
        let retryPlan = try await stagePlan(batchID: batchID)
        let failedAttempt = UUID(), failedStep = UUID(), retryAttempt = UUID(), retryStep = UUID()
        let failedBuild = makeBuild(executionID: sourceID, stepID: failedStep, text: prompt,
                                    history: conversationHistory)
        let retryBuild = makeBuild(executionID: retryID, stepID: retryStep, text: prompt,
                                   history: conversationHistory)
        expectedRequests[failedAttempt] = failedBuild
        expectedRequests[retryAttempt] = retryBuild
        let failedRequest = try await stageJSON(failedBuild, batchID: batchID, kind: .request)
        let retryRequest = try await stageJSON(retryBuild, batchID: batchID, kind: .request)
        let error = try await library.stage(SessionCodec.encode(JSONValue.string("Synthetic retry")),
                                            sessionID: sessionID, batchID: batchID, kind: .error)
        let output = AgentModelOutput(blocks: [.init(id: "retry-answer", content: .text("Stable retry answer"))],
            continuation: nil, usage: .init(inputTokens: 14, outputTokens: 3), finishReason: .stop)
        let outputReference = try await stageJSON(output, batchID: batchID, kind: .modelOutput)
        let answer = try await library.stage(Data("Stable retry answer".utf8), sessionID: sessionID,
                                             batchID: batchID, kind: .visibleAnswer)
        let facts: [SessionFact] = [
            .admitted(.init(executionID: sourceID, userMessageID: messageID, userBody: body,
                            plan: plan, hasModelRoute: true, authorizationEpoch: 0, timeZoneIdentifier: "UTC")),
            .phaseChanged(executionID: sourceID, phase: .preparing),
            .attemptStarted(.init(id: failedAttempt, executionID: sourceID, stepID: failedStep,
                                 stepIndex: 1, attemptIndex: 1, request: failedRequest)),
            .attemptResolved(.init(attemptID: failedAttempt, status: .failed, error: error,
                                   usage: .init(), stream: textStream("Synthetic retry"))),
            .phaseChanged(executionID: sourceID, phase: .settling),
            .finished(.init(executionID: sourceID, status: .failed, error: error)),
            .admitted(.init(executionID: retryID, userMessageID: messageID, retryOfExecutionID: sourceID,
                            userBody: nil, plan: retryPlan, hasModelRoute: true, authorizationEpoch: 0,
                            timeZoneIdentifier: "UTC")),
            .retrySuperseded(.init(sourceExecutionID: sourceID, retryExecutionID: retryID)),
            .phaseChanged(executionID: retryID, phase: .preparing),
            .attemptStarted(.init(id: retryAttempt, executionID: retryID, stepID: retryStep,
                                 stepIndex: 1, attemptIndex: 1, request: retryRequest)),
            .attemptResolved(.init(attemptID: retryAttempt, status: .completed, output: outputReference,
                                   usage: output.usage, stream: textStream("Stable retry answer"))),
            .phaseChanged(executionID: retryID, phase: .settling),
            .finished(.init(executionID: retryID, status: .completed,
                            assistantMessageID: MessageID(retryAttempt), answer: answer, usage: output.usage))]
        try await append(facts, batchID: batchID)
        conversationHistory += [userMessage(prompt), output.message]
    }

    private func append(_ facts: [SessionFact], batchID: UUID) async throws {
        let events = facts.enumerated().map { offset, fact in
            SessionEvent(sequence: nextSequence + Int64(offset) + 1,
                         occurredAt: baseDate.addingTimeInterval(TimeInterval(nextSequence + Int64(offset))), fact: fact)
        }
        let batch = SessionBatch(id: batchID, sessionID: sessionID, expectedSequence: nextSequence, events: events)
        switch await library.append(batch) {
        case .committed(let cursor): nextSequence = cursor.sequence
        case .notCommitted(let error), .indeterminate(let error): throw error
        }
    }

    private func stagePlan(batchID: UUID) async throws -> SessionContent {
        try await stageJSON(AgentExecutionPlan(runtimeID: UUID(), catalogGeneration: 1,
            driverID: "fixture.driver", driverRevision: 1, instructions: "Stable system prompt",
            limits: .init(), priority: .foreground, route: route), batchID: batchID, kind: .executionPlan)
    }

    private func stageJSON<T: Encodable>(_ value: T, batchID: UUID, kind: SessionContentKind) async throws -> SessionContent {
        try await library.stage(SessionCodec.encode(value), sessionID: sessionID, batchID: batchID, kind: kind)
    }

    private func makeBuild(executionID: ExecutionID, stepID: UUID, text: String,
                           history: [AgentModelMessage] = [],
                           currentRound: [AgentModelMessage] = []) -> AgentSessionRequest {
        let request = AgentContextRequest(sessionID: sessionID, executionID: executionID, workspaceID: nil,
            userText: text, authorizationEpoch: 0, destination: .model(route))
        let messages = history + [userMessage(text)] + currentRound
        let input = AgentModelInput(stepID: stepID, executionID: executionID,
            instructions: "Stable system prompt",
            messages: messages,
            tools: [.init(name: "lookup", description: "Look up fixture data.",
                          inputSchema: .object(["type": .string("object")]))])
        let prepared = AgentPreparedModelRequest(adapter: route.adapter, input: input,
            wirePayload: .object(["prompt": .string(text), "instructions": .string("Stable system prompt"),
                                  "messages": .array(messages.map(providerMessageJSON))]),
            estimatedInputTokens: 1)
        return AgentSessionRequest(AgentContextBuild(request: request, prepared: prepared, inheritedSources: [], evidence: [], omissions: []))
    }

    private func userMessage(_ text: String) -> AgentModelMessage {
        AgentModelMessage(role: .user, blocks: [.init(id: "user-block", content: .text(text))])
    }

    private func providerMessageJSON(_ message: AgentModelMessage) -> JSONValue {
        .object([
            "role": .string(message.role.rawValue),
            "blocks": .array(message.blocks.map { block in
                switch block.content {
                case .text(let value):
                    return .object(["id": .string(block.id), "type": .string("text"), "text": .string(value)])
                case .thinking(let value):
                    return .object(["id": .string(block.id), "type": .string("thinking"), "text": .string(value)])
                case .toolCall(let call):
                    return .object(["id": .string(block.id), "type": .string("toolCall"),
                                    "callID": .string(call.id), "name": .string(call.name),
                                    "arguments": .string(call.arguments)])
                case .toolResult(let callID, let text):
                    return .object(["id": .string(block.id), "type": .string("toolResult"),
                                    "callID": .string(callID), "text": .string(text)])
                }
            }),
            "continuation": message.continuation.flatMap { try? SessionCodec.decode(JSONValue.self, from: SessionCodec.encode($0)) } ?? .null
        ])
    }

    private func textStream(_ text: String) -> [SessionMessageStreamRecord] {
        [.chunk(time: 1, chunk: .blockStart(index: 0, blockType: "text")),
         .textChunks(time0: 2, index: 0, dt: [], texts: [text]),
         .chunk(time: 3, chunk: .blockEnd(index: 0, block: .text(text))),
         .chunk(time: 4, chunk: .finish(reason: .stop))]
    }

    private func toolStream(call: CanonicalToolCall) -> [SessionMessageStreamRecord] {
        [.chunk(time: 1, chunk: .blockStart(index: 0, blockType: "tool-call")),
         .chunk(time: 2, chunk: .toolCallDelta(index: 0, id: call.id, name: call.name, argumentsDelta: call.arguments)),
         .chunk(time: 3, chunk: .blockEnd(index: 0, block: .toolCall(id: call.id, name: call.name, arguments: call.arguments))),
         .chunk(time: 4, chunk: .finish(reason: .toolCalls))]
    }

    private func streamCount(_ value: Any) -> Int {
        if let dictionary = value as? [String: Any] {
            return dictionary.reduce(0) { total, entry in
                if entry.key == "stream", let stream = entry.value as? [Any] {
                    return total + stream.count
                }
                return total + streamCount(entry.value)
            }
        }
        if let array = value as? [Any] { return array.reduce(0) { $0 + streamCount($1) } }
        return 0
    }

    private func fileSize(_ url: URL) throws -> Int {
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.intValue ?? 0
    }

    private func gzip(_ data: Data) throws -> Int {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mira-session-log-gzip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("source.jsonl")
        let compressedFile = directory.appendingPathComponent("source.jsonl.gz")
        defer { try? FileManager.default.removeItem(at: directory) }
        try data.write(to: source, options: .atomic)
        FileManager.default.createFile(atPath: compressedFile.path, contents: nil)
        let output = try FileHandle(forWritingTo: compressedFile)
        process.arguments = ["-c", source.path]
        process.standardOutput = output; process.standardError = Pipe()
        try process.run()
        process.waitUntilExit(); try output.close()
        guard process.terminationStatus == 0 else { throw MiraError(.storage, "gzip failed") }
        return try Data(contentsOf: compressedFile).count
    }
}
