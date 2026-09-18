import Foundation
import GRDB
import Testing

@testable import MiraCore
@testable import MiraData

@Suite("SQLite business archive validation", .timeLimit(.minutes(1)))
struct SQLiteBusinessArchiveTests {
    @Test(arguments: [false, true])
    func validatesRealKernelReceiptsWithOrWithoutPublicationAcknowledgement(unacknowledged: Bool) async throws {
        try await withArchiveWorkflow { fixture in
            if unacknowledged {
                try await fixture.database.write { db in
                    try db.execute(sql: "UPDATE business_receipts SET acknowledged=0, publication_json=NULL")
                }
            }
            try await inspect(fixture)
        }
    }

    @Test(arguments: [
        "proofExecution", "intentDigest", "operationDigest", "publication", "missingReceipt", "body", "command",
        "fence",
    ])
    func rejectsBrokenCrossStoreIdentity(change: String) async throws {
        try await withArchiveWorkflow { fixture in
            try await fixture.database.write { db in
                switch change {
                case "proofExecution":
                    let raw = try #require(try String.fetchOne(db, sql: "SELECT proof_json FROM business_receipts"))
                    let proof = try SessionCodec.decode(AgentEffectProof.self, from: Data(raw.utf8))
                    let forged = AgentEffectProof(
                        sessionID: proof.sessionID, executionID: ExecutionID(), invocationID: proof.invocationID,
                        intentBatchID: proof.intentBatchID, intentSequence: proof.intentSequence,
                        authorization: proof.authorization, proposal: proof.proposal)
                    try db.execute(
                        sql: "UPDATE business_receipts SET proof_json=?",
                        arguments: [String(decoding: try SessionCodec.encode(forged), as: UTF8.self)])
                case "intentDigest":
                    try db.execute(
                        sql: "UPDATE business_receipts SET intent_digest=?",
                        arguments: [String(repeating: "0", count: 64)])
                case "operationDigest":
                    try db.execute(
                        sql: "UPDATE business_operations SET result_digest=?",
                        arguments: [String(repeating: "0", count: 64)])
                case "publication":
                    let cursor = SessionCursor(sessionID: ConversationID(), sequence: 1)
                    try db.execute(
                        sql: "UPDATE business_receipts SET publication_json=?",
                        arguments: [String(decoding: try SessionCodec.encode(cursor), as: UTF8.self)])
                case "missingReceipt":
                    try db.execute(sql: "DELETE FROM business_receipts")
                    try db.execute(sql: "DELETE FROM business_operations")
                case "body":
                    try db.execute(
                        sql: "UPDATE business_operations SET result_blob=?", arguments: [Data("corrupt".utf8)])
                case "command":
                    try db.execute(
                        sql: "UPDATE business_operations SET command_digest=?",
                        arguments: [String(repeating: "0", count: 64)])
                case "fence":
                    try db.execute(
                        sql: "INSERT INTO business_fences(session_id, execution_id) VALUES (?, ?)",
                        arguments: [UUID().uuidString, UUID().uuidString])
                default: throw MiraError(.invalidInput, "Unknown archive fixture mutation.")
                }
            }
            await #expect(throws: MiraError.self) { try await inspect(fixture) }
        }
    }
}

private func inspect(_ fixture: TaskWorkflowFixture) async throws {
    let module = try SQLiteBusinessEffects.archiveModule()
    try await fixture.library.withSnapshot { snapshot in
        try fixture.database.read { db in _ = try module.inspect(db, snapshot) }
    }
}
private func withArchiveWorkflow(_ body: (TaskWorkflowFixture) async throws -> Void) async throws {
    let quote = "add a task to review notes"
    try await withTaskWorkflow(outputs: taskReplies(taskArguments(quote: quote))) { fixture in
        _ = try await fixture.run(quote)
        #expect(
            try await fixture.database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM business_receipts") } == 1
        )
        _ = await fixture.runtime.shutdown()
        try await body(fixture)
    }
}
