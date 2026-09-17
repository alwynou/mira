import Foundation

/// Reads recovery output from settled steps and the single replaceable active draft.
/// Streaming checkpoints are never part of the canonical session journal.
public struct SessionDraftReader: Sendable {
    private let payloads: any SessionPayloadReader

    public init(journal: any SessionJournal, payloads: any SessionPayloadReader) {
        self.payloads = payloads
    }

    static func active(state: SessionState, executionID: ExecutionID,
                       payloads: any SessionPayloadReader) async throws -> SessionActiveDraft? {
        guard state.activeExecutionID == executionID,
              let execution = state.executions[executionID], execution.completion == nil,
              !state.excludedExecutionIDs.contains(executionID),
              let attemptID = execution.attemptIDs.last,
              let attempt = state.attempts[attemptID], attempt.resolution == nil,
              let draft = try await payloads.activeDraft(sessionID: state.id),
              draft.executionID == executionID, draft.attemptID == attemptID,
              draft.authorizationEpoch == state.authorizationEpoch,
              draft.request == attempt.attempt.request,
              state.references[draft.request.id] == draft.request,
              !state.invalidatedRetentionGroups.contains(draft.request.retentionGroup) else { return nil }
        try draft.validate()
        return draft
    }

    func thinkingPrefix(state: SessionState, executionID: ExecutionID) async throws -> String {
        guard let execution = state.executions[executionID], execution.completion == nil,
              !state.excludedExecutionIDs.contains(executionID) else { return "" }
        var text = ""
        for id in execution.attemptIDs {
            guard let attempt = state.attempts[id], attempt.resolution?.status == .completed,
                  let reference = attempt.resolution?.output,
                  !state.invalidatedRetentionGroups.contains(reference.retentionGroup) else { continue }
            let output = try SessionCodec.decode(AgentModelOutput.self, from: await payloads.read(reference))
            text += output.thinkingText
            guard text.utf8.count <= SessionFormatLimits.maximumPayloadBytes else {
                throw MiraError(.outputLimit, "The execution thinking exceeds its read limit.")
            }
        }
        return text
    }

    public func read(state: SessionState, executionID: ExecutionID,
                     parts: Set<SessionDraftPart> = [.answer, .thinking, .transcript]) async throws -> [SessionDraftPart: Data] {
        guard let execution = state.executions[executionID] else {
            throw MiraError(.notFound, "The execution is unavailable.")
        }
        guard execution.completion == nil, !state.excludedExecutionIDs.contains(executionID) else { return [:] }
        var thinking = ""
        var latest: [AgentModelBlock] = []
        var total = 0
        for id in execution.attemptIDs {
            try Task.checkCancellation()
            guard let attempt = state.attempts[id] else { throw MiraError(.storage, "The execution attempt is unavailable.") }
            // Only successful earlier steps belong to the current response. Failed retries
            // retain their own activity but do not enter the next model step's draft.
            guard let output = attempt.resolution?.output,
                  attempt.resolution?.status == .completed || id == execution.attemptIDs.last else { continue }
            guard state.references[output.id] == output, output.kind == .modelOutput,
                  !state.invalidatedRetentionGroups.contains(output.retentionGroup) else { continue }
            total += output.byteCount
            guard total <= SessionFormatLimits.maximumPayloadBytes * 3 else {
                throw MiraError(.outputLimit, "The execution draft exceeds the read limit.")
            }
            let value = try SessionCodec.decode(AgentModelOutput.self, from: await payloads.read(output))
            thinking += value.thinkingText
            latest = value.blocks
        }
        let active = try await Self.active(state: state, executionID: executionID, payloads: payloads)
        if let active {
            thinking += AgentModelOutput.thinking(in: active.blocks)
            latest = active.blocks
        } else if let last = execution.attemptIDs.last, state.attempts[last]?.resolution == nil {
            latest = []
        }
        var values: [SessionDraftPart: Data] = [:]
        if parts.contains(.answer) { values[.answer] = Data(AgentModelOutput.text(in: latest).utf8) }
        if parts.contains(.thinking) { values[.thinking] = Data(thinking.utf8) }
        if parts.contains(.transcript), let active { values[.transcript] = try SessionCodec.encode(active) }
        guard values.values.allSatisfy({ $0.count <= SessionFormatLimits.maximumPayloadBytes }) else {
            throw MiraError(.outputLimit, "The execution draft exceeds the read limit.")
        }
        return values
    }
}
