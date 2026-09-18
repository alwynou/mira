import Foundation
import Testing
@testable import MiraCore

@Suite("Session state invariants")
struct SessionStateTests {
    @Test func rejectsWholeBatchWithoutPartialAdmission() throws {
        var fixture = StateFixture()
        try fixture.open()
        let before = fixture.state
        let batchID = UUID()
        let admission = fixture.admission(batchID: batchID)
        let batch = fixture.batch([.admitted(admission), .admitted(admission)], id: batchID)
        #expect(throws: MiraError.self) { try fixture.state.apply(batch) }
        #expect(fixture.state == before)
        try fixture.state.apply(fixture.batch([.admitted(admission)], id: batchID))
        #expect(fixture.state.activeExecutionID == admission.executionID)
    }

    @Test func retrySupersessionIsAtomicWithAdmissionAndPreservesQuestionAndPlan() throws {
        var fixture = try StateFixture.failedWithVisiblePayloads()
        let retryBatchID = UUID()
        let retryID = ExecutionID()
        let retry = fixture.retryAdmission(executionID: retryID, batchID: retryBatchID)
        try fixture.state.apply(fixture.batch([
            .admitted(retry),
            .retrySuperseded(.init(sourceExecutionID: fixture.executionID, retryExecutionID: retryID)),
        ], id: retryBatchID))

        #expect(fixture.state.supersededExecutionIDs.contains(fixture.executionID))
        #expect(fixture.state.executions[fixture.executionID]?.completion?.status == .failed)
        #expect(fixture.state.executions[retryID]?.completion == nil)
    }

