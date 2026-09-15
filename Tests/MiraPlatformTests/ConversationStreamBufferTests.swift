import Foundation
import Testing
import MiraCore

// Unicode fixtures verify cumulative visible output preserves multilingual text and emoji.
@Suite("Conversation stream buffer")
@MainActor
struct ConversationStreamBufferTests {
    @Test func committedHandoffKeepsNewestPendingTextUntilMatchingSnapshot() {
        let buffer = ConversationStreamBuffer(interval: .seconds(1))
        let session = ConversationID(), execution = ExecutionID()
        buffer.receive(observation(session: session, sequence: 1, revision: 1, execution: execution, answer: "Prefix"))
        buffer.flush()
        buffer.receive(observation(session: session, sequence: 1, revision: 2, execution: execution, answer: "Prefix and final tail"))
        buffer.receive(.init(cursor: .init(sessionID: session, sequence: 3), revision: 3,
                             value: nil, isClosing: false, handoffExecutionID: execution))
        #expect(buffer.observation?.value?.answer == "Prefix and final tail")
        buffer.completeHandoff(executionID: execution, through: 2)
        #expect(buffer.observation?.value != nil)
        buffer.completeHandoff(executionID: execution, through: 3)
        #expect(buffer.observation?.value == nil)
    }

    @Test func revocationClearsHandoffImmediatelyAndForeignHandoffCannotReuseIt() {
        let buffer = ConversationStreamBuffer(interval: .seconds(1))
        let session = ConversationID(), execution = ExecutionID()
        buffer.receive(observation(session: session, sequence: 1, revision: 1, execution: execution, answer: "Private"))
        buffer.receive(.init(cursor: .init(sessionID: session, sequence: 2), revision: 2,
                             value: nil, isClosing: false, handoffExecutionID: execution))
        #expect(buffer.observation?.value?.answer == "Private")
        buffer.receive(observation(session: session, sequence: 3, revision: 3))
        #expect(buffer.observation?.value == nil)
        buffer.receive(.init(cursor: .init(sessionID: session, sequence: 4), revision: 4,
                             value: nil, isClosing: false, handoffExecutionID: ExecutionID()))
        #expect(buffer.observation?.value == nil)
    }
    @Test func burstPublishesLatestAnswerAndThinkingSnapshot() {
        let buffer = ConversationStreamBuffer(interval: .seconds(1))
        let session = ConversationID()
        let execution = ExecutionID()
        let attempt = UUID()
        let step = UUID()
        buffer.receive(observation(session: session, sequence: 1, revision: 1, execution: execution,
                                   attempt: attempt, step: step, answer: "你", thinking: "思")) // i18n-fixture: cumulative Unicode answer and thinking remain verbatim.
        buffer.receive(observation(session: session, sequence: 1, revision: 2, execution: execution,
                                   attempt: attempt, step: step, answer: "你好，世界 🌏", thinking: "思考完成")) // i18n-fixture: cumulative Unicode answer and thinking remain verbatim.
        #expect(buffer.observation == nil)

        buffer.flush()

        #expect(buffer.observation?.revision == 2)
        #expect(buffer.observation?.value?.answer == "你好，世界 🌏") // i18n-fixture: cumulative Unicode answer and thinking remain verbatim.
        #expect(buffer.observation?.value?.thinking == "思考完成") // i18n-fixture: cumulative Unicode answer and thinking remain verbatim.
    }

    @Test func revocationPublishesClearImmediatelyAndCancelsPendingValue() {
        let buffer = ConversationStreamBuffer(interval: .seconds(1))
        let session = ConversationID()
        buffer.receive(observation(session: session, sequence: 1, revision: 1, answer: "stale"))
        buffer.receive(observation(session: session, sequence: 2, revision: 2))

        #expect(buffer.observation?.value == nil)
        #expect(buffer.observation?.cursor.sequence == 2)
        buffer.flush()
        #expect(buffer.observation?.value == nil)
    }

    @Test func olderCursorOrRevisionCannotReplacePublishedOutput() {
        let buffer = ConversationStreamBuffer(interval: .seconds(1))
        let session = ConversationID()
        buffer.receive(observation(session: session, sequence: 4, revision: 8, answer: "current"))
        buffer.flush()
        buffer.receive(observation(session: session, sequence: 3, revision: 9, answer: "old cursor"))
        buffer.receive(observation(session: session, sequence: 4, revision: 7, answer: "old revision"))
        buffer.flush()

        #expect(buffer.observation?.value?.answer == "current")
        #expect(buffer.observation?.revision == 8)
    }


