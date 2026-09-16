import Foundation

/// Frozen request metadata with direct content references, never a chain of prior requests.
struct AgentRequestManifest: Codable, Sendable, Equatable {
    struct Header: Codable, Sendable, Equatable {
        let instructions: String
        let tools: [ToolDefinition]
        let allowsToolCalls: Bool
        let outputTokenLimit: Int?
        let adapter: AgentAdapterIdentity
    }

    struct Entry: Codable, Sendable, Equatable {
        enum Representation: String, Codable, Sendable { case message, userText, modelOutput, toolResult }
        let reference: SessionPayloadReference
        let representation: Representation
        let blockID: String?
        let callID: String?
        let toolStatus: ToolResultStatus?

        init(reference: SessionPayloadReference, representation: Representation,
             blockID: String? = nil, callID: String? = nil, toolStatus: ToolResultStatus? = nil) {
            self.reference = reference; self.representation = representation
            self.blockID = blockID; self.callID = callID; self.toolStatus = toolStatus
        }

        func validate(sessionID: ConversationID) throws {
            try reference.validate()
            guard reference.sessionID == sessionID else { throw invalid }
            switch representation {
            case .message:
                guard reference.kind == .requestComponent, blockID == nil, callID == nil, toolStatus == nil else { throw invalid }
            case .modelOutput:
                guard reference.kind == .modelOutput, blockID == nil, callID == nil, toolStatus == nil else { throw invalid }
            case .userText:
                guard reference.kind == .userText, let blockID,
                      SessionState.validIdentifier(blockID, maximumBytes: 256), callID == nil, toolStatus == nil else { throw invalid }
            case .toolResult:
                guard reference.kind == .toolResult, let blockID, let callID, toolStatus != nil,
                      SessionState.validIdentifier(blockID, maximumBytes: 256),
                      !callID.isEmpty, callID.utf8.count <= 256 else { throw invalid }
            }
        }

        func materialize(_ bytes: Data) throws -> AgentModelMessage {
            switch representation {
            case .message: return try SessionCodec.decode(AgentModelMessage.self, from: bytes)
            case .modelOutput: return try SessionCodec.decode(AgentModelOutput.self, from: bytes).message
            case .userText:
                guard let text = String(data: bytes, encoding: .utf8), let blockID else { throw invalid }
                return .init(role: .user, blocks: [.init(id: blockID, content: .text(text))])
            case .toolResult:
                guard let blockID, let callID, let toolStatus else { throw invalid }
                let text = try Self.toolObservation(bytes, status: toolStatus)
                return .init(role: .tool, blocks: [.init(id: blockID, content: .toolResult(callID: callID, text: text))])
            }
        }

        static func toolObservation(_ bytes: Data, status: ToolResultStatus) throws -> String {
            let content = try SessionCodec.decode(JSONValue.self, from: bytes)
            return try JSONValue.object(["status": .string(status.rawValue), "content": content,
                "authority": .string("untrusted_tool_observation")]).jsonString()
        }
    }

    struct Metadata: Sendable {
        let request: AgentContextRequest
        let inheritedSources: [AgentSourceReference]
        let evidence: [AgentContextEvidence]
        let omissions: [AgentContextOmission]
        let executionID: ExecutionID
        let stepID: UUID
    }

    let request: AgentContextRequest
    let executionID: ExecutionID
    let stepID: UUID
    let header: SessionPayloadReference
    let prefixMessageCount: Int?
    let estimatedInputTokens: Int
    let currentUserMessageIndex: Int
    let inheritedSources: [AgentSourceReference]
    let evidence: [AgentContextEvidence]
    let omissions: [AgentContextOmission]
    let entries: [Entry]

