import Foundation

/// Writes shared DSH events and the minimal Mira facts needed for durable execution.
final class SessionLogWriter {
    var state: SessionLogState
    var records: [SessionLogRecord] = []
    var date = Date(timeIntervalSince1970: 0)
    init(state: SessionLogState) { self.state = state }
    @discardableResult
    func append(_ data: SessionLogEventData, surface: SessionLogSurfaceOperation? = nil,
                sources: [Int]? = nil) throws -> Int {
        let seq = state.nextSeq
        let event = SessionLogEvent(seq: seq, time: try logTime(date), data: data, surfaceOp: surface, sourceEventSeqs: sources)
        try event.validate()
        try state.trace.apply(event)
        records.append(.event(event))
        state.nextSeq += 1
        switch data {
        case .userMessage(let message):
            state.messages[message.id.value] = .init(seq: seq, message: message)
        case .systemMessage(_, _, let message):
            state.messages[message.id.value] = .init(seq: seq, message: message)
            state.activeSystemID = message.id.value
        case .assistantMessage(_, _, let message, let stream, _, _):
            state.messages[message.id.value] = .init(seq: seq, message: message)
            state.streams[seq] = stream
        case .assistantAttempt(_, _, let stream): state.streams[seq] = stream
        case .toolResult(_, _, let message, _, _): state.messages[message.id.value] = .init(seq: seq, message: message)
        case .toolCall(_, _, let id, let name, let arguments): state.toolCalls[seq] = .init(id: id, name: name, arguments: arguments)
        case .stepStart(let turn, let step): state.openSteps[turn] = step
        case .stepEnd(let turn, _): state.openSteps[turn] = nil
        default: break
        }
        return seq
    }
    func message(_ message: SessionMessage, turn: Int, step: Int) throws {
        if let previous = state.messages[message.id.value] {
            guard try SessionCodec.encode(previous.message) == SessionCodec.encode(message) else { throw SessionLogCodecError.duplicateIdentity }; return
        }
        if message.role == .system { try append(.systemMessage(turn: turn, step: step, message: message), surface: .append) }
        else { try append(.userMessage(message), surface: .append) }
    }
    func system(_ text: String, turn: Int, step: Int) throws -> String {
        if let id = state.activeSystemID, let entry = state.messages[id],
           SessionLogReader.messageText(entry.message, field: "text").map({ $0.utf8.elementsEqual(text.utf8) }) == true { return id }
        let id = "system-" + SessionContentDigest.sha256(Data(text.utf8)) + "-\(state.nextSeq)"
        try message(.init(id: .init(id), role: .system, content: [.text(text)], source: .plugin(plugin: "mira-system-prompt")), turn: turn, step: step)
        return id
    }
    func route(_ route: AgentModelRoute?) throws -> JSONValue {
        guard let route else { return .null }
        let id = SessionContentDigest.sha256(try SessionCodec.encode(route))
        if state.routes[id] == nil {
            let seq = try append(.mira(name: "mira/route-snapshot", data: .object(["id": .string(id), "route": try logJSON(route)])))
            state.routes[id] = .init(seq: seq, route: route)
        }
        return .string(id)
    }
    func write(_ event: SessionEvent) throws {
        date = event.occurredAt
        var fields: [String: JSONValue] = [:]
        let name: String
        switch event.fact {
        case .opened(let value):
            name = "mira/session-opened"; fields = ["workspaceId": try logJSON(value.workspaceID), "title": try content(value.title)]
        case .renamed(let title, let revision):
            name = "mira/session-renamed"; fields = ["title": try content(title), "revision": .number(Double(revision))]
        case .archived(let revision): name = "mira/session-archived"; fields = ["revision": .number(Double(revision))]
        case .modelSelectionChanged(let selection, let revision):
            name = "mira/model-selection"; fields = ["selection": try logJSON(selection), "expectedRevision": .number(Double(revision))]
        case .admitted(let value):
            name = "mira/turn-admitted"
            let turn = (state.turns.values.max() ?? 0) + 1
            let plan = try SessionCodec.decode(AgentExecutionPlan.self, from: value.plan.bytes)
            state.turns[value.executionID] = turn; state.plans[value.executionID] = plan
            try append(.turnStart(turn: turn))
            let routeRef = try route(plan.route)
            try append(.stepStart(turn: turn, step: 1))
            state.userMessages[value.executionID] = value.userMessageID.rawValue.uuidString
            let systemRef = try system(plan.instructions, turn: turn, step: 1)
            if let body = value.userBody {
                let text = try text(body.bytes)
                try message(.init(id: .init(value.userMessageID.rawValue.uuidString), role: .user, content: [.text(text)], source: .user), turn: turn, step: 1)
            }
            var planJSON = try logJSON(plan)
            planJSON = try logSet(planJSON, path: ["instructions"], to: .null)
            if plan.route != nil { planJSON = try logSet(planJSON, path: ["route"], to: .null) }
            let representation = JSONValue.object(["plan": planJSON, "system": .string(systemRef), "route": routeRef])
            fields = ["turn": .number(Double(turn)), "executionId": .string(value.executionID.rawValue.uuidString),
                      "userMessageId": .string(value.userMessageID.rawValue.uuidString), "retryOfExecutionId": try logJSON(value.retryOfExecutionID?.rawValue),
                      "userBody": try content(value.userBody, representation: textReference(value.userMessageID.rawValue.uuidString, field: "text")), "plan": try content(value.plan, representation: representation),
                      "hasModelRoute": .bool(value.hasModelRoute), "authorizationEpoch": .number(Double(value.authorizationEpoch)),
                      "timeZoneIdentifier": .string(value.timeZoneIdentifier), "modelSelectionRevision": .number(Double(value.modelSelectionRevision))]
        case .phaseChanged(let executionID, let phase):
            name = "mira/phase-changed"; fields = ["executionId": .string(executionID.rawValue.uuidString), "phase": try logJSON(phase)]
        case .attemptStarted(let attempt):
            name = "mira/request-start"
            guard let turn = state.turns[attempt.executionID] else { throw SessionLogCodecError.missingAssociation }
            let build = try SessionCodec.decode(AgentSessionRequest.self, from: attempt.request.bytes)
            if state.openSteps[turn] != attempt.stepIndex {
                if let previous = state.openSteps[turn] { try append(.stepEnd(turn: turn, step: previous)) }
                try append(.stepStart(turn: turn, step: attempt.stepIndex))
                state.openSteps[turn] = attempt.stepIndex
            }
            let request = try request(build, turn: turn, step: attempt.stepIndex)
            fields = ["turn": .number(Double(turn)), "step": .number(Double(attempt.stepIndex)), "attempt": .string(attempt.id.uuidString),
                      "executionId": .string(attempt.executionID.rawValue.uuidString), "stepId": .string(attempt.stepID.uuidString),
                      "attemptIndex": .number(Double(attempt.attemptIndex)), "throughSeq": .number(Double(state.nextSeq - 1)),
                      "request": try content(attempt.request, representation: request)]
            state.attempts[attempt.id] = attempt
        case .attemptResolved(let resolution):
            name = "mira/attempt-resolved"
            guard let attempt = state.attempts[resolution.attemptID], let turn = state.turns[attempt.executionID] else { throw SessionLogCodecError.missingAssociation }
            var outputRef: JSONValue = .null
            let streamSeq: Int
            if let output = resolution.output {
                let value = try SessionCodec.decode(AgentModelOutput.self, from: output.bytes)
                let build = try SessionCodec.decode(AgentSessionRequest.self, from: attempt.request.bytes)
                guard let route = build.request.destination.modelRoute else { throw SessionLogCodecError.missingAssociation }
                let replay = try value.continuation.map(logJSON)
                let message = SessionMessage(id: .init(resolution.attemptID.uuidString), role: .assistant,
                    content: value.blocks.map(SessionMessageContent.init), source: .model(provider: route.adapter.id, model: route.modelID, replayState: replay))
                streamSeq = try append(.assistantMessage(turn: turn, step: attempt.stepIndex, message: message, stream: resolution.stream,
                    usage: SessionMessageUsage(tokenUsage: resolution.usage), interrupted: resolution.status == .interrupted ? true : nil), surface: .append)
                outputRef = try content(output, representation: .object(["output": .object([
                    "message": .string(message.id.value), "blockIds": try logJSON(value.blocks.map(\.id)),
                    "usage": try logJSON(value.usage), "finishReason": try logJSON(value.finishReason)])]))
            } else { streamSeq = try append(.assistantAttempt(turn: turn, step: attempt.stepIndex, stream: resolution.stream)) }
            fields = ["attempt": .string(resolution.attemptID.uuidString), "turn": .number(Double(turn)), "step": .number(Double(attempt.stepIndex)),
                      "streamSeq": .number(Double(streamSeq)), "status": try logJSON(resolution.status), "output": outputRef, "error": try content(resolution.error), "usage": try logJSON(resolution.usage)]
        case .toolProposed(let invocation):
            name = "mira/tool-proposed"
            guard let attempt = state.attempts[invocation.attemptID], let turn = state.turns[attempt.executionID] else { throw SessionLogCodecError.missingAssociation }
            let call = try SessionCodec.decode(CanonicalToolCall.self, from: invocation.call.bytes)
            let callSeq = try append(.toolCall(turn: turn, step: attempt.stepIndex, callID: call.id, name: call.name, arguments: call.arguments))
            fields = ["invocationId": .string(invocation.id.uuidString), "attempt": .string(invocation.attemptID.uuidString),
                      "modelOrder": .number(Double(invocation.modelOrder)), "toolName": .string(invocation.toolName), "effect": try logJSON(invocation.effect),
                      "call": try content(invocation.call, representation: .object(["callSeq": .number(Double(callSeq))]))]
            state.invocations[invocation.id] = invocation
        case .toolPrepared(let intent):
            name = "mira/tool-prepared"; fields = ["invocationId": .string(intent.invocationID.uuidString), "authorization": try logJSON(intent.authorization), "proposal": try content(intent.proposal)]
        case .toolApprovalRequested(let id, let expiry):
            name = "mira/tool-approval-requested"; fields = ["invocationId": .string(id.uuidString), "expiresAt": try logJSON(expiry)]
        case .toolApprovalResolved(let id, let approved):
            name = "mira/tool-approval-resolved"; fields = ["invocationId": .string(id.uuidString), "approved": .bool(approved)]
        case .toolDispatched(let id, let epoch):
            name = "mira/tool-dispatched"; fields = ["invocationId": .string(id.uuidString), "authorizationEpoch": .number(Double(epoch))]
        case .toolResolved(let result):
            name = "mira/tool-resolved"
            guard let invocation = state.invocations[result.invocationID], let attempt = state.attempts[invocation.attemptID],
                  let turn = state.turns[attempt.executionID] else { throw SessionLogCodecError.missingAssociation }
            let call = try SessionCodec.decode(CanonicalToolCall.self, from: invocation.call.bytes)
            guard let callSeq = state.trace.pendingCalls[call.id] else { throw SessionLogCodecError.missingAssociation }
            let observation = try SessionCodec.encode(SessionToolObservation.value(result))
            let message = SessionMessage(id: .init(result.invocationID.uuidString), role: .user,
                content: [.toolResult(toolCallID: call.id, content: [.text(try text(observation))], isError: result.status == .succeeded ? nil : true)], source: .tool(callID: call.id))
            let error = result.error.map { SessionLogToolError(name: "MiraError", code: $0.code.rawValue, reason: $0.message) }
            try append(.toolResult(turn: turn, step: attempt.stepIndex, message: message, error: error), surface: .append, sources: [callSeq])
            fields = ["invocationId": .string(result.invocationID.uuidString), "status": try logJSON(result.status), "result": try content(result.result, representation: textReference(message.id.value, field: "toolPayload")),
                      "error": try logJSON(result.error), "businessReceipt": try logJSON(result.businessReceipt), "effectIsKnown": .bool(result.effectIsKnown)]
        case .finished(let completion):
            name = "mira/turn-finished"
            guard let turn = state.turns[completion.executionID] else { throw SessionLogCodecError.missingAssociation }
            let reason: SessionLogTurnEndReason
            switch completion.status {
            case .completed: reason = .completed
            case .cancelled: reason = .aborted(reason: .user)
            case .failed:
                if let error = completion.error,
                   (try? SessionCodec.decode(MiraError.self, from: error.bytes).code) == .outputLimit { reason = .maxTokens }
                else { reason = .error(error: try completion.error.map { try SessionCodec.decode(JSONValue.self, from: $0.bytes) } ?? .null) }
            default: reason = .interrupted
            }
            if let step = state.openSteps.removeValue(forKey: turn) { try append(.stepEnd(turn: turn, step: step)) }
            try append(.turnEnd(turn: turn, reason: reason))
            fields = ["executionId": .string(completion.executionID.rawValue.uuidString), "status": try logJSON(completion.status),
                      "assistantMessageId": try logJSON(completion.assistantMessageID?.rawValue), "answer": try answerContent(completion.answer, executionID: completion.executionID),
                      "visibleThinking": try thinkingContent(completion.visibleThinking, executionID: completion.executionID), "error": try content(completion.error), "usage": try logJSON(completion.usage)]
        case .retrySuperseded(let retry):
            name = "mira/turn-retry"; fields = ["sourceExecutionId": .string(retry.sourceExecutionID.rawValue.uuidString), "retryExecutionId": .string(retry.retryExecutionID.rawValue.uuidString)]
        case .extensionRecorded(let namespace, let version, let required, let body):
            name = "mira/extension"; fields = ["namespace": .string(namespace), "schemaVersion": .number(Double(version)), "required": .bool(required), "body": try content(body)]
        }
        fields["eventId"] = .string(event.id.uuidString)
        fields["internalSequence"] = .number(Double(event.sequence))
        // Preserve the command's exact Date for immutable retry reconciliation.
        fields["occurredAt"] = try logJSON(event.occurredAt)
        try append(.mira(name: name, data: .object(fields.filter { $0.value != .null })))
    }
    func text(_ bytes: Data) throws -> String {
        guard let value = String(data: bytes, encoding: .utf8) else { throw SessionLogCodecError.unsupportedPayload }; return value
    }
    private func textReference(_ messageID: String, field: String) -> JSONValue {
        .object(["textSource": .object(["message": .string(messageID), "field": .string(field)])])
    }
    func answerContent(_ value: SessionContent?, executionID: ExecutionID) throws -> JSONValue {
        guard let value else { return .null }
        let ids = Set(state.attempts.values.filter { $0.executionID == executionID }.map { $0.id.uuidString })
        let latest = state.messages.values.filter { ids.contains($0.message.id.value) }.max { $0.seq < $1.seq }
        if let latest,
           SessionLogReader.messageText(latest.message, field: "text").map({ Data($0.utf8) }) == value.bytes {
            return try content(value, representation: textReference(latest.message.id.value, field: "text"))
        }
        return try content(value)
    }
    func thinkingContent(_ value: SessionContent?, executionID: ExecutionID) throws -> JSONValue {
        guard let value else { return .null }
        let ids = Set(state.attempts.values.filter { $0.executionID == executionID }.map { $0.id.uuidString })
        let entries = state.messages.values.filter { ids.contains($0.message.id.value) }.sorted { $0.seq < $1.seq }
        var text = ""
        var sources: [JSONValue] = []
        for entry in entries {
            var indices: [JSONValue] = []
            for (index, block) in entry.message.content.enumerated() {
                if case .reasoning(let value) = block {
                    text += value; indices.append(.number(Double(index)))
                }
            }
            if !indices.isEmpty { sources.append(.object(["message": .string(entry.message.id.value), "indices": .array(indices)])) }
        }
        if !sources.isEmpty, Data(text.utf8) == value.bytes {
            return try content(value, representation: .object(["textSource": .object([
                "field": .string("reasoningSequence"), "messages": .array(sources)])]))
        }
        return try content(value)
    }
}
