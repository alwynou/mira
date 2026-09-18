import Foundation

/// Canonical tool messages own the model-facing observation envelope.
/// Business result references select its content without duplicating the bytes.
enum SessionLogToolObservation {
    static let authority = "untrusted_tool_observation"

    static func status(isError: Bool?) -> String {
        isError == true ? "failed" : "succeeded"
    }

    static func toolResults(in message: SessionMessage) -> [(callID: String, text: String, status: String)] {
        message.content.compactMap { block in
            guard case .toolResult(let callID, let content, let isError) = block else { return nil }
            let text = content.compactMap { child -> String? in
                if case .text(let value) = child { return value }
                return nil
            }.joined()
            guard !text.isEmpty else { return nil }
            let actual = text.data(using: .utf8).flatMap { try? SessionCodec.decode(JSONValue.self, from: $0) }
            let envelopeStatus: String? = actual.flatMap { if case .string(let value) = $0["status"] { return value }; return nil }
            return (callID: callID, text: text, status: envelopeStatus ?? status(isError: isError))
        }
    }

    static func envelope(in message: SessionMessage, callID: String) throws -> JSONValue {
        guard case .tool(let sourceCallID) = message.source, sourceCallID == callID,
              message.role == .user,
              let result = toolResults(in: message).first(where: { $0.callID == callID }),
              let bytes = result.text.data(using: .utf8),
              let envelope = try? SessionCodec.decode(JSONValue.self, from: bytes),
              case .object(let fields) = envelope,
              fields["authority"] == .string(authority),
              fields["status"] == .string(result.status), fields["content"] != nil,
              (result.status == "succeeded") == (message.content.contains { if case .toolResult(_, _, let error) = $0 { return error != true }; return false }) else {
            throw SessionLogCodecError.missingAssociation
        }
        return envelope
    }

    static func payload(in message: SessionMessage, callID: String) throws -> Data {
        let envelope = try envelope(in: message, callID: callID)
        guard let value = envelope["content"] else { throw SessionLogCodecError.missingAssociation }
        return try SessionCodec.encode(value)
    }
}

extension SessionLogWriter {
    /// Each immutable value is defined once. Text already owned by a shared
    /// message refers to that message; operational JSON stays readable inline.
    func content(_ value: SessionContent?, representation: JSONValue? = nil) throws -> JSONValue {
        guard let value else { return .null }
        var result: [String: JSONValue] = ["id": .string(value.id.uuidString), "kind": .string(value.kind.rawValue)]
        if let old = state.contents[value.id] {
            guard old.value == value else { throw SessionLogCodecError.duplicateIdentity }
            result["ref"] = .string(value.id.uuidString); return .object(result)
        }
        if let representation { result["value"] = representation }
        else if let same = state.contents.values.filter({ $0.value.bytes == value.bytes && $0.value.kind == value.kind }).min(by: { $0.seq < $1.seq }) {
            result["ref"] = .string(same.value.id.uuidString)
        } else if let json = try? SessionCodec.decode(JSONValue.self, from: value.bytes),
                  (try? SessionCodec.encode(json)) == value.bytes {
            result["value"] = .object(["json": json])
        } else if let string = String(data: value.bytes, encoding: .utf8) {
            result["value"] = .object(["text": .string(string)])
        } else {
            // Non-text domain content uses inline base64. Ordinary messages
            // and model requests never take this path.
            result["value"] = .object(["binary": .string(value.bytes.base64EncodedString())])
        }
        state.contents[value.id] = .init(seq: state.nextSeq, value: value)
        return .object(result)
    }

    func request(_ boundary: AgentSessionRequest, turn: Int, step: Int) throws -> JSONValue {
        guard let routeValue = boundary.request.destination.modelRoute,
              let userID = state.userMessages[boundary.request.executionID],
              let user = state.messages[userID]?.message,
              sessionUserText(user).utf8.elementsEqual(boundary.request.userText.utf8) else {
            throw SessionLogCodecError.missingAssociation
        }
        try boundary.validate(for: routeValue)
        let routeRef = try route(routeValue)
        let systemRef = try system(boundary.instructions, turn: turn, step: step)
        var headerFields: [String: JSONValue] = ["config": .object([
            "provider": .string(routeValue.adapter.id), "model": .string(routeValue.modelID),
            "maxTokens": .number(Double(routeValue.maximumOutputTokens))])]
        if !boundary.tools.isEmpty {
            headerFields["tools"] = .array(boundary.tools.map {
                .object(["name": .string($0.name), "description": .string($0.description), "parameters": $0.inputSchema])
            })
        }
        let header = JSONValue.object(headerFields)
        let headerID = SessionContentDigest.sha256(try SessionCodec.encode(header))
        if state.activeHeaderID != headerID {
            let seq = try append(.requestHeader(header: header, reason: state.activeHeaderID == nil ? "initial" : "change"))
            if state.headers[headerID] == nil { state.headers[headerID] = .init(seq: seq, value: header) }
            state.activeHeaderID = headerID
            try append(.requestContext(provider: routeValue.adapter.id, model: routeValue.modelID, contextWindow: routeValue.contextWindow))
        }
        var contexts: [JSONValue] = []
        for (index, context) in boundary.contextMessages.enumerated() {
            let id = "context-\(boundary.request.executionID.rawValue.uuidString)-\(index)"
            try message(.init(id: .init(id), role: .user, content: context.blocks.map(SessionMessageContent.init),
                              source: .plugin(plugin: "mira-context")), turn: turn, step: step)
            contexts.append(.object(["message": .string(id), "blockIds": try logJSON(context.blocks.map(\.id))]))
        }
        var value: [String: JSONValue] = [
            "header": .string(headerID), "route": routeRef, "system": .string(systemRef), "user": .string(userID),
            "estimatedInputTokens": .number(Double(boundary.estimatedInputTokens)),
            "authorizationEpoch": .number(Double(boundary.request.authorizationEpoch))]
        if let workspaceID = boundary.request.workspaceID { value["workspaceId"] = .string(workspaceID.rawValue.uuidString) }
        if !contexts.isEmpty { value["context"] = .array(contexts) }
        if !boundary.inheritedSources.isEmpty { value["inheritedSources"] = try logJSON(boundary.inheritedSources) }
        if !boundary.evidence.isEmpty { value["evidence"] = try logJSON(boundary.evidence) }
        if !boundary.omissions.isEmpty { value["omissions"] = try logJSON(boundary.omissions) }
        return .object(value)
    }
}

private func sessionUserText(_ message: SessionMessage) -> String {
    message.content.compactMap { if case .text(let text) = $0 { return text }; return nil }.joined()
}
