import Foundation

public enum SessionToolActivityStatus: String, Codable, Sendable, Equatable {
    case queued, waitingForApproval, running, succeeded, failed, stopped
}

public struct SessionToolActivity: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let toolName: String
    public let status: SessionToolActivityStatus
    public let arguments: SessionTextContent
    public let result: SessionTextContent

    public init(id: UUID, toolName: String, status: SessionToolActivityStatus,
                arguments: SessionTextContent = .absent, result: SessionTextContent = .absent) {
        self.id = id; self.toolName = toolName; self.status = status
        self.arguments = arguments; self.result = result
    }

}

public struct SessionActivityStep: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let stepIndex: Int
    public let blocks: [SessionActivityBlock]

    public init(id: UUID, stepIndex: Int, blocks: [SessionActivityBlock]) {
        self.id = id; self.stepIndex = stepIndex; self.blocks = blocks
    }
}

public struct SessionActivityBlock: Sendable, Equatable, Identifiable {
    public let id: String
    public let content: Content

    public enum Content: Sendable, Equatable {
        case thinking(SessionTextContent)
        case text(SessionTextContent)
        case tool(SessionToolActivity)
    }

    public init(id: String, content: Content) { self.id = id; self.content = content }
}

/// Bounded, read-only activity assembly from one journal snapshot. It exposes
/// model output blocks and tool exchanges, while never exposing requests or
/// continuation data.
struct SessionActivityReader: Sendable {
    static let maximumExecutionIDs = 128

    static func read(
        snapshot: SessionJournalSnapshot, sessionID: ConversationID,
        executionIDs: [ExecutionID], maximumPageBytes: Int,
        journal: any SessionJournal, payloads: any SessionPayloadReader
    ) async throws -> [ExecutionID: [SessionActivityStep]] {
        guard snapshot.state.id == sessionID,
              executionIDs.count <= maximumExecutionIDs,
              Set(executionIDs).count == executionIDs.count,
              maximumPageBytes >= 0 else { throw invalidPage }
        var result: [ExecutionID: [SessionActivityStep]] = [:]
        var remaining = maximumPageBytes
        for executionID in executionIDs {
            guard !snapshot.state.excludedExecutionIDs.contains(executionID),
                  let execution = snapshot.state.executions[executionID] else {
                result[executionID] = []
                continue
            }
            guard Set(execution.attemptIDs).count == execution.attemptIDs.count else { throw invalidPage }
            let attempts = try execution.attemptIDs.map { id -> SessionAttemptState in
                guard let attempt = snapshot.state.attempts[id], attempt.attempt.id == id,
                      attempt.attempt.executionID == executionID else { throw invalidPage }
                return attempt
            }.sorted {
                if $0.attempt.stepIndex != $1.attempt.stepIndex { return $0.attempt.stepIndex < $1.attempt.stepIndex }
                if $0.attempt.attemptIndex != $1.attempt.attemptIndex { return $0.attempt.attemptIndex < $1.attempt.attemptIndex }
                return $0.sequence < $1.sequence
            }

            var steps: [SessionActivityStep] = []
            for attempt in attempts {
                guard Set(attempt.invocationIDs).count == attempt.invocationIDs.count else { throw invalidPage }
                let invocations = try attempt.invocationIDs.map { id -> SessionInvocationState in
                    guard let invocation = snapshot.state.invocations[id], invocation.invocation.id == id,
                          invocation.invocation.attemptID == attempt.attempt.id else { throw invalidPage }
                    return invocation
                }.sorted { $0.invocation.modelOrder < $1.invocation.modelOrder }

                var blocks: [SessionActivityBlock] = []
                if let output = attempt.resolution?.output {
                    let decoded = try await decodedOutput(output, state: snapshot.state, payloads: payloads, remaining: &remaining)
                    if case .available(let modelOutput) = decoded {
                        var invocationIndex = 0
                        for modelBlock in modelOutput.blocks {
                            switch modelBlock.content {
                            case .thinking(let text): blocks.append(.init(id: modelBlock.id, content: .thinking(.available(text))))
                            case .text(let text): blocks.append(.init(id: modelBlock.id, content: .text(.available(text))))
                            case .toolCall(let call):
                                let order = invocationIndex
                                invocationIndex += 1
                                if let invocation = invocations.first(where: { $0.invocation.modelOrder == order }) {
                                    guard invocation.invocation.toolName == call.name else { throw invalidPage }
                                    blocks.append(.init(id: modelBlock.id, content: .tool(try await tool(
                                        invocation, expectedCall: call, state: snapshot.state,
                                        payloads: payloads, remaining: &remaining))))
                                } else {
                                    blocks.append(.init(id: modelBlock.id, content: .tool(.init(
                                        id: attempt.attempt.id, toolName: call.name,
                                        status: execution.completion == nil ? .queued : .stopped,
                                        arguments: .available(call.arguments), result: .absent))))
                                }
                            case .toolResult: break
                            }
                        }
                    }
                    if blocks.isEmpty {
                        blocks.append(.init(id: "attempt-\(attempt.attempt.id.uuidString)", content: .text(
                            decoded == .purged ? .purged : .absent)))
                    }
                }
                let existingToolIDs = Set(blocks.compactMap { block -> UUID? in
                    if case .tool(let tool) = block.content { return tool.id }; return nil
                })
                for invocation in invocations where !existingToolIDs.contains(invocation.invocation.id) {
                    let toolActivity = try await tool(invocation, state: snapshot.state, payloads: payloads, remaining: &remaining)
                    blocks.append(.init(id: invocation.invocation.id.uuidString, content: .tool(toolActivity)))
                }
                steps.append(.init(id: attempt.attempt.id, stepIndex: attempt.attempt.stepIndex, blocks: blocks))
            }
            if let latestAttempt = attempts.last,
               latestAttempt.resolution?.output == nil,
               let draftBlocks = try await draftBlocks(
                state: snapshot.state, executionID: executionID, journal: journal,
                attempt: latestAttempt, payloads: payloads, remaining: &remaining) {
                let draftStep = SessionActivityStep(
                    id: latestAttempt.attempt.id,
                    stepIndex: latestAttempt.attempt.stepIndex,
                    blocks: draftBlocks)
                if let last = steps.last, last.id == draftStep.id {
                    steps[steps.count - 1] = draftStep
                } else {
                    steps.append(draftStep)
                }
            }
            result[executionID] = steps
        }
        return result
    }

