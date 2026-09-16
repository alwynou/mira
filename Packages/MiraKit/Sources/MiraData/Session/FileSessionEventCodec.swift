import Foundation
import MiraCore

/// Physical event lines followed by a checksum-bound atomic commit. The payload
/// dictionary exists only while assembling a transaction; it is never serialized.
enum FileSessionEventCodec {
    static let maximumBytes = FileSessionRecord.maximumBytes + 256
    private static let eventNames = [
        "opened": "session_meta", "modelSelectionChanged": "model_selection", "renamed": "session_title",
        "archived": "session_archived", "admitted": "turn_started", "phaseChanged": "execution_phase",
        "attemptStarted": "model_request", "attemptResolved": "model_response", "toolProposed": "tool_call",
        "toolPrepared": "tool_prepared", "toolApprovalRequested": "tool_approval_requested",
        "toolApprovalResolved": "tool_approval_resolved", "toolDispatched": "tool_dispatched",
        "toolResolved": "tool_result", "draftCheckpoint": "response_delta", "finished": "turn_completed",
        "invalidated": "content_invalidated", "retryCleared": "retry_retired", "extensionRecorded": "extension"
    ]
    private static let unlabeled: Set<String> = [
        "opened", "admitted", "attemptStarted", "attemptResolved", "toolProposed", "toolPrepared",
        "toolResolved", "draftCheckpoint", "finished", "invalidated", "retryCleared"
    ]
    private static let textKinds: Set<SessionPayloadKind> = [.title, .userText, .visibleAnswer, .visibleThinking, .draft]
    private static let contentFields = [
        "opened": ["title"], "renamed": ["title"], "admitted": ["userBody", "plan"],
        "attemptStarted": ["request"], "attemptResolved": ["output", "error"], "toolProposed": ["call"],
        "toolPrepared": ["proposal"], "toolResolved": ["result"], "draftCheckpoint": ["replacement"],
        "finished": ["answer", "visibleThinking", "replay", "error"], "extensionRecorded": ["body"]
    ]
    private static let nodeKeys: Set<String> = [
        "id", "retention_group", "kind", "byte_count", "sha256", "source_batch", "storage", "text", "json", "erased"
    ]

    private struct Header: Decodable {
        let id: UUID
        let sequence: Int64
        let timestamp: String
        let type: String
    }
    private struct Commit: Codable {
        let type: String
        let format_version: Int
        let id: UUID
        let session_id: UUID
        let expected_sequence: Int64
        let event_count: Int
        let checksum: String
    }
    private struct Node: Decodable {
        let id: UUID
        let retention_group: UUID
        let kind: SessionPayloadKind
        let byte_count: Int
        let sha256: String
        let source_batch: UUID?
        let storage: String?
        let text: String?
        let erased: Bool?
    }

