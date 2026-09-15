import Foundation

/// Current model-stream activity, independent of whether earlier thinking exists.
public enum SessionOutputPhase: String, Sendable, Equatable {
    case waiting, thinking, answering, callingTool
}

/// The currently visible, in-memory output of one unresolved model attempt.
/// It is deliberately separate from durable drafts and journal payloads.
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
    /// A successful attempt has committed its final draft. A bound presentation
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