    @Test func retrySupersessionCannotBePublishedInASeparateBatch() throws {
        var fixture = try StateFixture.failedWithVisiblePayloads()
        let retryBatchID = UUID()
        let retryID = ExecutionID()
        let retry = fixture.retryAdmission(executionID: retryID, batchID: retryBatchID)
        try fixture.state.apply(fixture.batch([.admitted(retry)], id: retryBatchID))
        let before = fixture.state
        #expect(throws: MiraError.self) {
            try fixture.state.apply(fixture.batch([
                .retrySuperseded(.init(sourceExecutionID: fixture.executionID, retryExecutionID: retryID)),
            ]))
        }
        #expect(fixture.state == before)
    }

    @Test func retrySupersessionAllowsFailureWithoutGeneratedBodies() throws {
        var fixture = StateFixture()
        try fixture.open()
        let firstBatchID = UUID()
        var initial = fixture.admission(batchID: firstBatchID)
        initial = .init(executionID: initial.executionID, userMessageID: initial.userMessageID,
            userBody: initial.userBody, plan: initial.plan, hasModelRoute: false,
            authorizationEpoch: initial.authorizationEpoch, timeZoneIdentifier: initial.timeZoneIdentifier)
        try fixture.state.apply(fixture.batch([
            .admitted(initial),
            .phaseChanged(executionID: fixture.executionID, phase: .preparing),
            .phaseChanged(executionID: fixture.executionID, phase: .settling),
            .finished(.init(executionID: fixture.executionID, status: .failed)),
        ], id: firstBatchID))
        let retryBatchID = UUID()
        let retryID = ExecutionID()
        let retry = fixture.retryAdmission(executionID: retryID, batchID: retryBatchID, hasModelRoute: false)
        try fixture.state.apply(fixture.batch([
            .admitted(retry),
            .retrySuperseded(.init(sourceExecutionID: fixture.executionID, retryExecutionID: retryID)),
        ], id: retryBatchID))
        #expect(fixture.state.executions[retryID]?.completion == nil)
    }

    @Test func toolsMustBeAtomicWithOutputAndWritesRequireReceipts() throws {
        var fixture = StateFixture(); try fixture.startAttempt()
        let attempt = try #require(fixture.state.attempts.values.first?.attempt)
        let batchID = UUID()
        let resolution = SessionAttemptResolution(attemptID: attempt.id, status: .completed,
            output: fixture.reference(kind: .modelOutput, batchID: batchID))
        let tool = SessionInvocation(id: UUID(), attemptID: attempt.id, modelOrder: 0,
            toolName: "test.write", effect: .localWrite, call: fixture.reference(kind: .toolCall, batchID: batchID))
        try fixture.state.apply(fixture.batch([.attemptResolved(resolution), .toolProposed(tool),
            .phaseChanged(executionID: fixture.executionID, phase: .waitingForTools)], id: batchID))
        #expect(throws: MiraError.self) { try fixture.apply([.toolProposed(tool)]) }
        let before = fixture.state
        #expect(throws: MiraError.self) {
            try fixture.apply([.toolDispatched(invocationID: tool.id, authorizationEpoch: 0),
                .toolResolved(.init(invocationID: tool.id, status: .succeeded))])
        }
        #expect(fixture.state == before)
        let authorization = fixture.authorization()
        let intentBatchID = UUID()
        let intent = try fixture.intent(for: tool, batchID: intentBatchID, authorization: authorization)
        try fixture.state.apply(fixture.batch([.toolPrepared(intent)], id: intentBatchID))
        #expect(throws: MiraError.self) { try fixture.apply([.toolPrepared(intent)]) }
        try fixture.apply([.toolDispatched(invocationID: tool.id, authorizationEpoch: 0)])
        let resultBatchID = UUID()
        let result = fixture.reference(kind: .toolResult, batchID: resultBatchID)
        let receipt = fixture.receipt(for: tool, intent: intent, result: result)
        try fixture.state.apply(fixture.batch([.toolResolved(.init(invocationID: tool.id, status: .succeeded,
            result: result, businessReceipt: receipt))], id: resultBatchID))
        #expect(fixture.state.invocations[tool.id]?.resolution?.businessReceipt != nil)
        #expect(throws: MiraError.self) { try fixture.apply([.toolDispatched(invocationID: tool.id, authorizationEpoch: 0)]) }
    }

    @Test func forgedBusinessReceiptsAreRejected() throws {
        var fixture = StateFixture()
        let tool = try fixture.makeTool(effect: .localWrite)
        let authorization = fixture.authorization()
        let intentBatchID = UUID()
        let intent = try fixture.intent(for: tool, batchID: intentBatchID, authorization: authorization)
        try fixture.state.apply(fixture.batch([.toolPrepared(intent),
            .toolDispatched(invocationID: tool.id, authorizationEpoch: 0)], id: intentBatchID))
        let resultBatchID = UUID()
        let result = fixture.reference(kind: .toolResult, batchID: resultBatchID)
        let valid = fixture.receipt(for: tool, intent: intent, result: result)
        let wrongInvocation = AgentBusinessReceiptReference(id: valid.id, invocationID: UUID(), authorization: valid.authorization,
            intentDigest: valid.intentDigest, resultDigest: valid.resultDigest)
        let wrongAuthorization = AgentBusinessReceiptReference(id: valid.id, invocationID: tool.id,
            authorization: .init(libraryID: valid.authorization.libraryID, epoch: valid.authorization.epoch + 1),
            intentDigest: valid.intentDigest, resultDigest: valid.resultDigest)
        let wrongIntentHash = AgentBusinessReceiptReference(id: valid.id, invocationID: tool.id, authorization: valid.authorization,
            intentDigest: String(repeating: "b", count: 64), resultDigest: valid.resultDigest)
        let wrongResultHash = AgentBusinessReceiptReference(id: valid.id, invocationID: tool.id, authorization: valid.authorization,
            intentDigest: valid.intentDigest, resultDigest: String(repeating: "b", count: 64))
        for receipt in [wrongInvocation, wrongAuthorization, wrongIntentHash, wrongResultHash] {
            #expect(throws: MiraError.self) {
                try fixture.state.apply(fixture.batch([.toolResolved(.init(invocationID: tool.id, status: .succeeded,
                    result: result, businessReceipt: receipt))], id: resultBatchID))
            }
        }
        let forgedResultBatchID = UUID()
        let forgedResult = SessionContent(id: UUID(), kind: .toolResult, bytes: Data("x".utf8))
        #expect(throws: MiraError.self) {
            try fixture.state.apply(fixture.batch([.toolResolved(.init(invocationID: tool.id, status: .succeeded,
                result: forgedResult, businessReceipt: valid))], id: forgedResultBatchID))
        }
    }

    @Test func unknownWriteEffectBlocksContinuationAndWholeTurnRetry() throws {
        var fixture = StateFixture()
        let tool = try fixture.makeTool(effect: .externalWrite)
        let batchID = UUID()
        let intent = try fixture.intent(for: tool, batchID: batchID, authorization: fixture.authorization())
        try fixture.state.apply(fixture.batch([
            .toolPrepared(intent),
            .toolDispatched(invocationID: tool.id, authorizationEpoch: 0),
            .toolResolved(.init(invocationID: tool.id, status: .interrupted, effectIsKnown: false)),
            .phaseChanged(executionID: fixture.executionID, phase: .preparing)
        ], id: batchID))
        let nextBatchID = UUID()
        let nextAttempt = SessionAttempt(id: UUID(), executionID: fixture.executionID, stepID: UUID(),
            stepIndex: 2, attemptIndex: 1, request: fixture.reference(kind: .request, batchID: nextBatchID))
        #expect(throws: MiraError.self) { try fixture.state.apply(fixture.batch([.attemptStarted(nextAttempt)], id: nextBatchID)) }
        try fixture.apply([.phaseChanged(executionID: fixture.executionID, phase: .settling),
            .finished(.init(executionID: fixture.executionID, status: .interrupted))])
        let retryBatchID = UUID()
        let retry = SessionAdmission(executionID: ExecutionID(), userMessageID: fixture.userID,
            retryOfExecutionID: fixture.executionID, userBody: nil,
            plan: fixture.reference(kind: .executionPlan, batchID: retryBatchID), hasModelRoute: true, authorizationEpoch: 0,
            timeZoneIdentifier: "UTC")
        #expect(throws: MiraError.self) { try fixture.state.apply(fixture.batch([.admitted(retry)], id: retryBatchID)) }
    }

    @Test func terminalSettlementIsUnique() throws {
        var fixture = StateFixture(); try fixture.startAttempt()
        let attempt = try #require(fixture.state.attempts.values.first?.attempt)
        try fixture.apply([.attemptResolved(.init(attemptID: attempt.id, status: .failed)),
            .phaseChanged(executionID: fixture.executionID, phase: .preparing)])
        let retry = SessionAttempt(id: UUID(), executionID: fixture.executionID, stepID: attempt.stepID,
            stepIndex: 1, attemptIndex: 2, request: attempt.request)
        try fixture.apply([.attemptStarted(retry)])
        #expect(throws: MiraError.self) { try fixture.apply([.finished(.init(executionID: fixture.executionID, status: .failed))]) }
        try fixture.apply([.phaseChanged(executionID: fixture.executionID, phase: .cancelling),
            .attemptResolved(.init(attemptID: retry.id, status: .interrupted)),
            .finished(.init(executionID: fixture.executionID, status: .cancelled))])
        #expect(throws: MiraError.self) { try fixture.apply([.finished(.init(executionID: fixture.executionID, status: .cancelled))]) }
    }

    @Test func inlineContentAndRequiredExtensionsAreValidated() throws {
        var fixture = StateFixture(); try fixture.open()
        let batchID = UUID(); let shared = UUID()
        let admission = SessionAdmission(executionID: fixture.executionID, userMessageID: fixture.userID,
            userBody: fixture.reference(kind: .userText, batchID: batchID, group: shared),
            plan: fixture.reference(kind: .executionPlan, batchID: batchID, group: shared), hasModelRoute: true, authorizationEpoch: 0,
            timeZoneIdentifier: "UTC")
        try fixture.state.apply(fixture.batch([.admitted(admission)], id: batchID))
        let body = fixture.reference(kind: .module, batchID: UUID())
        let required = fixture.batch([.extensionRecorded(namespace: "test.event", schemaVersion: 2, required: true, body: body)])
        #expect(throws: MiraError.self) { try fixture.state.apply(required) }
        let supported = fixture.batch([.extensionRecorded(namespace: "test.event", schemaVersion: 2, required: true, body: body)])
        try fixture.state.apply(supported, extensionSchemas: ["test.event": [2]])
    }

}