    @Test func staleClearCannotRollBackRevisionWatermark() {
        let buffer = ConversationStreamBuffer(interval: .seconds(1))
        let session = ConversationID()
        buffer.receive(observation(session: session, sequence: 1, revision: 10, answer: "current"))
        buffer.flush()
        buffer.receive(observation(session: session, sequence: 2, revision: 9))
        buffer.flush()

        #expect(buffer.observation?.value?.answer == "current")
        #expect(buffer.observation?.revision == 10)
    }

    @Test func foreignPendingAndClearObservationsAreRejected() {
        let buffer = ConversationStreamBuffer(interval: .seconds(1))
        let first = ConversationID()
        let second = ConversationID()
        buffer.receive(observation(session: first, sequence: 1, revision: 1, answer: "first"))
        buffer.receive(observation(session: second, sequence: 1, revision: 2, answer: "foreign"))
        buffer.receive(observation(session: second, sequence: 2, revision: 3))
        buffer.flush()

        #expect(buffer.observation?.value?.answer == "first")
        #expect(buffer.observation?.cursor.sessionID == first)
    }

    @Test func newerCursorWithOlderRevisionIsRejected() {
        let buffer = ConversationStreamBuffer(interval: .seconds(1))
        let session = ConversationID()
        buffer.receive(observation(session: session, sequence: 1, revision: 5, answer: "current"))
        buffer.flush()
        buffer.receive(observation(session: session, sequence: 2, revision: 4, answer: "rollback"))
        buffer.flush()

        #expect(buffer.observation?.value?.answer == "current")
        #expect(buffer.observation?.cursor.sequence == 1)
    }

    @Test func outputAfterClosingCannotRestoreVisibleText() {
        let buffer = ConversationStreamBuffer(interval: .seconds(1))
        let session = ConversationID()
        buffer.receive(observation(session: session, sequence: 1, revision: 1, answer: "visible"))
        buffer.flush()
        buffer.receive(observation(session: session, sequence: 2, revision: 2, isClosing: true))
        buffer.receive(observation(session: session, sequence: 3, revision: 3, answer: "late"))
        buffer.flush()

        #expect(buffer.observation?.value == nil)
        #expect(buffer.observation?.isClosing == true)
    }

    @Test func clearResetsSessionAcceptanceAndOldTimerCannotRestoreOutput() async throws {
        let buffer = ConversationStreamBuffer(interval: .milliseconds(20))
        let firstSession = ConversationID()
        buffer.receive(observation(session: firstSession, sequence: 9, revision: 9, answer: "revoked"))
        buffer.clear()
        let secondSession = ConversationID()
        buffer.receive(observation(session: secondSession, sequence: 1, revision: 1, answer: "new session"))
        buffer.flush()
        #expect(buffer.observation?.value?.answer == "new session")

        try await Task.sleep(for: .milliseconds(80))
        #expect(buffer.observation?.value?.answer == "new session")
        #expect(buffer.observation?.cursor.sessionID == secondSession)
    }

    @Test func closingObservationClearsVisibleValueImmediately() {
        let buffer = ConversationStreamBuffer(interval: .seconds(1))
        let session = ConversationID()
        buffer.receive(observation(session: session, sequence: 1, revision: 1, answer: "visible"))
        buffer.flush()
        buffer.receive(observation(session: session, sequence: 2, revision: 2, isClosing: true))

        #expect(buffer.observation?.isClosing == true)
        #expect(buffer.observation?.value == nil)
    }

    private func observation(
        session: ConversationID, sequence: Int64, revision: UInt64,
        execution: ExecutionID = .init(), attempt: UUID = UUID(), step: UUID = UUID(),
        answer: String? = nil, thinking: String = "",
        isClosing: Bool = false
    ) -> SessionOutputObservation {
        let output: SessionVisibleOutput? = answer.map {
            .init(executionID: execution, attemptID: attempt, stepID: step,
                  answer: $0, thinking: thinking)
        }
        return .init(cursor: .init(sessionID: session, sequence: sequence), revision: revision,
                     value: output, isClosing: isClosing)
    }
}