    static func stage(record: AgentRequestRecord, context: SessionCommandContext) async throws ->
        (request: SessionPayloadReference, contents: [SessionPayloadReference]) {
        let input = record.input
        guard input.messages.count <= 256, input.messages.indices.contains(record.currentUserMessageIndexValue),
              try SessionCodec.encode(input).count <= maximumInputBytes else { throw invalid }
        let retention = UUID()
        let headerValue = Header(instructions: input.instructions, tools: input.tools,
            allowsToolCalls: input.allowsToolCalls, outputTokenLimit: input.outputTokenLimit, adapter: record.adapter)
        let reusable = try await candidates(record: record, context: context)
        let headerRef: SessionPayloadReference
        if let existing = reusable.headers.first(where: { $0.value == headerValue }) {
            headerRef = existing.reference
        } else {
            headerRef = try await context.stage(headerValue, kind: .requestComponent, retentionGroup: retention)
        }
        var entries: [Entry] = []
        var newlyStaged: [(AgentModelMessage, Entry)] = []
        for message in input.messages {
            if let existing = reusable.messages.first(where: { $0.message == message }) {
                entries.append(existing.entry)
            } else if message.continuation == nil, message.blocks.count == 1,
                      let existing = reusable.raw.first(where: { $0.matches(message) }) {
                entries.append(.init(reference: existing.reference,
                    representation: existing.reference.kind == .userText ? .userText : .toolResult,
                    blockID: message.blocks[0].id, callID: existing.callID, toolStatus: existing.toolStatus))
            } else if let existing = newlyStaged.first(where: { $0.0 == message }) {
                entries.append(existing.1)
            } else {
                let reference = try await context.stage(message, kind: .requestComponent, retentionGroup: retention)
                let entry = Entry(reference: reference, representation: .message)
                entries.append(entry); newlyStaged.append((message, entry))
            }
        }
        let manifest = Self(request: record.request, executionID: input.executionID, stepID: input.stepID,
            header: headerRef, prefixMessageCount: input.prefixMessageCount,
            estimatedInputTokens: record.estimatedInputTokens, currentUserMessageIndex: record.currentUserMessageIndexValue,
            inheritedSources: record.inheritedSources, evidence: record.evidence, omissions: record.omissions, entries: entries)
        try manifest.validate(sessionID: context.state.id)
        let reference = try await context.stage(manifest, kind: .request, retentionGroup: retention)
        var seen: Set<UUID> = []
        let contents = ([headerRef] + entries.map(\.reference)).filter { seen.insert($0.id).inserted }
        return (reference, contents)
    }

    static func read(reference: SessionPayloadReference, payloads: any SessionPayloadReader) async throws -> AgentRequestRecord {
        guard reference.kind == .request else { throw invalid }
        let manifest = try decode(await payloads.read(reference), sessionID: reference.sessionID)
        let header = try SessionCodec.decode(Header.self, from: await payloads.read(manifest.header))
        var messages: [AgentModelMessage] = []
        for entry in manifest.entries {
            messages.append(try entry.materialize(await payloads.read(entry.reference)))
        }
        let record = try AgentRequestRecord(manifest: manifest, header: header, messages: messages)
        guard try SessionCodec.encode(record.input).count <= maximumInputBytes else { throw invalid }
        return record
    }

    static func decodeMetadata(_ data: Data, sessionID: ConversationID) throws -> Metadata {
        let value = try decode(data, sessionID: sessionID)
        return .init(request: value.request, inheritedSources: value.inheritedSources,
            evidence: value.evidence, omissions: value.omissions, executionID: value.executionID, stepID: value.stepID)
    }

    private static func decode(_ data: Data, sessionID: ConversationID) throws -> Self {
        let value = try SessionCodec.decode(Self.self, from: data)
        try value.validate(sessionID: sessionID)
        return value
    }

    private func validate(sessionID: ConversationID) throws {
        guard request.sessionID == sessionID, request.executionID == executionID,
              entries.count <= 256, entries.indices.contains(currentUserMessageIndex),
              header.sessionID == sessionID, header.kind == .requestComponent,
              estimatedInputTokens >= 0, inheritedSources.count <= 8_192, evidence.count <= 8_192,
              omissions.count <= 8_192 else { throw Self.invalid }
        try header.validate()
        var bytes = header.byteCount
        for entry in entries {
            try entry.validate(sessionID: sessionID)
            bytes += entry.reference.byteCount
            guard bytes <= Self.maximumInputBytes else { throw Self.invalid }
        }
    }

