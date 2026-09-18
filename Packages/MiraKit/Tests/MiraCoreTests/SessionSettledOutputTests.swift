import Foundation
import Testing
@testable import MiraCore

@Suite("Settled session output")
struct SessionSettledOutputTests {
    @Test func usesLatestSettledAnswerAndAccumulatesThinking() async throws {
        let executionID = ExecutionID()
        let admission = SessionAdmission(
            executionID: executionID, userMessageID: MessageID(), userBody: nil,
            plan: .init(kind: .executionPlan, bytes: Data()), hasModelRoute: true,
            authorizationEpoch: 0, timeZoneIdentifier: "UTC")
        var execution = SessionExecutionState(
            admission: admission, admittedAt: Date(), admissionEventID: UUID(),
            admissionSequence: 1, admissionBatchID: UUID())
        let firstID = UUID(), secondID = UUID()
        execution.attemptIDs = [firstID, secondID]

        let firstOutput = AgentModelOutput(
            blocks: [
                .init(id: "thinking-1", content: .thinking("Plan. ")),
                .init(id: "answer-1", content: .text("intermediate")),
            ], continuation: nil, usage: .init(), finishReason: .stop)
        let secondOutput = AgentModelOutput(
            blocks: [
                .init(id: "thinking-2", content: .thinking("Revise.")),
                .init(id: "answer-2", content: .text("final")),
            ], continuation: nil, usage: .init(), finishReason: .stop)
        let firstReference = SessionContent(kind: .modelOutput, bytes: try SessionCodec.encode(firstOutput))
        let secondReference = SessionContent(kind: .modelOutput, bytes: try SessionCodec.encode(secondOutput))
        var first = SessionAttemptState(
            attempt: .init(id: firstID, executionID: executionID, stepID: UUID(), stepIndex: 1,
                           attemptIndex: 1, request: .init(kind: .request, bytes: Data())),
            sequence: 2, startedAt: Date())
        first.resolution = .init(attemptID: firstID, status: .completed, output: firstReference)
        var second = SessionAttemptState(
            attempt: .init(id: secondID, executionID: executionID, stepID: UUID(), stepIndex: 2,
                           attemptIndex: 1, request: .init(kind: .request, bytes: Data())),
            sequence: 3, startedAt: Date())
        second.resolution = .init(attemptID: secondID, status: .completed, output: secondReference)

        let output = try await SessionSettledOutput.read(
            execution: execution, attempts: [firstID: first, secondID: second],
            payloads: SettledOutputReader(values: [firstReference.id: firstReference.bytes,
                                                    secondReference.id: secondReference.bytes]))
        #expect(output.answer == "final")
        #expect(output.thinking == "Plan. Revise.")
    }
}

private struct SettledOutputReader: SessionContentReader {
    let values: [UUID: Data]

    func read(_ reference: SessionContent) async throws -> Data {
        guard let value = values[reference.id] else { throw MiraError(.notFound, "Missing test output.") }
        return value
    }
}