    static func status(of invocation: SessionInvocationState) -> SessionToolActivityStatus {
        if let resolution = invocation.resolution {
            switch resolution.status {
            case .succeeded: return .succeeded
            case .cancelledBeforeDispatch, .cancelled, .interrupted: return .stopped
            case .invalidArguments, .notFound, .denied, .timedOut, .failed, .outputLimit: return .failed
            }
        }
        if let approval = invocation.approval, approval.approved == nil { return .waitingForApproval }
        if invocation.dispatchedAt != nil { return .running }
        return .queued
    }

    private static func tool(
        _ invocation: SessionInvocationState, expectedCall: CanonicalToolCall? = nil, state: SessionState,
        payloads: any SessionPayloadReader, remaining: inout Int
    ) async throws -> SessionToolActivity {
        let arguments = try await content(invocation.invocation.call, expectedKind: .toolCall,
            state: state, payloads: payloads, remaining: &remaining) {
            let call = try SessionCodec.decode(CanonicalToolCall.self, from: $0)
            guard call.name == invocation.invocation.toolName, expectedCall.map({ $0 == call }) ?? true else { throw invalidPage }
            return call.arguments
        }
        let result: SessionTextContent
        if let resolution = invocation.resolution, resolution.resultWasPurged {
            result = .purged
        } else if let reference = invocation.resolution?.result {
            result = try await content(reference, expectedKind: .toolResult, state: state,
                payloads: payloads, remaining: &remaining) {
                let value = try SessionCodec.decode(JSONValue.self, from: $0)
                if let text = value.stringValue { return text }
                return try value.jsonString()
            }
        } else { result = .absent }
        return .init(id: invocation.invocation.id, toolName: invocation.invocation.toolName,
                     status: status(of: invocation), arguments: arguments, result: result)
    }

    private static func decodedOutput(
        _ reference: SessionPayloadReference, state: SessionState,
        payloads: any SessionPayloadReader, remaining: inout Int
    ) async throws -> SessionAuditContent<AgentModelOutput> {
        try reference.validate()
        guard reference.kind == .modelOutput, state.references[reference.id] == reference else { throw invalidPage }
        if state.invalidatedRetentionGroups.contains(reference.retentionGroup) { return .purged }
        guard reference.byteCount <= remaining else { return .absent }
        remaining -= reference.byteCount
        let bytes = try await payloads.read(reference)
        guard bytes.count == reference.byteCount else { throw invalidPage }
        return .available(try SessionCodec.decode(AgentModelOutput.self, from: bytes))
    }

