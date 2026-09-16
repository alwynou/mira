import Foundation

/// The replaceable, recoverable output of the currently running attempt.
public struct SessionActiveDraft: Codable, Sendable, Equatable {
    public let request: SessionPayloadReference
    public let executionID: ExecutionID
    public let attemptID: UUID
    public let authorizationEpoch: UInt64
    public let revision: UInt64
    public let blocks: [AgentModelBlock]
    public let continuation: AgentModelContinuation?
    public let usage: TokenUsage

    public init(request: SessionPayloadReference, executionID: ExecutionID, attemptID: UUID,
                authorizationEpoch: UInt64, revision: UInt64, blocks: [AgentModelBlock],
                continuation: AgentModelContinuation? = nil, usage: TokenUsage = .init()) {
        self.request = request; self.executionID = executionID; self.attemptID = attemptID
        self.authorizationEpoch = authorizationEpoch; self.revision = revision
        self.blocks = blocks; self.continuation = continuation; self.usage = usage
    }

    public func validate() throws {
        guard request.kind == .request, revision > 0,
              blocks.count <= 64, Set(blocks.map(\.id)).count == blocks.count else {
            throw MiraError(.storage, "The active session draft is invalid or exceeds its bounds.")
        }
        try request.validate()
        for block in blocks { try Self.validate(block) }
        try continuation?.validate()
        try usage.validate(maximumTokens: TokenUsage.maximumAggregateTokens)
        guard try SessionCodec.encode(self).count <= Self.maximumBytes else {
            throw MiraError(.outputLimit, "The active session draft exceeds its supported bounds.")
        }
    }

    public static let maximumBytes = 8 * 1_024 * 1_024

    private static func validate(_ block: AgentModelBlock) throws {
        guard SessionState.validIdentifier(block.id, maximumBytes: 256) else {
            throw MiraError(.malformedStream, "The model block identity is invalid.")
        }
        switch block.content {
        case .text(let value), .thinking(let value):
            guard value.utf8.count <= SessionFormatLimits.maximumPayloadBytes else { throw limitError() }
        case .toolResult(let callID, let text):
            guard !callID.isEmpty, callID.utf8.count <= 256,
                  text.utf8.count <= SessionFormatLimits.maximumPayloadBytes else { throw limitError() }
        case .toolCall(let call):
            // Streaming tool arguments are deliberately allowed to be incomplete JSON.
            guard !call.id.isEmpty, call.id.utf8.count <= 256,
                  SessionState.validIdentifier(call.name, maximumBytes: 64),
                  call.arguments.utf8.count <= 65_536 else { throw limitError() }
        }
    }

    private static func limitError() -> MiraError {
        .init(.malformedStream, "The active model block is invalid or exceeds its bounds.")
    }
}

public protocol SessionActiveDraftReader: Sendable {
    func activeDraft(sessionID: ConversationID) async throws -> SessionActiveDraft?
}

public protocol SessionActiveDraftStore: SessionActiveDraftReader {
    func saveActiveDraft(_ draft: SessionActiveDraft) async throws
    func removeActiveDraft(sessionID: ConversationID, attemptID: UUID) async throws
}
