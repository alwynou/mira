import Foundation
import GRDB
import Testing

@testable import MiraCore
@testable import MiraData

@Suite("SQLite business privacy store", .timeLimit(.minutes(1)))
struct SQLiteBusinessPrivacyStoreTests {
    @Test func purgeRemovesSelectedResultBodiesAndPreservesReceiptIdentity() async throws {
        try await withTaskWorkflow(outputs: [[.blockStarted(.init(id: "text", content: .text("Done"))), .blockFinished(id: "text"), .finished(.stop)]]) { fixture in
            let operation = try await beginMaintenance(fixture)
            let data = try privacyData(operation: operation)
            try await insertReceipt(data, in: fixture.database, libraryID: fixture.authority.libraryID)
            let identities = try await fixture.database.read { db in
                try String.fetchAll(
                    db,
                    sql:
                        "SELECT id || ':' || invocation_id || ':' || acknowledged FROM business_receipts ORDER BY sequence"
                )
            }
            let store = try SQLiteBusinessPrivacyStore(
                database: fixture.database, libraryID: fixture.authority.libraryID)
            try await store.purgeSessionResults(plan: data.plan)
            try await store.verifySessionResultsPurged(plan: data.plan)
            try await store.purgeSessionResults(plan: data.plan)
            await store.close()
            let reopened = try SQLiteBusinessPrivacyStore(
                database: fixture.database, libraryID: fixture.authority.libraryID)
            try await reopened.verifySessionResultsPurged(plan: data.plan)
            let row = try await fixture.database.read { db in
                try Row.fetchOne(
                    db,
                    sql:
                        "SELECT r.id, o.result_blob, o.result_purged FROM business_receipts AS r JOIN business_operations AS o ON o.namespace = r.operation_namespace AND o.business_key = r.operation_key WHERE r.invocation_id = ?",
                    arguments: [data.proof.invocationID.uuidString])
            }
            #expect(row?["result_blob"] == nil)
            #expect(row?["result_purged"] as Int? == 1)
            let unrelated = try await fixture.database.read { db in
                try Int.fetchOne(
                    db,
                    sql:
                        "SELECT result_purged FROM business_operations WHERE namespace = 'other' AND business_key = 'untouched'"
                )
            }
            #expect(unrelated == 0)
            #expect(
                try await fixture.database.read { db in
                    try String.fetchAll(
                        db,
                        sql:
                            "SELECT id || ':' || invocation_id || ':' || acknowledged FROM business_receipts ORDER BY sequence"
                    )
                } == identities)
            await reopened.close()
            await #expect(throws: MiraError.self) { try await reopened.verifySessionResultsPurged(plan: data.plan) }
            let fresh = try SQLiteBusinessPrivacyStore(
                database: fixture.database, libraryID: fixture.authority.libraryID)
            do {
                _ = try await fixture.authority.complete(operation, at: operation.request.requestedAt)
                await #expect(throws: MiraError.self) { try await fresh.purgeSessionResults(plan: data.plan) }
                await #expect(throws: MiraError.self) { try await fresh.verifySessionResultsPurged(plan: data.plan) }
            } catch {
                await fresh.close()
                throw error
            }
            await fresh.close()
        }
    }

    @Test func tamperedProofIsRejectedWithoutDeletingResults() async throws {
        try await withTaskWorkflow { fixture in
            let operation = try await beginMaintenance(fixture)
            let data = try privacyData(operation: operation)
            try await insertReceipt(data, in: fixture.database, libraryID: fixture.authority.libraryID)
            try await fixture.database.write { db in
                try db.execute(
                    sql: "UPDATE business_receipts SET proof_json = ? WHERE acknowledged = 1",
                    arguments: ["{}"])
            }
            let store = try SQLiteBusinessPrivacyStore(
                database: fixture.database, libraryID: fixture.authority.libraryID)
            await #expect(throws: MiraError.self) { try await store.purgeSessionResults(plan: data.plan) }
            let purged = try await fixture.database.read { db in
                try Int.fetchOne(
                    db,
                    sql:
                        "SELECT result_purged FROM business_operations WHERE namespace = 'test' AND business_key = 'one'"
                )
            }
            #expect(purged == 0)
            await store.close()
        }
    }

    private struct PrivacyData: Sendable {
        let plan: SessionPrivacyPlan
        let proof: AgentEffectProof
        let result: Data
    }

    private func beginMaintenance(_ fixture: TaskWorkflowFixture) async throws -> AgentLibraryMaintenanceOperation {
        let authorization = try await fixture.authority.authorization()
        return try await fixture.authority.begin(
            .init(
                id: UUID(), namespace: "session.privacy",
                revision: 1, scope: .library, requestedAt: TaskWorkflowFixture.now), expected: authorization)
    }

    private func privacyData(operation: AgentLibraryMaintenanceOperation) throws -> PrivacyData {
        let sessionID = ConversationID()
        let executionID = ExecutionID()
        let invocationID = UUID()
        let batchID = UUID()
        let result = Data(#"{"ok":true}"#.utf8)
        let reference = SessionPayloadReference(
            id: UUID(), sessionID: sessionID, batchID: batchID,
            retentionGroup: UUID(), kind: .effectIntent, byteCount: 1, digest: String(repeating: "0", count: 64))
        let proof = AgentEffectProof(
            sessionID: sessionID, executionID: executionID, invocationID: invocationID,
            intentBatchID: batchID, intentSequence: 1, authorization: operation.previousAuthorization,
            proposal: reference)
        let fact = SessionInvalidation(
            operationID: operation.request.id, executionIDs: [executionID], retentionGroups: [UUID()],
            authorizationEpoch: operation.authorization.epoch, reason: .forgotten)
        let event = SessionEvent(sequence: 2, occurredAt: operation.request.requestedAt, fact: .invalidated(fact))
        let batch = SessionBatch(id: batchID, sessionID: sessionID, expectedSequence: 1, events: [event])
        let dependency = SessionPrivacyDependencies(
            executionID: executionID,
            sources: [.sessionExecution(sessionID: sessionID, executionID: executionID)])
        let plan = SessionPrivacyPlan(
            operation: operation,
            roots: [.sessionExecution(sessionID: sessionID, executionID: executionID)],
            retention: .purgeGeneratedHistory, reason: .forgotten,
            heads: [.init(cursor: .init(sessionID: sessionID, sequence: 1), batchID: UUID())],
            changes: [.init(batch: batch, dependencies: [dependency])])
        try plan.validate()
        return .init(plan: plan, proof: proof, result: result)
    }

    private func insertReceipt(_ data: PrivacyData, in database: DatabaseQueue, libraryID: UUID) async throws {
        let proofJSON = String(decoding: try SessionCodec.encode(data.proof), as: UTF8.self)
        let digest = String(repeating: "a", count: 64)
        try await database.write { db in
            try db.execute(
                sql:
                    "INSERT INTO business_operations(namespace, business_key, command_digest, result_digest, result_blob, result_purged) VALUES ('test', 'one', ?, ?, ?, 0)",
                arguments: [String(repeating: "b", count: 64), digest, data.result])
            try db.execute(
                sql:
                    "INSERT INTO business_receipts(id, invocation_id, library_id, epoch, intent_digest, result_digest, operation_namespace, operation_key, proof_json, acknowledged) VALUES (?, ?, ?, ?, ?, ?, 'test', 'one', ?, 0)",
                arguments: [
                    UUID().uuidString, data.proof.invocationID.uuidString, libraryID.uuidString,
                    String(data.proof.authorization.epoch), data.proof.proposal.digest, digest, proofJSON,
                ])
            var second = data.proof
            second = .init(
                sessionID: second.sessionID, executionID: second.executionID, invocationID: UUID(),
                intentBatchID: second.intentBatchID, intentSequence: second.intentSequence,
                authorization: second.authorization, proposal: second.proposal)
            try db.execute(
                sql:
                    "INSERT INTO business_receipts(id, invocation_id, library_id, epoch, intent_digest, result_digest, operation_namespace, operation_key, proof_json, acknowledged) VALUES (?, ?, ?, ?, ?, ?, 'test', 'one', ?, 1)",
                arguments: [
                    UUID().uuidString, second.invocationID.uuidString, libraryID.uuidString,
                    String(second.authorization.epoch), second.proposal.digest, digest,
                    String(decoding: try SessionCodec.encode(second), as: UTF8.self),
                ])
            try db.execute(
                sql:
                    "INSERT INTO business_operations(namespace, business_key, command_digest, result_digest, result_blob, result_purged) VALUES ('other', 'untouched', ?, ?, ?, 0)",
                arguments: [String(repeating: "c", count: 64), digest, data.result])
        }
    }
}
