import Foundation
import XCTest
@testable import MiraCore

final class SessionLogContentReferenceTests: XCTestCase {
    func testEqualTextKeepsTheCurrentExecutionAsItsOwner() throws {
        let executionID = ExecutionID(), oldAttemptID = UUID(), currentAttemptID = UUID()
        var state = SessionLogState.initial
        state.nextSeq = 3
        let user = SessionMessage(id: "user", role: .user, content: [.text("same")], source: .user)
        state.messages[user.id.value] = .init(seq: 0, message: user)
        for (index, id) in [oldAttemptID, currentAttemptID].enumerated() {
            let message = SessionMessage(id: .init(id.uuidString), role: .assistant,
                content: [.text("same"), .reasoning("thought")],
                source: .model(provider: "fixture", model: "m", replayState: nil))
            state.messages[message.id.value] = .init(seq: index + 1, message: message)
            state.attempts[id] = .init(id: id, executionID: index == 0 ? ExecutionID() : executionID,
                stepID: UUID(), stepIndex: 1, attemptIndex: 1, request: .init(kind: .request, bytes: Data()))
        }
        let oldContent = SessionContent(kind: .visibleAnswer, bytes: Data("same".utf8))
        state.contents[oldContent.id] = .init(seq: 1, value: oldContent)
        let writer = SessionLogWriter(state: state)
        let answer = try writer.answerContent(.init(kind: .visibleAnswer, bytes: Data("same".utf8)), executionID: executionID)
        XCTAssertEqual(answer["value"]?["textSource"]?["message"], .string(currentAttemptID.uuidString))
        XCTAssertNil(answer["ref"])
        let thinking = try writer.thinkingContent(.init(kind: .visibleThinking, bytes: Data("thought".utf8)), executionID: executionID)
        XCTAssertEqual(thinking["value"]?["textSource"]?["messages"], .array([
            .object(["message": .string(currentAttemptID.uuidString), "indices": .array([.number(1)])])
        ]))
    }

    func testReasoningSequencePreservesOrderedEmptyAndDuplicateChunks() throws {
        let executionID = ExecutionID(), firstID = UUID(), secondID = UUID()
        let first = SessionMessage(id: .init(firstID.uuidString), role: .assistant,
            content: [.reasoning(""), .reasoning("same")],
            source: .model(provider: "fixture", model: "m", replayState: nil))
        let second = SessionMessage(id: .init(secondID.uuidString), role: .assistant,
            content: [.reasoning("same"), .reasoning("")],
            source: .model(provider: "fixture", model: "m", replayState: nil))
        var state = SessionLogState.initial
        state.nextSeq = 2
        state.messages = [
            first.id.value: .init(seq: 0, message: first),
            second.id.value: .init(seq: 1, message: second)
        ]
        for (step, id) in [firstID, secondID].enumerated() {
            state.attempts[id] = .init(id: id, executionID: executionID, stepID: UUID(), stepIndex: step + 1,
                attemptIndex: 1, request: .init(kind: .request, bytes: Data()))
        }
        let writer = SessionLogWriter(state: state)
        let encoded = try writer.thinkingContent(.init(kind: .visibleThinking, bytes: Data("samesame".utf8)), executionID: executionID)
        let source = try XCTUnwrap(encoded["value"]?["textSource"])
        XCTAssertEqual(source["field"], .string("reasoningSequence"))
        let reader = SessionLogReader(state: state)
        XCTAssertEqual(try reader.textSource(source), "samesame")
    }

    func testReasoningSequenceRejectsFutureAndDuplicateMessageReferences() throws {
        let message = SessionMessage(id: "assistant", role: .assistant,
            content: [.reasoning("thought")], source: .model(provider: "fixture", model: "m", replayState: nil))
        var state = SessionLogState.initial
        state.nextSeq = 1
        state.messages = [message.id.value: .init(seq: 1, message: message)]
        let future: JSONValue = .object(["field": .string("reasoningSequence"), "messages": .array([
            .object(["message": .string("assistant"), "indices": .array([.number(0)])])
        ])])
        XCTAssertThrowsError(try SessionLogReader(state: state).textSource(future))
    }
}
