import Foundation
import Testing

@testable import MiraCore

@Suite("Agent library restoration")
struct AgentLibraryRestorationTests {
    @Test func emptyLibraryRestoresAndCloses() async throws {
        let journal = RestorationJournal()
        let receipts = RestorationReceipts()
        let service = AgentLibraryRestoration(
            journal: journal, payloads: journal, receipts: receipts,
            authorizer: RestorationAuthorizer())

        #expect(try await service.restore().isEmpty)
        await service.close()
        await #expect(throws: MiraError.self) { try await service.restore() }
    }

    @Test func callerCancellationDoesNotCancelAcceptedRestore() async throws {
        let journal = RestorationJournal(waitForFirstSessionsCall: true)
        let service = AgentLibraryRestoration(
            journal: journal, payloads: journal, receipts: RestorationReceipts(),
            authorizer: RestorationAuthorizer())

        let caller = Task { try await service.restore() }
        await journal.waitForFirstSessionsCall()
        caller.cancel()
        let close = Task { await service.close() }
        await journal.releaseFirstSessionsCall()

        #expect(try await caller.value.isEmpty)
        await close.value
    }

    @Test func oversizedSessionPageFailsBeforeOpeningAState() async throws {
        let journal = RestorationJournal(sessionIDs: (0..<129).map { _ in ConversationID() })
        let service = AgentLibraryRestoration(
            journal: journal, payloads: journal, receipts: RestorationReceipts(),
            authorizer: RestorationAuthorizer())

        do {
            _ = try await service.restore()
            Issue.record("An oversized session page was accepted")
        } catch let error as MiraError {
            #expect(error.code == .storage)
            #expect(await journal.openCount == 0)
        }
        await service.close()
    }

    @Test func receiptForUnknownSessionIsRejectedWithoutAcknowledgement() async throws {
        let journal = RestorationJournal()
        let authorization = AgentLibraryAuthorization(libraryID: UUID(), epoch: 1)
        let proposal = SessionPayloadReference(
            id: UUID(), sessionID: ConversationID(), batchID: UUID(), retentionGroup: UUID(),
            kind: .effectIntent, byteCount: 1, digest: String(repeating: "a", count: 64))
        let proof = AgentEffectProof(
            sessionID: proposal.sessionID, executionID: ExecutionID(), invocationID: UUID(),
            intentBatchID: proposal.batchID, intentSequence: 1,
            authorization: authorization, proposal: proposal)
        let receipt = AgentBusinessReceipt(
            reference: .init(
                id: UUID(), invocationID: proof.invocationID,
                authorization: authorization,
                intentDigest: proposal.digest,
                resultDigest: String(repeating: "b", count: 64)),
            result: nil)
        let receipts = RestorationReceipts(publications: [.init(proof: proof, receipt: receipt)])
        let service = AgentLibraryRestoration(
            journal: journal, payloads: journal, receipts: receipts,
            authorizer: RestorationAuthorizer())

        await #expect(throws: MiraError.self) { try await service.restore() }
        #expect(await receipts.acknowledged.isEmpty)
        await service.close()
    }

    @Test func activeLocalExecutionIsSettledWithoutAProvider() async throws {
        let journal = RestorationJournal()
        let sessionID = ConversationID()
        let runtime = try await SessionRuntime.open(id: sessionID, journal: journal, payloads: journal)
        let opened = await runtime.commit(id: UUID()) { context in
            let title = try await context.stageBytes(
                Data("Restored session".utf8), kind: .title, retentionGroup: UUID())
            return [.opened(.init(workspaceID: nil, title: title))]
        }
        guard case .committed = opened else { throw MiraError(.storage, "Fixture session did not open.") }
        let admitted = await runtime.commit(id: UUID()) { context in
            let plan = AgentExecutionPlan(
                runtimeID: UUID(), catalogGeneration: 1, driverID: "local",
                driverRevision: 1, instructions: "", limits: .init(), priority: .foreground, route: nil)
            let planReference = try await context.stage(plan, kind: .executionPlan, retentionGroup: UUID())
            let user = try await context.stageBytes(
                Data("Recover locally".utf8), kind: .userText, retentionGroup: UUID())
            let executionID = ExecutionID()
            return [
                .admitted(
                    .init(
                        executionID: executionID, userMessageID: MessageID(), userBody: user,
                        plan: planReference, hasModelRoute: false,
                        authorizationEpoch: context.state.authorizationEpoch, timeZoneIdentifier: "UTC"))
            ]
        }
        guard case .committed = admitted else { throw MiraError(.storage, "Fixture admission did not commit.") }
        let executionID = try #require(await runtime.snapshot().activeExecutionID)
        let preparing = await runtime.commit(id: UUID()) { _ in
            [.phaseChanged(executionID: executionID, phase: .preparing)]
        }
        guard case .committed = preparing else { throw MiraError(.storage, "Fixture execution did not start.") }
        await runtime.close()

        let service = AgentLibraryRestoration(
            journal: journal, payloads: journal, receipts: RestorationReceipts(),
            authorizer: RestorationAuthorizer())
        _ = try await service.restore()
        let reopened = try await SessionRuntime.open(id: sessionID, journal: journal, payloads: journal)
        #expect(await reopened.snapshot().executions[executionID]?.completion?.status == .interrupted)
        #expect(await reopened.snapshot().activeExecutionID == nil)
        await reopened.close()
        await service.close()
    }

}

