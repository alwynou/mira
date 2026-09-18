import Foundation
import GRDB
import Testing

@testable import MiraCore
@testable import MiraData

@Suite("SQLite business receipt store", .timeLimit(.minutes(1)))
struct SQLiteBusinessReceiptStoreTests {
    @Test
    func readsRealCommittedReceiptAndAcknowledgesWithoutReplaying() async throws {
        try await withReceiptWorkflow { fixture, address in
            try await fixture.database.write { db in
                // Simulate lost publication acknowledgement after the journal committed.
                try db.execute(sql: "UPDATE business_receipts SET acknowledged=0, publication_json=NULL")
            }
            let receipts = try SQLiteBusinessReceiptStore(
                database: fixture.database, libraryID: fixture.authority.libraryID,
                journal: fixture.library, payloads: fixture.library)
            do {
                let publication = try #require(try await receipts.unpublished(after: nil, limit: 10).first)
                guard case .committed(let recovered) = await receipts.receipt(for: publication.proof) else {
                    Issue.record("The committed business receipt is missing")
                    await receipts.close()
                    return
                }
                #expect(recovered.reference == publication.receipt.reference)
                #expect(recovered.result == publication.receipt.result)
                await #expect(throws: MiraError.self) {
                    try await receipts.acknowledge(
                        recovered.reference, at: .init(sessionID: address.sessionID, sequence: 0))
                }
                #expect(try await receipts.unpublished(after: nil, limit: 10).count == 1)
                let head = try await fixture.library.head(sessionID: address.sessionID)
                let restoration = AgentLibraryRestoration(
                    journal: fixture.library, payloads: fixture.library,
                    receipts: receipts, authorizer: UnexpectedReceiptSourceRead())
                do { #expect(try await restoration.restore() == [head]) } catch {
                    await restoration.close()
                    throw error
                }
                await restoration.close()
                #expect(try await receipts.unpublished(after: nil, limit: 10).isEmpty)
                #expect(try await fixture.library.head(sessionID: address.sessionID) == head)
                #expect(
                    try await fixture.database.read {
                        try Int.fetchOne($0, sql: "SELECT count(*) FROM business_operations")
                    } == 1)
                let proof = publication.proof
                let foreign = AgentEffectProof(
                    sessionID: proof.sessionID, executionID: proof.executionID,
                    invocationID: UUID(), intentBatchID: proof.intentBatchID, intentSequence: proof.intentSequence,
                    authorization: .init(libraryID: UUID(), epoch: proof.authorization.epoch), proposal: proof.proposal)
                guard case .unavailable(let error) = await receipts.receipt(for: foreign) else {
                    Issue.record("A foreign library proof was treated as absent")
                    await receipts.close()
                    return
                }
                #expect(error.code == .unauthorized)
                await receipts.close()
                await #expect(throws: MiraError.self) { try await receipts.unpublished(after: nil, limit: 1) }
            } catch {
                await receipts.close()
                throw error
            }
        }
    }

    @Test func closeDrainsPublicationValidationBeforeDatabaseWrite() async throws {
        try await withReceiptWorkflow { fixture, address in
            try await fixture.database.write {
                try $0.execute(sql: "UPDATE business_receipts SET acknowledged=0, publication_json=NULL")
            }
            let gate = ReceiptJournalGate(base: fixture.library)
            let receipts = try SQLiteBusinessReceiptStore(
                database: fixture.database, libraryID: fixture.authority.libraryID,
                journal: gate, payloads: fixture.library)
            let publication = try #require(try await receipts.unpublished(after: nil, limit: 1).first)
            let head = try await fixture.library.head(sessionID: address.sessionID)
            let acknowledgement = Task {
                try await receipts.acknowledge(publication.receipt.reference, at: head.cursor)
            }
            await gate.waitUntilEntered()
            let closing = Task { await receipts.close() }
            // Wait until admission has actually closed, rather than relying on a timing delay.
            var isClosed = false
            for _ in 0..<10_000 {
                do { _ = try await receipts.unpublished(after: nil, limit: 1) } catch {
                    isClosed = true
                    break
                }
                await Task.yield()
            }
            #expect(isClosed)
            #expect(
                try await fixture.database.read {
                    try Int.fetchOne($0, sql: "SELECT acknowledged FROM business_receipts")
                } == 0)
            await gate.release()
            try await acknowledgement.value
            await closing.value
            #expect(
                try await fixture.database.read {
                    try Int.fetchOne($0, sql: "SELECT acknowledged FROM business_receipts")
                } == 1)
        }
    }
}

private struct UnexpectedReceiptSourceRead: AgentSourceAuthorizer {
    func validate(_ sources: [AgentSourceReference], for request: AgentContextRequest) async throws {
        throw MiraError(.storage, "A terminal receipt must not re-read source bodies.")
    }
}

private func withReceiptWorkflow(_ body: (TaskWorkflowFixture, AgentExecutionAddress) async throws -> Void) async throws
{
    let quote = "add a task to review notes"
    try await withTaskWorkflow(outputs: taskReplies(taskArguments(quote: quote))) { fixture in
        let address = try await fixture.run(quote)
        _ = await fixture.runtime.shutdown()
        try await fixture.business.close()
        try await body(fixture, address)
    }
}

private actor ReceiptJournalGate: SessionJournal {
    let base: FileSessionLibrary
    private var entered = false
    private var released = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var blocked: CheckedContinuation<Void, Never>?
    init(base: FileSessionLibrary) { self.base = base }
    func read(sessionID: ConversationID, after sequence: Int64, limit: Int) async throws -> [SessionBatch] {
        if !entered {
            entered = true
            enteredWaiters.forEach { $0.resume() }
            enteredWaiters.removeAll()
            if !released { await withCheckedContinuation { blocked = $0 } }
        }
        return try await base.read(sessionID: sessionID, after: sequence, limit: limit)
    }
    func waitUntilEntered() async { if !entered { await withCheckedContinuation { enteredWaiters.append($0) } } }
    func release() {
        released = true
        blocked?.resume()
        blocked = nil
    }
    func append(_ batch: SessionBatch) async -> SessionAppendOutcome { await base.append(batch) }
    func reconcile(_ batch: SessionBatch) async -> SessionAppendOutcome { await base.reconcile(batch) }
    func batch(id: UUID, sessionID: ConversationID) async throws -> SessionBatch? {
        try await base.batch(id: id, sessionID: sessionID)
    }
    func head(sessionID: ConversationID) async throws -> SessionJournalHead {
        try await base.head(sessionID: sessionID)
    }
    func sessions(after: ConversationID?, limit: Int) async throws -> [ConversationID] {
        try await base.sessions(after: after, limit: limit)
    }
    func flush() async throws { try await base.flush() }
    func close() async throws {}
}