private struct StateFixture {
    var state = SessionState(id: ConversationID())
    let executionID = ExecutionID()
    let userID = MessageID()

    func reference(kind: SessionContentKind, batchID: UUID, group: UUID = UUID(), count: Int = 1) -> SessionContent {
        .init(id: UUID(), kind: kind, bytes: Data(repeating: 97, count: count))
    }

    func batch(_ facts: [SessionFact], id: UUID = UUID()) -> SessionBatch {
        .init(id: id, sessionID: state.id, expectedSequence: state.sequence,
              events: facts.enumerated().map { .init(sequence: state.sequence + Int64($0.offset) + 1,
                  occurredAt: Date(timeIntervalSince1970: 1), fact: $0.element) })
    }

    mutating func apply(_ facts: [SessionFact]) throws { try state.apply(batch(facts)) }

    mutating func open() throws {
        let id = UUID()
        try state.apply(batch([.opened(.init(workspaceID: nil, title: reference(kind: .title, batchID: id)))], id: id))
    }

    func admission(batchID: UUID) -> SessionAdmission {
        .init(executionID: executionID, userMessageID: userID,
              userBody: reference(kind: .userText, batchID: batchID),
              plan: reference(kind: .executionPlan, batchID: batchID), hasModelRoute: true, authorizationEpoch: 0,
              timeZoneIdentifier: "UTC")
    }