private actor RestorationJournal: SessionJournal, SessionPayloadStore {
    private let sessionIDs: [ConversationID]
    private let waitForFirstCall: Bool
    private var firstCallEntered = false
    private var firstCallReleased = false
    private var firstCallWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    var openCount = 0
    private var batches: [UUID: SessionBatch] = [:]
    private var payloadData: [SessionPayloadReference: Data] = [:]

    init(sessionIDs: [ConversationID] = [], waitForFirstSessionsCall: Bool = false) {
        self.sessionIDs = sessionIDs
        self.waitForFirstCall = waitForFirstSessionsCall
    }

    func append(_ batch: SessionBatch) async -> SessionAppendOutcome {
        do { try batch.validate() } catch { return .notCommitted(.safe(error)) }
        if let existing = batches[batch.id] { return .committed(existing.cursor) }
        let current =
            batches.values.filter { $0.sessionID == batch.sessionID }
            .map(\.cursor.sequence).max() ?? 0
        guard current == batch.expectedSequence else {
            return .notCommitted(.init(.conflict, "Fixture sequence mismatch."))
        }
        batches[batch.id] = batch
        return .committed(batch.cursor)
    }
    func reconcile(_ batch: SessionBatch) async -> SessionAppendOutcome { await append(batch) }
    func batch(id: UUID, sessionID: ConversationID) async throws -> SessionBatch? {
        guard let batch = batches[id], batch.sessionID == sessionID else { return nil }
        return batch
    }
    func head(sessionID: ConversationID) async throws -> SessionJournalHead {
        openCount += 1
        let values = batches.values.filter { $0.sessionID == sessionID }
            .sorted { $0.cursor.sequence < $1.cursor.sequence }
        guard let last = values.last else {
            return .init(cursor: .init(sessionID: sessionID, sequence: 0), batchID: nil)
        }
        return .init(cursor: last.cursor, batchID: last.id)
    }
    func read(sessionID: ConversationID, after sequence: Int64, limit: Int) async throws -> [SessionBatch] {
        Array(
            batches.values.filter { $0.sessionID == sessionID && $0.cursor.sequence > sequence }
                .sorted { $0.expectedSequence < $1.expectedSequence }.prefix(limit))
    }

    func sessions(after: ConversationID?, limit: Int) async throws -> [ConversationID] {
        if after == nil, waitForFirstCall, !firstCallEntered {
            firstCallEntered = true
            for waiter in firstCallWaiters { waiter.resume() }
            firstCallWaiters.removeAll()
            if !firstCallReleased { await withCheckedContinuation { releaseContinuation = $0 } }
        }
        if sessionIDs.count == 129, after == nil { return sessionIDs }
        var all = Set(sessionIDs)
        all.formUnion(batches.values.map(\.sessionID))
        let ordered = all.sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }
        if let after, let index = ordered.firstIndex(of: after) {
            return Array(ordered.dropFirst(index + 1).prefix(limit))
        }
        return Array(ordered.prefix(limit))
    }

    func flush() async throws {}
    func close() async throws {}

    func stage(
        _ data: Data, sessionID: ConversationID, batchID: UUID,
        retentionGroup: UUID, kind: SessionPayloadKind
    ) async throws -> SessionPayloadReference {
        let reference = SessionPayloadReference(
            id: UUID(), sessionID: sessionID, batchID: batchID,
            retentionGroup: retentionGroup, kind: kind, byteCount: data.count,
            digest: String(repeating: "a", count: 64))
        payloadData[reference] = data
        return reference
    }
    func read(_ reference: SessionPayloadReference) async throws -> Data {
        guard let data = payloadData[reference] else {
            throw MiraError(.notFound, "Fixture payload is unavailable.")
        }
        return data
    }
    func purge(sessionID: ConversationID, retentionGroups: Set<UUID>) async throws {}

    func waitForFirstSessionsCall() async {
        if !firstCallEntered { await withCheckedContinuation { firstCallWaiters.append($0) } }
    }
    func releaseFirstSessionsCall() {
        firstCallReleased = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor RestorationReceipts: AgentBusinessReceipts {
    private var publications: [AgentReceiptPublication]
    var acknowledged: [AgentBusinessReceiptReference] = []

    init(publications: [AgentReceiptPublication] = []) { self.publications = publications }

    func fenceExecution(sessionID: ConversationID, executionID: ExecutionID) async throws {}
    func receipt(for proof: AgentEffectProof) async -> AgentBusinessReceiptLookup { .absent }
    func unpublished(after receiptID: UUID?, limit: Int) async throws -> [AgentReceiptPublication] {
        guard let receiptID else { return Array(publications.prefix(limit)) }
        guard let index = publications.firstIndex(where: { $0.receipt.reference.id == receiptID }) else { return [] }
        return Array(publications.dropFirst(index + 1).prefix(limit))
    }
    func acknowledge(_ receipt: AgentBusinessReceiptReference, at cursor: SessionCursor) async throws {
        acknowledged.append(receipt)
        publications.removeAll { $0.receipt.reference.id == receipt.id }
    }
}

private struct RestorationAuthorizer: AgentSourceAuthorizer {
    func validate(_ sources: [AgentSourceReference], for request: AgentContextRequest) async throws {}
}
