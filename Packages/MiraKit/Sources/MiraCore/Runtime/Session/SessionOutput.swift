import Foundation

/// Current model-stream activity, independent of whether earlier thinking exists.
public enum SessionOutputPhase: String, Sendable, Equatable {
    case waiting, thinking, answering, callingTool
}

/// The currently visible, in-memory output of one unresolved model attempt.
/// It is deliberately separate from journal payloads.
public struct SessionVisibleOutput: Sendable, Equatable {
    public let executionID: ExecutionID
    public let attemptID: UUID
    public let stepID: UUID
    public let answer: String
    public let thinking: String
    public let phase: SessionOutputPhase
    public let toolCall: CanonicalToolCall?
    /// Ordered visible blocks of this attempt only; never provider continuation data.
    public let blocks: [AgentModelBlock]

    public init(executionID: ExecutionID, attemptID: UUID, stepID: UUID,
                answer: String, thinking: String, phase: SessionOutputPhase = .waiting,
                toolCall: CanonicalToolCall? = nil, blocks: [AgentModelBlock] = []) {
        self.executionID = executionID
        self.attemptID = attemptID
        self.stepID = stepID
        self.answer = answer
        self.thinking = thinking
        self.phase = phase
        self.toolCall = toolCall
        self.blocks = blocks
    }
}

/// A lossy wake-up stream for live output. The journal remains the durable source of truth.
public struct SessionOutputObservation: Sendable, Equatable {
    public let cursor: SessionCursor
    public let revision: UInt64
    public let value: SessionVisibleOutput?
    public let isClosing: Bool
    /// A successful attempt has committed its final output. A bound presentation
    /// may keep already-delivered pixels until it installs that durable snapshot.
    public let handoffExecutionID: ExecutionID?

    public init(cursor: SessionCursor, revision: UInt64,
                value: SessionVisibleOutput?, isClosing: Bool, handoffExecutionID: ExecutionID? = nil) {
        self.cursor = cursor
        self.revision = revision
        self.value = value
        self.isClosing = isClosing
        self.handoffExecutionID = handoffExecutionID
    }
}

/// The settled model output visible for an execution. Model answers belong to
/// the latest settled attempt; thinking remains cumulative across settled
/// attempts so multi-step tool execution keeps its prior reasoning visible.
public struct SessionSettledOutput: Sendable, Equatable {
    public let answer: String?
    public let thinking: String?

    public init(answer: String? = nil, thinking: String? = nil) {
        self.answer = answer
        self.thinking = thinking
    }

    /// Reads only committed attempt resolutions. An unresolved attempt has no
    /// output here by design: its in-memory stream is owned by the executor.
    public static func read(
        execution: SessionExecutionState,
        attempts: [UUID: SessionAttemptState],
        payloads: any SessionContentReader
    ) async throws -> SessionSettledOutput {
        var answer: String?
        var thinking = ""
        for attemptID in execution.attemptIDs {
            guard let attempt = attempts[attemptID], attempt.attempt.id == attemptID,
                  attempt.attempt.executionID == execution.admission.executionID else {
                throw MiraError(.storage, "The execution attempt is unavailable while reading settled output.")
            }
            guard let reference = attempt.resolution?.output else { continue }
            try reference.validate()
            guard reference.kind == .modelOutput else {
                throw MiraError(.storage, "The settled model output has an invalid content kind.")
            }
            let bytes = try await payloads.read(reference)
            guard bytes.count == reference.byteCount else {
                throw MiraError(.storage, "The settled model output has an invalid length.")
            }
            let output = try SessionCodec.decode(AgentModelOutput.self, from: bytes)
            answer = output.text.isEmpty ? nil : output.text
            if !output.thinkingText.isEmpty {
                guard thinking.utf8.count + output.thinkingText.utf8.count <= SessionFormatLimits.maximumContentBytes else {
                    throw MiraError(.outputLimit, "The settled thinking output exceeds its storage limit.")
                }
                thinking += output.thinkingText
            }
        }
        return .init(answer: answer, thinking: thinking.isEmpty ? nil : thinking)
    }
}
