import Foundation

extension SessionLogReader {
    func textSource(_ source: JSONValue) throws -> String {
        if source["field"] == .string("reasoningSequence") {
            guard case .array(let references) = source["messages"], !references.isEmpty else { throw SessionLogCodecError.unsupportedPayload }
            var result = ""
            var seen: Set<String> = []
            var previousSeq = -1
            for reference in references {
                let id = try logString(reference, "message")
                guard seen.insert(id).inserted else { throw SessionLogCodecError.unsupportedPayload }
                let message = try self.message(id)
                guard case .model = message.source, let seq = state.messages[id]?.seq, seq > previousSeq,
                      case .array(let indices) = reference["indices"], !indices.isEmpty else { throw SessionLogCodecError.unsupportedPayload }
                previousSeq = seq
                var previousIndex = -1
                for encodedIndex in indices {
                    let index = try logInt(encodedIndex)
                    guard index > previousIndex, message.content.indices.contains(index), case .reasoning(let text) = message.content[index] else {
                        throw SessionLogCodecError.missingAssociation
                    }
                    result += text
                    previousIndex = index
                    guard result.utf8.count <= SessionFormatLimits.maximumContentBytes else { throw SessionLogCodecError.unsupportedPayload }
                }
            }
            return result
        }
        let message = try message(logString(source, "message"))
        if let field = source["field"] {
            let fieldName = try logString(field)
            if fieldName == "toolResult" {
                guard case .tool(let sourceCallID) = message.source,
                      message.role == .user else { throw SessionLogCodecError.missingAssociation }
                let bytes = try SessionCodec.encode(SessionLogToolObservation.envelope(in: message, callID: sourceCallID))
                return String(decoding: bytes, as: UTF8.self)
            }
            if fieldName == "toolPayload" {
                guard case .tool(let sourceCallID) = message.source,
                      message.role == .user else { throw SessionLogCodecError.missingAssociation }
                let bytes = try SessionLogToolObservation.payload(in: message, callID: sourceCallID)
                return String(decoding: bytes, as: UTF8.self)
            }
            guard let text = Self.messageText(message, field: fieldName) else { throw SessionLogCodecError.missingAssociation }; return text
        }
        let index = try logInt(source, "index")
        guard message.content.indices.contains(index) else { throw SessionLogCodecError.missingAssociation }
        switch message.content[index] {
        case .text(let text), .reasoning(let text), .toolCall(_, _, let text): return text
        default: throw SessionLogCodecError.unsupportedPayload
        }
    }
    mutating func content(_ encoded: JSONValue?, executionID: ExecutionID? = nil) throws -> SessionContent? {
        guard let encoded, encoded != .null else { return nil }
        let id = try logUUID(encoded, "id")
        guard let kind = SessionContentKind(rawValue: try logString(encoded, "kind")) else { throw SessionLogCodecError.unsupportedPayload }
        let bytes: Data
        if let reference = encoded["ref"] {
            guard let entry = state.contents[try logUUID(reference)], entry.seq < state.nextSeq,
                  entry.value.kind == kind else { throw SessionLogCodecError.missingAssociation }
            bytes = entry.value.bytes
        } else {
            guard let representation = encoded["value"] else { throw SessionLogCodecError.unsupportedPayload }
            if let text = representation["text"] { bytes = Data(try logString(text).utf8) }
            else if let source = representation["textSource"] { bytes = Data(try textSource(source).utf8) }
            else if let json = representation["json"] { bytes = try SessionCodec.encode(json) }
            else if let binary = representation["binary"] {
                guard let data = Data(base64Encoded: try logString(binary)) else { throw SessionLogCodecError.unsupportedPayload }; bytes = data
            } else if var plan = representation["plan"] {
                let system = try message(logString(representation, "system"))
                guard let instructions = Self.messageText(system, field: "text") else { throw SessionLogCodecError.unsupportedPayload }
                plan = try logSet(plan, path: ["instructions"], to: .string(instructions))
                if let routeID = representation["route"], routeID != .null {
                    let route = try route(logString(routeID))
                    plan = try logSet(plan, path: ["route"], to: logJSON(route))
                }
                bytes = try SessionCodec.encode(try logDecode(AgentExecutionPlan.self, plan))
            } else if representation["header"] != nil {
                guard let executionID else { throw SessionLogCodecError.missingAssociation }
                bytes = try SessionCodec.encode(request(representation, executionID: executionID))
            } else if let output = representation["output"] {
                let message = try message(logString(output, "message"))
                let ids = try logDecode([String].self, output["blockIds"] ?? .null)
                guard ids.count == message.content.count else { throw SessionLogCodecError.unsupportedPayload }
                let blocks = zip(message.content, ids).map { $0.agentModelBlock(id: $1) }
                let continuation: AgentModelContinuation?
                if case .model(_, _, let replay) = message.source, let replay { continuation = try logDecode(AgentModelContinuation.self, replay) }
                else { continuation = nil }
                let value = AgentModelOutput(blocks: blocks, continuation: continuation,
                    usage: try logDecode(TokenUsage.self, output["usage"] ?? .null), finishReason: try logDecode(StreamFinishReason.self, output["finishReason"] ?? .null))
                bytes = try SessionCodec.encode(value)
            } else if let callSeq = representation["callSeq"] {
                let seq = try logInt(callSeq)
                guard seq < state.nextSeq, let call = state.toolCalls[seq] else { throw SessionLogCodecError.missingAssociation }
                bytes = try SessionCodec.encode(call)
            } else { throw SessionLogCodecError.unsupportedPayload }
        }
        let value = SessionContent(id: id, kind: kind, bytes: bytes)
        try value.validate()
        if let old = state.contents[id], old.value != value { throw SessionLogCodecError.duplicateIdentity }
        state.contents[id] = .init(seq: min(state.contents[id]?.seq ?? state.nextSeq, state.nextSeq), value: value)
        return value
    }
    mutating func requiredContent(_ encoded: JSONValue?, executionID: ExecutionID? = nil) throws -> SessionContent {
        guard let value = try content(encoded, executionID: executionID) else { throw SessionLogCodecError.missingAssociation }; return value
    }
    func route(_ id: String) throws -> AgentModelRoute {
        guard let entry = state.routes[id], entry.seq < state.nextSeq else { throw SessionLogCodecError.missingAssociation }; return entry.route
    }
    func request(_ value: JSONValue, executionID: ExecutionID) throws -> AgentSessionRequest {
        guard let sessionID = state.sessionID else { throw SessionLogCodecError.wrongSession }
        let route = try route(logString(value, "route"))
        let system = try message(logString(value, "system"))
        let user = try message(logString(value, "user"))
        guard system.role == .system, user.role == .user, case .user = user.source,
              state.userMessages[executionID] == user.id.value,
              let instructions = Self.messageText(system, field: "text"),
              let userText = Self.messageText(user, field: "text"),
              let header = state.headers[try logString(value, "header")], header.seq < state.nextSeq,
              case .array(let definitions) = header.value["tools"] ?? .array([]) else {
            throw SessionLogCodecError.missingAssociation
        }
        guard header.value["config"] == .object([
            "provider": .string(route.adapter.id), "model": .string(route.modelID),
            "maxTokens": .number(Double(route.maximumOutputTokens))]) else {
            throw SessionLogCodecError.missingAssociation
        }
        let tools = try definitions.map { definition in
            ToolDefinition(name: try logString(definition, "name"), description: try logString(definition, "description"),
                           inputSchema: definition["parameters"] ?? .null)
        }
        guard case .array(let contexts) = value["context"] ?? .array([]) else { throw SessionLogCodecError.unsupportedPayload }
        let contextMessages = try contexts.enumerated().map { index, item -> AgentModelMessage in
            let id = try logString(item, "message")
            guard id == "context-\(executionID.rawValue.uuidString)-\(index)" else { throw SessionLogCodecError.missingAssociation }
            let source = try message(id)
            guard source.role == .user, case .plugin(let plugin) = source.source, plugin == "mira-context" else {
                throw SessionLogCodecError.missingAssociation
            }
            let ids = try logDecode([String].self, item["blockIds"] ?? .null)
            guard ids.count == source.content.count else { throw SessionLogCodecError.missingAssociation }
            return .init(role: .context, blocks: zip(source.content, ids).map { $0.agentModelBlock(id: $1) })
        }
        let request = AgentContextRequest(sessionID: sessionID, executionID: executionID,
            workspaceID: try value["workspaceId"].map { WorkspaceID(try logUUID($0)) }, userText: userText,
            authorizationEpoch: try logDecode(UInt64.self, value["authorizationEpoch"] ?? .null), destination: .model(route))
        let result = AgentSessionRequest(request: request, instructions: instructions, tools: tools,
            contextMessages: contextMessages, estimatedInputTokens: try logInt(value, "estimatedInputTokens"),
            inheritedSources: try logDecode([AgentSourceReference].self, value["inheritedSources"] ?? .array([])),
            evidence: try logDecode([AgentContextEvidence].self, value["evidence"] ?? .array([])),
            omissions: try logDecode([AgentContextOmission].self, value["omissions"] ?? .array([])))
        try result.validate(for: route)
        return result
    }
}
