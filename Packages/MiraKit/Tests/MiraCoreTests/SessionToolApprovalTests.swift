import Foundation
import Testing
@testable import MiraCore

@Suite("Session tool approval")
struct SessionToolApprovalTests {
    @Test func requestBindsPreparedInvocationAndDispatchRequiresApproval() throws {
        var fixture = try ApprovalFixture()
        try fixture.request()
        #expect(fixture.state.invocations[fixture.invocationID]?.approval?.approved == nil)
        #expect(throws: MiraError.self) { try fixture.dispatch() }
        try fixture.apply(.toolApprovalResolved(invocationID: fixture.invocationID, approved: true))
        try fixture.dispatch()
        #expect(fixture.state.invocations[fixture.invocationID]?.dispatchedAt != nil)
    }

    @Test func missingIntentDeniedApprovalAndRepeatedRequestsAreRejected() throws {
        var unprepared = try ApprovalFixture(prepared: false)
        #expect(throws: MiraError.self) { try unprepared.request() }
        var ready = try ApprovalFixture()
        try ready.request()
        #expect(throws: MiraError.self) { try ready.request() }
        try ready.apply(.toolApprovalResolved(invocationID: ready.invocationID, approved: false))
        #expect(throws: MiraError.self) { try ready.dispatch() }
        #expect(throws: MiraError.self) { try ready.request() }
        #expect(throws: MiraError.self) { try ready.apply(.toolApprovalResolved(invocationID: ready.invocationID, approved: true)) }
    }

    @Test func expiryRejectsGrantButAllowsDenial() throws {
        var fixture = try ApprovalFixture()
        let expiry = fixture.now.addingTimeInterval(1)
        try fixture.request(expiresAt: expiry)
        #expect(throws: MiraError.self) {
            try fixture.apply(.toolApprovalResolved(invocationID: fixture.invocationID, approved: true), at: expiry)
        }
        try fixture.apply(.toolApprovalResolved(invocationID: fixture.invocationID, approved: false), at: expiry.addingTimeInterval(1))
        #expect(fixture.state.invocations[fixture.invocationID]?.approval?.approved == false)
    }

    @Test func invalidExpiryAndSettlingCannotRequestApproval() throws {
        for offset in [0.0, -1, 86_401, .infinity] {
            var fixture = try ApprovalFixture()
            #expect(throws: MiraError.self) { try fixture.request(expiresAt: fixture.now.addingTimeInterval(offset)) }
        }
        var fixture = try ApprovalFixture()
        try fixture.apply(.phaseChanged(executionID: fixture.executionID, phase: .settling))
        #expect(throws: MiraError.self) { try fixture.request() }
    }

    @Test func cancellationAllowsOnlyDenialAndPendingApprovalMustBeSettled() throws {
        var fixture = try ApprovalFixture()
        try fixture.request()
        #expect(throws: MiraError.self) {
            try fixture.apply(.toolResolved(.init(invocationID: fixture.invocationID, status: .cancelledBeforeDispatch)))
        }
        try fixture.apply(.phaseChanged(executionID: fixture.executionID, phase: .cancelling))
        #expect(throws: MiraError.self) { try fixture.apply(.toolApprovalResolved(invocationID: fixture.invocationID, approved: true)) }
        try fixture.apply(.toolApprovalResolved(invocationID: fixture.invocationID, approved: false))
        try fixture.apply(.toolResolved(.init(invocationID: fixture.invocationID, status: .cancelledBeforeDispatch)))
        #expect(fixture.state.invocations[fixture.invocationID]?.resolution?.effectIsKnown == true)
    }
}

private struct ApprovalFixture {
    var state: SessionState
    let executionID = ExecutionID()
    let invocationID = UUID()
    let now = Date(timeIntervalSince1970: 1_000)

    init(prepared: Bool = true) throws {
        let sessionID = ConversationID()
        state = SessionState(id: sessionID)
        let openID = UUID()
        try apply([
            .opened(.init(workspaceID: nil, title: reference(batch: openID, kind: .title))),
            .admitted(.init(executionID: executionID, userMessageID: MessageID(),
                userBody: reference(batch: openID, kind: .userText), plan: reference(batch: openID, kind: .executionPlan), hasModelRoute: true,
                authorizationEpoch: 0, timeZoneIdentifier: "UTC"))
        ], batchID: openID)
        let attemptID = UUID(), startID = UUID()
        try apply([
            .phaseChanged(executionID: executionID, phase: .preparing),
            .attemptStarted(.init(id: attemptID, executionID: executionID, stepID: UUID(), stepIndex: 1,
                attemptIndex: 1, request: reference(batch: startID, kind: .request)))
        ], batchID: startID)
        let outputID = UUID()
        try apply([
            .attemptResolved(.init(attemptID: attemptID, status: .completed, output: reference(batch: outputID, kind: .modelOutput))),
            .toolProposed(.init(id: invocationID, attemptID: attemptID, modelOrder: 0, toolName: "write",
                effect: .externalWrite, call: reference(batch: outputID, kind: .toolCall))),
            .phaseChanged(executionID: executionID, phase: .waitingForTools)
        ], batchID: outputID)
        if prepared {
            let batchID = UUID()
            try apply([.toolPrepared(.init(invocationID: invocationID,
                authorization: .init(libraryID: UUID(), epoch: 1),
                proposal: reference(batch: batchID, kind: .effectIntent)))], batchID: batchID)
        }
    }

    mutating func request(expiresAt: Date? = nil) throws {
        try apply(.toolApprovalRequested(invocationID: invocationID, expiresAt: expiresAt ?? now.addingTimeInterval(60)))
    }
    mutating func dispatch() throws {
        try apply(.toolDispatched(invocationID: invocationID, authorizationEpoch: 0))
    }
    mutating func apply(_ fact: SessionFact, at date: Date? = nil) throws { try apply([fact], at: date) }
    private mutating func apply(_ facts: [SessionFact], batchID: UUID = UUID(), at date: Date? = nil) throws {
        let batch = SessionBatch(id: batchID, sessionID: state.id, expectedSequence: state.sequence,
            events: facts.enumerated().map { offset, fact in
                .init(sequence: state.sequence + Int64(offset) + 1, occurredAt: date ?? now, fact: fact)
            })
        try state.apply(batch)
    }
    private func reference(batch: UUID, kind: SessionPayloadKind) -> SessionPayloadReference {
        .init(id: UUID(), sessionID: state.id, batchID: batch, retentionGroup: UUID(), kind: kind,
            byteCount: 1, digest: String(repeating: "0", count: 64))
    }
}
