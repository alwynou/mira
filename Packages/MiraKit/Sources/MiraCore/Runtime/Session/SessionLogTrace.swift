import Foundation

/// Execution relations are checked on both append and replay, including indexed reads.
struct SessionLogTrace: Codable, Sendable, Equatable {
    var nextTurn = 1
    var turn: Int?
    var nextStep = 1
    var step: Int?
    var pendingCalls: [String: Int] = [:]

    mutating func apply(_ event: SessionLogEvent) throws {
        func requireStep(_ turn: Int, _ step: Int) throws {
            guard self.turn == turn, self.step == step else { throw SessionLogCodecError.invalidRelation }
        }
        switch event.data {
        case .turnStart(let turn):
            guard self.turn == nil, turn == nextTurn else { throw SessionLogCodecError.invalidRelation }
            self.turn = turn; nextStep = 1
        case .turnEnd(let turn, _):
            guard self.turn == turn, step == nil, pendingCalls.isEmpty else { throw SessionLogCodecError.invalidRelation }
            self.turn = nil; nextTurn += 1
        case .stepStart(let turn, let step):
            guard self.turn == turn, self.step == nil, step == nextStep else { throw SessionLogCodecError.invalidRelation }
            self.step = step
        case .stepEnd(let turn, let step):
            try requireStep(turn, step)
            guard pendingCalls.isEmpty else { throw SessionLogCodecError.invalidRelation }
            self.step = nil; nextStep += 1
        case .systemMessage(let turn, let step, _), .assistantMessage(let turn, let step, _, _, _, _),
             .assistantAttempt(let turn, let step, _):
            try requireStep(turn, step)
        case .toolCall(let turn, let step, let callID, _, _):
            try requireStep(turn, step)
            guard pendingCalls[callID] == nil else { throw SessionLogCodecError.duplicateIdentity }
            pendingCalls[callID] = event.seq
        case .toolResult(let turn, let step, let message, _, _):
            try requireStep(turn, step)
            guard case .tool(let callID) = message.source,
                  let callSeq = pendingCalls[callID], event.sourceEventSeqs == [callSeq] else {
                throw SessionLogCodecError.invalidRelation
            }
            pendingCalls[callID] = nil
        case .requestHeader, .requestContext:
            guard turn != nil else { throw SessionLogCodecError.invalidRelation }
        default: break
        }
    }
}
