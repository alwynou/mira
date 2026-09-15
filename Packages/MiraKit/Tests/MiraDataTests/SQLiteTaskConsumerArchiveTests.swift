import Foundation
import GRDB
import Testing

@testable import MiraCore
@testable import MiraData

@Test
func taskArchiveValidatesTypedHistoryAndReminderRestoreState() async throws {
    try await withTaskWorkflow { fixture in
        let task = try await fixture.save(
            id: .init(),
            draft: .init(title: "Archive task", reminderAt: TaskWorkflowFixture.now.addingTimeInterval(3_600)),
            status: .open)
        let module = try SQLiteTaskStore.archiveModule()
        try await fixture.library.withSnapshot { snapshot in
            try fixture.database.read { db in try module.inspect(db, snapshot) }
        }
        guard case .prepare(let apply, let verify) = module.restoration else {
            Issue.record("Task archives must pause reminders during restore preparation.")
            return
        }
        try await fixture.database.write { db in try apply(db, TaskWorkflowFixture.now) }
        try await fixture.database.read { db in
            try verify(db)
            #expect(
                try String.fetchOne(
                    db, sql: "SELECT delivery_state FROM mira_tasks WHERE id = ?",
                    arguments: [task.id.rawValue.uuidString.lowercased()]) == ReminderDeliveryState.paused.rawValue)
        }

        try await fixture.database.write { db in
            try db.execute(
                sql: "UPDATE mira_tasks SET revision = revision + 1 WHERE id = ?",
                arguments: [task.id.rawValue.uuidString.lowercased()])
        }
        await #expect(throws: MiraError.self) {
            try await fixture.library.withSnapshot { snapshot in
                try fixture.database.read { db in try module.inspect(db, snapshot) }
            }
        }
    }
}

@Test
func consumerArchiveValidatesCommittedCheckpointAndRejectsFutureCursor() async throws {
    try await withTaskWorkflow(outputs: [[.blockStarted(.init(id: "text", content: .text("done"))), .blockFinished(id: "text"), .finished(.stop)]]) { fixture in
        let address = try await fixture.run("archive consumer source")
        let (first, headSequence) = try await fixture.library.withSnapshot { snapshot in
            let session = try #require(snapshot.session(address.sessionID))
            let batches = try snapshot.readBatches(sessionID: session.id)
            return (try #require(batches.first), session.head.cursor.sequence)
        }
        let identity = AgentSessionConsumerIdentity(id: "archive.consumer", revision: 1)
        let consumer = try SQLiteSessionConsumer(
            database: fixture.database, identity: identity, handler: ArchiveNoopHandler())
        do {
            _ = try await consumer.consume(
                .init(
                    consumer: identity,
                    previous: .init(cursor: .init(sessionID: address.sessionID, sequence: 0), batchID: nil),
                    batch: first))

            let module = try SQLiteSessionConsumer.archiveModule()
            try await fixture.library.withSnapshot { snapshot in
                try fixture.database.read { db in try module.inspect(db, snapshot) }
            }
            try await fixture.database.write { db in
                try db.execute(
                    sql:
                        "UPDATE mira_session_consumer_checkpoints SET head_sequence = ? WHERE consumer_id = ? AND session_id = ?",
                    arguments: [headSequence + 1, identity.id, address.sessionID.rawValue.uuidString])
            }
            await #expect(throws: MiraError.self) {
                try await fixture.library.withSnapshot { snapshot in
                    try fixture.database.read { db in try module.inspect(db, snapshot) }
                }
            }
        } catch {
            await consumer.close()
            throw error
        }
        await consumer.close()
    }
}

private struct ArchiveNoopHandler: SQLiteSessionConsumerHandler {
    func prepare(_ delivery: AgentSessionConsumerDelivery) async throws -> any SQLiteSessionConsumerTransaction {
        ArchiveNoopTransaction()
    }
}

private struct ArchiveNoopTransaction: SQLiteSessionConsumerTransaction {
    func apply(in db: Database) throws {}
    func close() async {}
}