    func retryAdmission(executionID: ExecutionID, batchID: UUID, hasModelRoute: Bool = true) -> SessionAdmission {
        .init(executionID: executionID, userMessageID: userID, retryOfExecutionID: self.executionID,
            userBody: nil, plan: reference(kind: .executionPlan, batchID: batchID),
            hasModelRoute: hasModelRoute, authorizationEpoch: state.authorizationEpoch,
            timeZoneIdentifier: "UTC")
    }

    static func failedWithVisiblePayloads() throws -> StateFixture {
        var fixture = StateFixture()
        try fixture.startAttempt()
        let attempt = try #require(fixture.state.attempts.values.first?.attempt)
        let batchID = UUID()
        let error = fixture.reference(kind: .error, batchID: batchID)
        let answer = fixture.reference(kind: .visibleAnswer, batchID: batchID)
        let thinking = fixture.reference(kind: .visibleThinking, batchID: batchID)
        try fixture.state.apply(fixture.batch([
            .attemptResolved(.init(attemptID: attempt.id, status: .failed, error: error)),
            .phaseChanged(executionID: fixture.executionID, phase: .settling),
            .finished(.init(executionID: fixture.executionID, status: .failed,
                assistantMessageID: MessageID(), answer: answer, visibleThinking: thinking, error: error)),
        ], id: batchID))
        return fixture
    }

    mutating func makeTool(effect: SessionEffectKind) throws -> SessionInvocation {
        try startAttempt()
        let attempt = try #require(state.attempts.values.first?.attempt)
        let batchID = UUID()
        let tool = SessionInvocation(id: UUID(), attemptID: attempt.id, modelOrder: 0,
            toolName: effect == .localWrite ? "test.write" : "test.read", effect: effect,
            call: reference(kind: .toolCall, batchID: batchID))
        try state.apply(batch([.attemptResolved(.init(attemptID: attempt.id, status: .completed,
                output: reference(kind: .modelOutput, batchID: batchID))), .toolProposed(tool),
            .phaseChanged(executionID: executionID, phase: .waitingForTools)], id: batchID))
        return tool
    }

    func authorization() -> AgentLibraryAuthorization {
        .init(libraryID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, epoch: 7)
    }

    func intent(for invocation: SessionInvocation, batchID: UUID,
                authorization: AgentLibraryAuthorization) throws -> SessionEffectIntent {
        let descriptor = AgentToolDescriptor(definition: .init(name: invocation.toolName,
            description: "Synthetic tool", inputSchema: .object(["type": .string("object")])), revision: 1,
            outputSchema: .object(["type": .string("object")]), executionMode: .ordered,
            timeoutMilliseconds: 1_000, maximumResultBytes: 1_024)
        let proposal = AgentToolProposal(descriptor: descriptor, effect: invocation.effect,
            businessNamespace: invocation.effect == .localWrite ? "test.write" : nil,
            callDigest: String(repeating: "a", count: 64),
            plan: .init(input: .object([:]), sources: [], targets: []))
        let bytes = try SessionCodec.encode(proposal)
        let reference = SessionContent(id: UUID(), kind: .effectIntent, bytes: bytes)
        return .init(invocationID: invocation.id, authorization: authorization, proposal: reference)
    }

    func receipt(for invocation: SessionInvocation, intent: SessionEffectIntent,
                 result: SessionContent) -> AgentBusinessReceiptReference {
        .init(id: UUID(), invocationID: invocation.id, authorization: intent.authorization,
              intentDigest: intent.proposal.digest, resultDigest: result.digest)
    }

    mutating func startAttempt() throws {
        try open()
        let id = UUID()
        try state.apply(batch([.admitted(admission(batchID: id)),
            .phaseChanged(executionID: executionID, phase: .preparing),
            .attemptStarted(.init(id: UUID(), executionID: executionID, stepID: UUID(), stepIndex: 1,
                attemptIndex: 1, request: reference(kind: .request, batchID: id)))], id: id))
    }
}