    private struct RawCandidate {
        let reference: SessionPayloadReference
        let text: String
        let callID: String?
        let toolStatus: ToolResultStatus?
        func matches(_ message: AgentModelMessage) -> Bool {
            switch message.blocks[0].content {
            case .text(let value): return reference.kind == .userText && message.role == .user && value == text
            case .toolResult(let id, let value): return reference.kind == .toolResult && message.role == .tool && value == text && callID == id
            default: return false
            }
        }
    }
    private struct Candidates {
        var messages: [(entry: Entry, message: AgentModelMessage)] = []
        var raw: [RawCandidate] = []
        var headers: [(reference: SessionPayloadReference, value: Header)] = []
    }

    private static func candidates(record: AgentRequestRecord, context: SessionCommandContext) async throws -> Candidates {
        var allowed: Set<ExecutionID> = [record.request.executionID]
        for source in record.sources {
            if case .sessionExecution(let session, let execution) = source, session == context.state.id {
                allowed.insert(execution)
            }
        }
        var result = Candidates()
        var seen: Set<UUID> = []
        func eligible(_ reference: SessionPayloadReference) -> Bool {
            context.state.references[reference.id] == reference &&
                !context.state.invalidatedRetentionGroups.contains(reference.retentionGroup)
        }
        for id in context.state.executionOrder where allowed.contains(id) && !context.state.excludedExecutionIDs.contains(id) {
            guard let execution = context.state.executions[id] else { continue }
            if let body = execution.admission.userBody, eligible(body),
               let text = String(data: try await context.payloads.read(body), encoding: .utf8) {
                result.raw.append(.init(reference: body, text: text, callID: nil, toolStatus: nil))
            }
            for attemptID in execution.attemptIDs {
                guard let attempt = context.state.attempts[attemptID] else { throw invalid }
                if attempt.resolution?.status == .completed, let output = attempt.resolution?.output,
                   eligible(output), seen.insert(output.id).inserted {
                    let value = try SessionCodec.decode(AgentModelOutput.self, from: await context.payloads.read(output))
                    result.messages.append((.init(reference: output, representation: .modelOutput), value.message))
                }
                for invocationID in attempt.invocationIDs {
                    guard let invocation = context.state.invocations[invocationID],
                          let reference = invocation.resolution?.result, eligible(reference),
                          eligible(invocation.invocation.call), seen.insert(reference.id).inserted else { continue }
                    let call = try SessionCodec.decode(CanonicalToolCall.self, from: await context.payloads.read(invocation.invocation.call))
                    let status = invocation.resolution!.status
                    let text = try Entry.toolObservation(await context.payloads.read(reference), status: status)
                    result.raw.append(.init(reference: reference, text: text, callID: call.id, toolStatus: status))
                }
                // Reuse synthetic context and headers within one execution only, preserving
                // independent privacy ownership for materialized context in later turns.
                guard id == record.request.executionID, eligible(attempt.attempt.request),
                      seen.insert(attempt.attempt.request.id).inserted else { continue }
                let old = try decode(await context.payloads.read(attempt.attempt.request), sessionID: context.state.id)
                if eligible(old.header), seen.insert(old.header.id).inserted {
                    result.headers.append((old.header, try SessionCodec.decode(Header.self, from: await context.payloads.read(old.header))))
                }
                for entry in old.entries where entry.reference.kind == .requestComponent && eligible(entry.reference) && seen.insert(entry.reference.id).inserted {
                    result.messages.append((entry, try entry.materialize(await context.payloads.read(entry.reference))))
                }
            }
        }
        return result
    }

    private static let maximumInputBytes = 8 * 1_024 * 1_024
    private static var invalid: MiraError { .init(.storage, "The execution request manifest is invalid or unsupported.") }
}