    private static func formatter() -> ISO8601DateFormatter {
        let result = ISO8601DateFormatter()
        result.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return result
    }
    private static func object(_ bytes: Data) throws -> [String: Any] {
        guard let result = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw FileSessionIO.failure() }
        return result
    }
    private static func jsonBytes(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
    }
    private static func orderedObject(_ fields: [(String, Any)]) throws -> Data {
        var result = Data([123])
        for (index, field) in fields.enumerated() {
            if index > 0 { result.append(44) }
            result.append(try jsonBytes(field.0))
            result.append(58)
            result.append(try jsonBytes(field.1))
        }
        result.append(125)
        return result
    }

    /// Validate complete physical lines before classifying an uncommitted tail.
    /// A valid event without a commit is recoverable; an unknown/corrupt line is not.
    static func isCommit(_ line: Data) throws -> Bool {
        let value = try object(line)
        if value["type"] as? String == "transaction_commit" {
            guard Set(value.keys) == ["type", "format_version", "id", "session_id", "expected_sequence", "event_count", "checksum"] else {
                throw FileSessionIO.failure()
            }
            let commit = try SessionCodec.decode(Commit.self, from: line)
            guard commit.format_version == SessionFormatLimits.version,
                  (1...SessionFormatLimits.maximumEventsPerBatch).contains(commit.event_count),
                  commit.expected_sequence >= 0,
                  commit.expected_sequence <= Int64.max - Int64(commit.event_count),
                  commit.checksum.count == 64,
                  commit.checksum.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw FileSessionIO.failure()
            }
            return true
        }
        guard Set(value.keys) == ["timestamp", "type", "id", "sequence", "payload"],
              value["payload"] is [String: Any] else { throw FileSessionIO.failure() }
        let header = try SessionCodec.decode(Header.self, from: line)
        guard header.sequence > 0, eventNames.values.contains(header.type),
              formatter().date(from: header.timestamp) != nil else { throw FileSessionIO.failure() }
        return false
    }

    static func encode(_ record: FileSessionRecord) throws -> Data {
        try record.validate()
        let references = Set(record.batch.events.flatMap(\.fact.payloadReferences))
        let dateFormatter = formatter()
        var seen: Set<UUID> = [], preceding = Data()
        for event in record.batch.events {
            let fact = try object(SessionCodec.encode(event.fact))
            guard fact.count == 1, let key = fact.keys.first, let type = eventNames[key], let body = fact[key] else {
                throw FileSessionIO.failure()
            }
            var payload = try embed(body, references: references, record: record, seen: &seen)
            if unlabeled.contains(key) {
                guard let container = payload as? [String: Any], let value = container["_0"] else { throw FileSessionIO.failure() }
                payload = value
            }
            preceding.append(try orderedObject([
                ("timestamp", dateFormatter.string(from: event.occurredAt)), ("type", type),
                ("id", event.id.uuidString), ("sequence", event.sequence), ("payload", payload)
            ]))
            preceding.append(10)
            guard preceding.count <= maximumBytes else { throw FileSessionIO.failure() }
        }
        let commit = Commit(type: "transaction_commit", format_version: SessionFormatLimits.version,
                            id: record.batch.id, session_id: record.batch.sessionID.rawValue,
                            expected_sequence: record.batch.expectedSequence, event_count: record.batch.events.count,
                            checksum: FileSessionIO.digest(preceding))
        let result = preceding + (try orderedObject([
            ("type", commit.type), ("format_version", commit.format_version), ("id", commit.id.uuidString),
            ("session_id", commit.session_id.uuidString), ("expected_sequence", commit.expected_sequence),
            ("event_count", commit.event_count), ("checksum", commit.checksum)
        ]))
        guard result.count <= maximumBytes else { throw FileSessionIO.failure() }
        return result
    }

    static func decode(_ bytes: Data) throws -> FileSessionRecord {
        guard !bytes.isEmpty, bytes.count <= maximumBytes else { throw FileSessionIO.failure() }
        let lines = bytes.split(separator: 10, omittingEmptySubsequences: false)
        guard (2...(SessionFormatLimits.maximumEventsPerBatch + 1)).contains(lines.count),
              let last = lines.last, try isCommit(Data(last)) else { throw FileSessionIO.failure() }
        let commit = try SessionCodec.decode(Commit.self, from: Data(last))
        guard commit.event_count == lines.count - 1 else { throw FileSessionIO.failure() }
        let preceding = bytes.prefix(bytes.count - last.count)
        guard FileSessionIO.digest(Data(preceding)) == commit.checksum else { throw FileSessionIO.failure() }
        let dateFormatter = formatter()
        var events: [SessionEvent] = [], payloads: [String: String] = [:], references: [UUID: SessionPayloadReference] = [:]
        for (index, line) in lines.dropLast().enumerated() {
            let data = Data(line)
            guard try !isCommit(data) else { throw FileSessionIO.failure() }
            let header = try SessionCodec.decode(Header.self, from: data)
            guard header.sequence == commit.expected_sequence + Int64(index) + 1,
                  let key = eventNames.first(where: { $0.value == header.type })?.key,
                  let date = dateFormatter.date(from: header.timestamp),
                  var payload = try object(data)["payload"] as? [String: Any] else {
                throw FileSessionIO.failure()
            }
            // Only typed content fields are references. Extension/configuration
            // data cannot impersonate storage metadata through matching keys.
            for field in (contentFields[key] ?? []).sorted() {
                if let content = payload[field] {
                    payload[field] = try restore(content, sessionID: ConversationID(commit.session_id), batchID: commit.id,
                                                 payloads: &payloads, references: &references)
                }
            }
            let body: Any
            if unlabeled.contains(key) { body = ["_0": payload] }
            else { body = payload }
            let fact = try SessionCodec.decode(SessionFact.self, from: jsonBytes([key: body]))
            events.append(.init(id: header.id, sequence: header.sequence, occurredAt: date, fact: fact))
        }
        let record = FileSessionRecord(batch: .init(id: commit.id, sessionID: ConversationID(commit.session_id),
            expectedSequence: commit.expected_sequence, events: events), payloads: payloads)
        try record.validate()
        return record
    }

    private static func embed(_ value: Any, references: Set<SessionPayloadReference>, record: FileSessionRecord,
                              seen: inout Set<UUID>) throws -> Any {
        if let dictionary = value as? [String: Any] {
            if dictionary["sessionID"] != nil,
               let reference = try? SessionCodec.decode(SessionPayloadReference.self, from: jsonBytes(dictionary)),
               references.contains(reference) {
                return try content(reference, record: record, seen: &seen)
            }
            var result: [String: Any] = [:]
            for key in dictionary.keys.sorted() {
                result[key] = try embed(dictionary[key]!, references: references, record: record, seen: &seen)
            }
            return result
        }
        if let array = value as? [Any] {
            return try array.map { try embed($0, references: references, record: record, seen: &seen) }
        }
        return value
    }

    private static func content(_ ref: SessionPayloadReference, record: FileSessionRecord,
                                seen: inout Set<UUID>) throws -> [String: Any] {
        var result: [String: Any] = ["id": ref.id.uuidString, "retention_group": ref.retentionGroup.uuidString,
            "kind": ref.kind.rawValue, "byte_count": ref.byteCount, "sha256": ref.digest]
        if ref.batchID != record.batch.id { result["source_batch"] = ref.batchID.uuidString }
        if ref.storage == .external { result["storage"] = "external"; return result }
        guard ref.batchID == record.batch.id, seen.insert(ref.id).inserted else { return result }
        guard let text = record.payloads[ref.id.uuidString] else { result["erased"] = true; return result }
        let bytes = Data(text.utf8)
        // Only losslessly canonical JSON becomes a structured value. Opaque provider
        // strings, whitespace, numeric precision and user-authored text stay verbatim.
        if !textKinds.contains(ref.kind), let json = try? SessionCodec.decode(JSONValue.self, from: bytes),
           try SessionCodec.encode(json) == bytes {
            result["json"] = try JSONSerialization.jsonObject(with: bytes, options: [.fragmentsAllowed])
        } else { result["text"] = text }
        return result
    }

    private static func restore(_ value: Any, sessionID: ConversationID, batchID: UUID,
                                payloads: inout [String: String], references: inout [UUID: SessionPayloadReference]) throws -> Any {
        if let dictionary = value as? [String: Any] {
            if dictionary["retention_group"] != nil {
                guard Set(dictionary.keys).isSubset(of: nodeKeys) else { throw FileSessionIO.failure() }
                let node = try SessionCodec.decode(Node.self, from: jsonBytes(dictionary))
                guard node.storage == nil || node.storage == "external",
                      node.source_batch != batchID, node.erased == nil || node.erased == true else { throw FileSessionIO.failure() }
                let reference = SessionPayloadReference(id: node.id, sessionID: sessionID, batchID: node.source_batch ?? batchID,
                    retentionGroup: node.retention_group, kind: node.kind, byteCount: node.byte_count, digest: node.sha256,
                    storage: node.storage == "external" ? .external : .inline)
                try reference.validate()
                let hasText = dictionary["text"] != nil, hasJSON = dictionary["json"] != nil
                let hasBody = hasText || hasJSON, prior = references[node.id]
                guard !(hasText && hasJSON), !(node.erased != nil && hasBody),
                      prior == nil || prior == reference else { throw FileSessionIO.failure() }
                if reference.storage == .external || reference.batchID != batchID {
                    guard !hasBody, node.erased == nil else { throw FileSessionIO.failure() }
                } else if prior != nil {
                    guard !hasBody, node.erased == nil else { throw FileSessionIO.failure() }
                } else {
                    guard hasBody || node.erased == true else { throw FileSessionIO.failure() }
                }
                references[node.id] = reference
                if let json = dictionary["json"] {
                    guard !textKinds.contains(node.kind) else { throw FileSessionIO.failure() }
                    let value = try SessionCodec.decode(JSONValue.self, from: jsonBytes(json))
                    payloads[node.id.uuidString] = String(decoding: try SessionCodec.encode(value), as: UTF8.self)
                } else if hasText {
                    guard let text = node.text else { throw FileSessionIO.failure() }
                    payloads[node.id.uuidString] = text
                }
                return try object(SessionCodec.encode(reference))
            }
            var result: [String: Any] = [:]
            for key in dictionary.keys.sorted() {
                result[key] = try restore(dictionary[key]!, sessionID: sessionID, batchID: batchID,
                                          payloads: &payloads, references: &references)
            }
            return result
        }
        if let array = value as? [Any] {
            return try array.map { try restore($0, sessionID: sessionID, batchID: batchID, payloads: &payloads, references: &references) }
        }
        return value
    }
}
