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

    @Test func retryCleanupIsAtomicWithAdmissionAndPreservesQuestionAndPlan() throws {
        var fixture = try StateFixture.failedWithVisiblePayloads()
        let retryBatchID = UUID()
        let retryID = ExecutionID()
        let retry = fixture.retryAdmission(executionID: retryID, batchID: retryBatchID)
        let groups = fixture.state.retryCleanupGroups(forUserMessageID: fixture.userID)
        try fixture.state.apply(fixture.batch([
            .admitted(retry),
            .retryCleared(.init(sourceExecutionID: fixture.executionID,
                retryExecutionID: retryID, retentionGroups: groups)),
        ], id: retryBatchID))

        #expect(fixture.state.invalidatedRetentionGroups == groups)
        #expect(fixture.state.references.values.contains { $0.kind == .userText &&
            !fixture.state.invalidatedRetentionGroups.contains($0.retentionGroup) })
        #expect(fixture.state.references.values.contains { $0.kind == .executionPlan &&
            !fixture.state.invalidatedRetentionGroups.contains($0.retentionGroup) })
        #expect(fixture.state.executions[fixture.executionID]?.completion?.status == .failed)
        #expect(fixture.state.executions[retryID]?.completion == nil)
    }

    @Test func retryCleanupCannotBePublishedInASeparateBatch() throws {
        var fixture = try StateFixture.failedWithVisiblePayloads()
        let retryBatchID = UUID()
        let retryID = ExecutionID()
        let retry = fixture.retryAdmission(executionID: retryID, batchID: retryBatchID)
        let groups = fixture.state.retryCleanupGroups(forUserMessageID: fixture.userID)
        try fixture.state.apply(fixture.batch([.admitted(retry)], id: retryBatchID))
        let before = fixture.state
        #expect(throws: MiraError.self) {
            try fixture.state.apply(fixture.batch([
                .retryCleared(.init(sourceExecutionID: fixture.executionID,
                    retryExecutionID: retryID, retentionGroups: groups)),
            ]))
        }
        #expect(fixture.state == before)
        #expect(fixture.state.invalidatedRetentionGroups.isEmpty)
    }

    @Test func retryCleanupRejectsMissingOrForeignGroupsAndRollsBackAdmission() throws {
        let wrongGroups: [Set<UUID>] = [[], [UUID()]]
        for groups in wrongGroups {
            var fixture = try StateFixture.failedWithVisiblePayloads()
            let retryBatchID = UUID()
            let retryID = ExecutionID()
            let retry = fixture.retryAdmission(executionID: retryID, batchID: retryBatchID)
            let before = fixture.state
            #expect(throws: MiraError.self) {
                try fixture.state.apply(fixture.batch([
                    .admitted(retry),
                    .retryCleared(.init(sourceExecutionID: fixture.executionID,
                        retryExecutionID: retryID, retentionGroups: groups)),
                ], id: retryBatchID))
            }
            #expect(fixture.state == before)
        }
    }

    @Test func retryCleanupAllowsEmptyGroupsWhenFailureProducedNoGeneratedBodies() throws {
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
            .retryCleared(.init(sourceExecutionID: fixture.executionID,
                retryExecutionID: retryID, retentionGroups: [])),
        ], id: retryBatchID))
        #expect(fixture.state.invalidatedRetentionGroups.isEmpty)
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
        let forgedResult = SessionPayloadReference(id: UUID(), sessionID: fixture.state.id, batchID: forgedResultBatchID,
            retentionGroup: UUID(), kind: .toolResult, byteCount: 1, digest: String(repeating: "b", count: 64))
        #expect(throws: MiraError.self) {
            try fixture.state.apply(fixture.batch([.toolResolved(.init(invocationID: tool.id, status: .succeeded,
                result: forgedResult, businessReceipt: valid))], id: forgedResultBatchID))
        }
    }

    @Test func purgedBusinessReceiptKeepsCommittedEffectKnown() throws {
        var fixture = StateFixture()
        let tool = try fixture.makeTool(effect: .localWrite)
        let authorization = fixture.authorization()
        let intentBatchID = UUID()
        let intent = try fixture.intent(for: tool, batchID: intentBatchID, authorization: authorization)
        try fixture.state.apply(fixture.batch([.toolPrepared(intent),
            .toolDispatched(invocationID: tool.id, authorizationEpoch: 0)], id: intentBatchID))
        let result = fixture.reference(kind: .toolResult, batchID: UUID())
        let receipt = fixture.receipt(for: tool, intent: intent, result: result)
        try fixture.state.apply(fixture.batch([.toolResolved(.init(invocationID: tool.id, status: .succeeded,
            businessReceipt: receipt, resultWasPurged: true))], id: result.batchID))
        let finishBatchID = UUID()
        try fixture.state.apply(fixture.batch([.phaseChanged(executionID: fixture.executionID, phase: .settling),
            .finished(.init(executionID: fixture.executionID, status: .completed,
                assistantMessageID: MessageID(), answer: fixture.reference(kind: .visibleAnswer, batchID: finishBatchID)))], id: finishBatchID))
        #expect(fixture.state.executions[fixture.executionID]?.completion?.status == .completed)
        #expect(fixture.state.invocations[tool.id]?.resolution?.effectIsKnown == true)
        #expect(fixture.state.invocations[tool.id]?.resolution?.result == nil)
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

    @Test func draftRejectsLateAttemptCallbacksAndTerminalSettlementIsUnique() throws {
        var fixture = StateFixture(); try fixture.startAttempt()
        let attempt = try #require(fixture.state.attempts.values.first?.attempt)
        let draftBatchID = UUID(); let group = UUID()
        let draft = fixture.reference(kind: .draft, batchID: draftBatchID, group: group, count: 4)
        let checkpoint = SessionDraftCheckpoint(executionID: fixture.executionID, attemptID: attempt.id,
            part: .answer, baseSequence: nil, prefixByteCount: 0, suffixByteCount: 0,
            replacement: draft, resultByteCount: 4)
        try fixture.state.apply(fixture.batch([.draftCheckpoint(checkpoint)], id: draftBatchID))
        let previousSequence = fixture.state.sequence
        try fixture.apply([.attemptResolved(.init(attemptID: attempt.id, status: .failed)),
            .phaseChanged(executionID: fixture.executionID, phase: .preparing)])
        let retry = SessionAttempt(id: UUID(), executionID: fixture.executionID, stepID: attempt.stepID,
            stepIndex: 1, attemptIndex: 2, request: attempt.request)
        try fixture.apply([.attemptStarted(retry)])
        let lateBatchID = UUID()
        let late = SessionDraftCheckpoint(executionID: fixture.executionID, attemptID: attempt.id,
            part: .answer, baseSequence: previousSequence, prefixByteCount: 4, suffixByteCount: 0,
            replacement: fixture.reference(kind: .draft, batchID: lateBatchID, group: group, count: 1), resultByteCount: 5)
        #expect(throws: MiraError.self) { try fixture.state.apply(fixture.batch([.draftCheckpoint(late)], id: lateBatchID)) }
        #expect(throws: MiraError.self) { try fixture.apply([.finished(.init(executionID: fixture.executionID, status: .failed))]) }
        try fixture.apply([.phaseChanged(executionID: fixture.executionID, phase: .cancelling),
            .attemptResolved(.init(attemptID: retry.id, status: .interrupted)),
            .finished(.init(executionID: fixture.executionID, status: .cancelled))])
        #expect(fixture.state.executions[fixture.executionID]?.drafts.isEmpty == true)
        #expect(throws: MiraError.self) { try fixture.apply([.finished(.init(executionID: fixture.executionID, status: .cancelled))]) }
    }

    @Test func invalidationPurgesHiddenLifetimeAndPreservesVisibleHistory() throws {
        var fixture = StateFixture(); try fixture.startAttempt()
        let hidden = Set(fixture.state.references.values.filter { [.executionPlan, .request].contains($0.kind) }.map(\.retentionGroup))
        let before = fixture.state
        #expect(throws: MiraError.self) {
            try fixture.apply([.invalidated(.init(operationID: UUID(), executionIDs: [fixture.executionID],
                retentionGroups: [], authorizationEpoch: 1, reason: .forgotten))])
        }
        #expect(fixture.state == before)
        try fixture.apply([.invalidated(.init(operationID: UUID(), executionIDs: [fixture.executionID],
            retentionGroups: hidden, authorizationEpoch: 1, reason: .forgotten))])
        #expect(fixture.state.excludedExecutionIDs == [fixture.executionID])
        #expect(fixture.state.references.values.filter { $0.kind == .userText }
            .allSatisfy { !fixture.state.invalidatedRetentionGroups.contains($0.retentionGroup) })
        #expect(throws: MiraError.self) { try fixture.apply([.phaseChanged(executionID: fixture.executionID, phase: .preparing)]) }
    }

    @Test func payloadLifetimesAndRequiredExtensionsAreValidated() throws {
        var fixture = StateFixture(); try fixture.open()
        let batchID = UUID(); let shared = UUID()
        let admission = SessionAdmission(executionID: fixture.executionID, userMessageID: fixture.userID,
            userBody: fixture.reference(kind: .userText, batchID: batchID, group: shared),
            plan: fixture.reference(kind: .executionPlan, batchID: batchID, group: shared), hasModelRoute: true, authorizationEpoch: 0,
            timeZoneIdentifier: "UTC")
        #expect(throws: MiraError.self) { try fixture.state.apply(fixture.batch([.admitted(admission)], id: batchID)) }
        let body = fixture.reference(kind: .module, batchID: batchID)
        let required = fixture.batch([.extensionRecorded(namespace: "test.event", schemaVersion: 2, required: true, body: body)], id: batchID)
        #expect(throws: MiraError.self) { try fixture.state.apply(required) }
        try fixture.state.apply(required, extensionSchemas: ["test.event": [2]])
        try fixture.apply([.invalidated(.init(operationID: UUID(), executionIDs: [],
            retentionGroups: [body.retentionGroup], authorizationEpoch: 1, reason: .forgotten))])
        #expect(fixture.state.invalidatedRetentionGroups.contains(body.retentionGroup))
    }

    @Test func bytePatchesRoundTripUnicodeAndHaveLinearAppendStorage() throws {
        // Unicode is synthetic test content for byte-level patch boundary coverage.
        let snapshots = ["a☕z", "a🌍z", "", "字", "字🙂"] // i18n-fixture: Synthetic Unicode patch boundaries.
        var previous = Data(); var sequence: Int64?; var storedBytes = 0
        let fixture = StateFixture(); let group = UUID()
        for (index, snapshot) in snapshots.enumerated() {
            let current = Data(snapshot.utf8)
            let patch = try SessionDraftPatch(previous: previous, current: current)
            let checkpoint = SessionDraftCheckpoint(executionID: fixture.executionID, attemptID: UUID(), part: .thinking,
                baseSequence: sequence, prefixByteCount: patch.prefixByteCount, suffixByteCount: patch.suffixByteCount,
                replacement: fixture.reference(kind: .draft, batchID: UUID(), group: group, count: patch.replacement.count),
                resultByteCount: patch.resultByteCount)
            #expect(try SessionDraftPatch.apply(checkpoint, replacement: patch.replacement,
                previous: previous, previousSequence: sequence) == current)
            previous = current; sequence = Int64(index + 1)
        }
        previous = Data()
        for _ in 0..<128 {
            let current = previous + Data(repeating: 120, count: 1024)
            let patch = try SessionDraftPatch(previous: previous, current: current)
            storedBytes += patch.replacement.count; previous = current
        }
        #expect(storedBytes == 128 * 1024)
    }
}

private struct StateFixture {
    var state = SessionState(id: ConversationID())
    let executionID = ExecutionID()
    let userID = MessageID()

    func reference(kind: SessionPayloadKind, batchID: UUID, group: UUID = UUID(), count: Int = 1) -> SessionPayloadReference {
        .init(id: UUID(), sessionID: state.id, batchID: batchID, retentionGroup: group,
              kind: kind, byteCount: count, digest: String(repeating: "a", count: 64))
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
            callDigest: String(repeating: "a", count: 64), inheritedSources: [],
            plan: .init(input: .object([:]), sources: [], targets: []))
        let bytes = try SessionCodec.encode(proposal)
        let reference = SessionPayloadReference(id: UUID(), sessionID: state.id, batchID: batchID,
            retentionGroup: UUID(), kind: .effectIntent, byteCount: bytes.count,
            digest: String(repeating: "a", count: 64))
        return .init(invocationID: invocation.id, authorization: authorization, proposal: reference)
    }

    func receipt(for invocation: SessionInvocation, intent: SessionEffectIntent,
                 result: SessionPayloadReference) -> AgentBusinessReceiptReference {
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