    private struct DraftTranscript: Decodable {
        let blocks: [AgentModelBlock]
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            blocks = try container.decode([AgentModelBlock].self, forKey: .blocks)
        }
        private enum CodingKeys: String, CodingKey { case blocks }
    }

    private static func draftBlocks(
        state: SessionState, executionID: ExecutionID, journal: any SessionJournal,
        attempt: SessionAttemptState?, payloads: any SessionPayloadReader, remaining: inout Int
    ) async throws -> [SessionActivityBlock]? {
        guard let attempt,
              let draft = state.executions[executionID]?.drafts[.transcript],
              draft.checkpoint.attemptID == attempt.attempt.id,
              draft.checkpoint.resultByteCount <= remaining,
              state.references[draft.checkpoint.replacement.id] == draft.checkpoint.replacement,
              !state.invalidatedRetentionGroups.contains(draft.checkpoint.replacement.retentionGroup)
        else { return nil }
        let bounded = ActivityDraftPayloadReader(base: payloads, remaining: remaining)
        let values: [SessionDraftPart: Data]
        do {
            values = try await SessionDraftReader(journal: journal, payloads: bounded)
                .read(state: state, executionID: executionID, parts: [.transcript])
        } catch ActivityDraftPayloadReader.Limit.exceeded {
            remaining = await bounded.remaining
            return nil
        }
        remaining = await bounded.remaining
        guard let bytes = values[.transcript] else { return nil }
        let transcript = try SessionCodec.decode(DraftTranscript.self, from: bytes)
        var invocationIndex = 0
        var blocks: [SessionActivityBlock] = []
        for block in transcript.blocks {
            switch block.content {
            case .thinking(let text): blocks.append(.init(id: block.id, content: .thinking(.available(text))))
            case .text(let text): blocks.append(.init(id: block.id, content: .text(.available(text))))
            case .toolCall(let call):
                let order = invocationIndex
                invocationIndex += 1
                if let invocation = attempt.invocationIDs.compactMap({ state.invocations[$0] })
                    .first(where: { $0.invocation.modelOrder == order }) {
                    guard invocation.invocation.toolName == call.name else { throw invalidPage }
                    blocks.append(.init(id: block.id, content: .tool(try await tool(
                        invocation, expectedCall: call, state: state, payloads: payloads, remaining: &remaining))))
                } else {
                    blocks.append(.init(id: block.id, content: .tool(.init(
                        id: attempt.attempt.id, toolName: call.name, status: .queued,
                        arguments: .available(call.arguments), result: .absent))))
                }
            case .toolResult: break
            }
        }
        return blocks
    }

    private static func content(
        _ reference: SessionPayloadReference, expectedKind: SessionPayloadKind, state: SessionState,
        payloads: any SessionPayloadReader, remaining: inout Int,
        decode: (Data) throws -> String
    ) async throws -> SessionTextContent {
        try reference.validate()
        guard reference.kind == expectedKind, state.references[reference.id] == reference else { throw invalidPage }
        if state.invalidatedRetentionGroups.contains(reference.retentionGroup) { return .purged }
        guard reference.byteCount <= remaining else { return .absent }
        remaining -= reference.byteCount
        let bytes = try await payloads.read(reference)
        guard bytes.count == reference.byteCount else { throw invalidPage }
        return .available(try decode(bytes))
    }

    private static var invalidPage: MiraError { .init(.storage, "The session activity is inconsistent.") }
}

/// Counts actual patch reads, not just the reconstructed draft size.
private actor ActivityDraftPayloadReader: SessionPayloadReader {
    enum Limit: Error { case exceeded }
    let base: any SessionPayloadReader
    private(set) var remaining: Int
    init(base: any SessionPayloadReader, remaining: Int) { self.base = base; self.remaining = remaining }
    func read(_ reference: SessionPayloadReference) async throws -> Data {
        guard reference.byteCount <= remaining else { throw Limit.exceeded }
        remaining -= reference.byteCount
        return try await base.read(reference)
    }
}
