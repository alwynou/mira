import Foundation

struct SessionLogReader {
    var state: SessionLogState
    mutating func read(_ event: SessionLogEvent) throws -> SessionEvent? {
        try state.trace.apply(event)
        switch event.data {
        case .userMessage(let message), .toolResult(_, _, let message, _, _):
            try register(message, seq: event.seq)
        case .systemMessage(_, _, let message):
            try register(message, seq: event.seq); state.activeSystemID = message.id.value
        case .assistantMessage(_, _, let message, let stream, _, _):
            try register(message, seq: event.seq); state.streams[event.seq] = stream
        case .assistantAttempt(_, _, let stream): state.streams[event.seq] = stream
        case .toolCall(_, _, let id, let name, let arguments): state.toolCalls[event.seq] = .init(id: id, name: name, arguments: arguments)
        case .requestHeader(let value, _, _):
            let id = SessionContentDigest.sha256(try SessionCodec.encode(value))
            if state.headers[id] == nil { state.headers[id] = .init(seq: event.seq, value: value) }
            state.activeHeaderID = id
        case .stepStart(let turn, let step): state.openSteps[turn] = step
        case .stepEnd(let turn, _): state.openSteps[turn] = nil
        case .mira(let name, let data):
            if name == "mira/route-snapshot" {
                let id = try logString(data, "id"), route = try logDecode(AgentModelRoute.self, data["route"] ?? .null)
                guard id == SessionContentDigest.sha256(try SessionCodec.encode(route)) else { throw SessionLogCodecError.unsupportedPayload }
                state.routes[id] = .init(seq: event.seq, route: route); return nil
            }
            let occurredAt = try logDecode(Date.self, data["occurredAt"] ?? .null)
            guard try logTime(occurredAt) == event.time else { throw SessionLogCodecError.malformedTime }
            let fact = try fact(name, data: data)
            return .init(id: try logUUID(data, "eventId"), sequence: Int64(try logInt(data, "internalSequence")),
                occurredAt: occurredAt, fact: fact)
        default: break
        }
        return nil
    }
    mutating func register(_ message: SessionMessage, seq: Int) throws {
        if let old = state.messages[message.id.value], try SessionCodec.encode(old.message) != SessionCodec.encode(message) { throw SessionLogCodecError.duplicateIdentity }
        state.messages[message.id.value] = .init(seq: seq, message: message)
    }
    func message(_ id: String) throws -> SessionMessage {
        guard let entry = state.messages[id], entry.seq < state.nextSeq else { throw SessionLogCodecError.missingAssociation }; return entry.message
    }
    static func messageText(_ message: SessionMessage, field: String) -> String? {
        let values: [String] = message.content.compactMap { block in
            switch (field, block) {
            case ("text", .text(let text)), ("reasoning", .reasoning(let text)): return text
            case ("toolResult", .toolResult(_, let blocks, _)):
                return blocks.compactMap { if case .text(let text) = $0 { return text }; return nil }.joined()
            default: return nil
            }
        }
        return values.isEmpty ? nil : values.joined()
    }
    mutating func fact(_ name: String, data: JSONValue) throws -> SessionFact {
        func decode<T: Decodable>(_ type: T.Type, _ key: String) throws -> T { try logDecode(type, data[key] ?? .null) }
        func execution(_ key: String = "executionId") throws -> ExecutionID { .init(try logUUID(data, key)) }
        switch name {
        case "mira/session-opened": return .opened(.init(workspaceID: try decode(WorkspaceID?.self, "workspaceId"), title: try requiredContent(data["title"])))
        case "mira/session-renamed": return .renamed(title: try requiredContent(data["title"]), revision: try logInt(data, "revision"))
        case "mira/session-archived": return .archived(revision: try logInt(data, "revision"))
        case "mira/model-selection": return .modelSelectionChanged(selection: try decode(AgentSessionModelSelection.self, "selection"), expectedRevision: try logInt(data, "expectedRevision"))
        case "mira/turn-admitted":
            let id = try execution(), plan = try requiredContent(data["plan"])
            state.turns[id] = try logInt(data, "turn")
            state.userMessages[id] = try logString(data, "userMessageId")
            state.plans[id] = try SessionCodec.decode(AgentExecutionPlan.self, from: plan.bytes)
            return .admitted(.init(executionID: id, userMessageID: .init(try logUUID(data, "userMessageId")),
                retryOfExecutionID: try decode(UUID?.self, "retryOfExecutionId").map(ExecutionID.init),
                userBody: try content(data["userBody"]), plan: plan, hasModelRoute: try decode(Bool.self, "hasModelRoute"),
                authorizationEpoch: try decode(UInt64.self, "authorizationEpoch"), timeZoneIdentifier: try logString(data, "timeZoneIdentifier"),
                modelSelectionRevision: try logInt(data, "modelSelectionRevision")))
        case "mira/phase-changed": return .phaseChanged(executionID: try execution(), phase: try decode(ExecutionPhase.self, "phase"))
        case "mira/request-start":
            guard try logInt(data, "throughSeq") == state.nextSeq - 1 else { throw SessionLogCodecError.invalidSequence }
            let attempt = SessionAttempt(id: try logUUID(data, "attempt"), executionID: try execution(), stepID: try logUUID(data, "stepId"),
                stepIndex: try logInt(data, "step"), attemptIndex: try logInt(data, "attemptIndex"), request: try requiredContent(data["request"], executionID: try execution()))
            state.attempts[attempt.id] = attempt
            return .attemptStarted(attempt)
        case "mira/attempt-resolved":
            let seq = try logInt(data, "streamSeq")
            guard seq < state.nextSeq, let stream = state.streams[seq] else { throw SessionLogCodecError.missingAssociation }
            return .attemptResolved(.init(attemptID: try logUUID(data, "attempt"), status: try decode(AttemptStatus.self, "status"),
                output: try content(data["output"]), error: try content(data["error"]), usage: try decode(TokenUsage.self, "usage"), stream: stream))
        case "mira/tool-proposed":
            let invocation = SessionInvocation(id: try logUUID(data, "invocationId"), attemptID: try logUUID(data, "attempt"), modelOrder: try logInt(data, "modelOrder"),
                toolName: try logString(data, "toolName"), effect: try decode(SessionEffectKind.self, "effect"), call: try requiredContent(data["call"]))
            state.invocations[invocation.id] = invocation; return .toolProposed(invocation)
        case "mira/tool-prepared": return .toolPrepared(.init(invocationID: try logUUID(data, "invocationId"), authorization: try decode(AgentLibraryAuthorization.self, "authorization"), proposal: try requiredContent(data["proposal"])))
        case "mira/tool-approval-requested": return .toolApprovalRequested(invocationID: try logUUID(data, "invocationId"), expiresAt: try decode(Date.self, "expiresAt"))
        case "mira/tool-approval-resolved": return .toolApprovalResolved(invocationID: try logUUID(data, "invocationId"), approved: try decode(Bool.self, "approved"))
        case "mira/tool-dispatched": return .toolDispatched(invocationID: try logUUID(data, "invocationId"), authorizationEpoch: try decode(UInt64.self, "authorizationEpoch"))
        case "mira/tool-resolved": return .toolResolved(.init(invocationID: try logUUID(data, "invocationId"), status: try decode(ToolResultStatus.self, "status"), result: try content(data["result"]), businessReceipt: try decode(AgentBusinessReceiptReference?.self, "businessReceipt"), effectIsKnown: try decode(Bool.self, "effectIsKnown"), error: try decode(MiraError?.self, "error")))
        case "mira/turn-finished": return .finished(.init(executionID: try execution(), status: try decode(ExecutionStatus.self, "status"), assistantMessageID: try decode(UUID?.self, "assistantMessageId").map(MessageID.init), answer: try content(data["answer"]), visibleThinking: try content(data["visibleThinking"]), error: try content(data["error"]), usage: try decode(TokenUsage.self, "usage")))
        case "mira/turn-retry": return .retrySuperseded(.init(sourceExecutionID: try execution("sourceExecutionId"), retryExecutionID: try execution("retryExecutionId")))
        case "mira/extension": return .extensionRecorded(namespace: try logString(data, "namespace"), schemaVersion: try logInt(data, "schemaVersion"), required: try decode(Bool.self, "required"), body: try requiredContent(data["body"]))
        default: throw SessionLogCodecError.unsupportedPayload
        }
    }
}
