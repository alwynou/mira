import Foundation
import GRDB
import Testing

@testable import MiraCore
@testable import MiraData

@Suite("Memory extraction journal consumer", .timeLimit(.minutes(1)))
struct MemoryExtractionConsumerTests {
    @Test func completionEnqueuesOnceAndCheckpointReopens() async throws {
        try await withTaskWorkflow(outputs: [[.blockStarted(.init(id: "text", content: .text("Done"))), .blockFinished(id: "text"), .finished(.stop)]], memoryEnabled: true) { fixture in
            try await enable(fixture)
            let address = try await fixture.run("I prefer green tea")
            let batches = try await fixture.library.read(
                sessionID: address.sessionID, after: 0, limit: SessionFormatLimits.maximumReadBatches)
            let consumer = try makeConsumer(fixture)
            do {
                var previous = SessionJournalHead(
                    cursor: .init(sessionID: address.sessionID, sequence: 0), batchID: nil)
                for batch in batches {
                    let delivery = AgentSessionConsumerDelivery(
                        consumer: SQLiteMemoryExtractionConsumer.identity, previous: previous, batch: batch)
                    _ = try await consumer.consume(delivery)
                    _ = try await consumer.consume(delivery)
                    previous = delivery.checkpoint.head
                }
                let store = try SQLiteMemoryExtractionStore(
                    database: fixture.database, libraryID: fixture.authority.libraryID)
                let jobs = try await store.memoryExtractionJobs(sessionID: address.sessionID, state: .queued, limit: 10)
                await store.close()
                #expect(jobs.count == 1)
                #expect(jobs.first?.origin.source == (try await fixture.evidence(address)).reference)
                #expect(try await consumer.checkpoint(sessionID: address.sessionID)?.head == previous)
                await consumer.close()
                let reopened = try makeConsumer(fixture)
                #expect(try await reopened.checkpoint(sessionID: address.sessionID)?.head == previous)
                await reopened.close()
            } catch {
                await consumer.close()
                throw error
            }
        }
    }

    @Test func jobFailureRollsBackTheCompletionCheckpoint() async throws {
        try await withTaskWorkflow(outputs: [[.blockStarted(.init(id: "text", content: .text("Done"))), .blockFinished(id: "text"), .finished(.stop)]], memoryEnabled: true) { fixture in
            try await enable(fixture)
            let address = try await fixture.run("I prefer green tea")
            let batches = try await fixture.library.read(
                sessionID: address.sessionID, after: 0, limit: SessionFormatLimits.maximumReadBatches)
            let consumer = try makeConsumer(fixture)
            do {
                var previous = SessionJournalHead(
                    cursor: .init(sessionID: address.sessionID, sequence: 0), batchID: nil)
                for batch in batches {
                    let delivery = AgentSessionConsumerDelivery(
                        consumer: SQLiteMemoryExtractionConsumer.identity, previous: previous, batch: batch)
                    let finishes = batch.events.contains {
                        if case .finished = $0.fact { return true }
                        return false
                    }
                    if finishes {
                        try await fixture.database.write { db in
                            try db.execute(
                                sql:
                                    "CREATE TRIGGER extraction_reject BEFORE INSERT ON memory_extraction_jobs BEGIN SELECT RAISE(ABORT, 'Synthetic failure'); END"
                            )
                        }
                        await #expect(throws: MiraError.self) { try await consumer.consume(delivery) }
                        #expect(try await consumer.checkpoint(sessionID: address.sessionID)?.head == previous)
                        #expect(
                            try await fixture.database.read {
                                try Int.fetchOne($0, sql: "SELECT count(*) FROM memory_extraction_jobs")
                            } == 0)
                        try await fixture.database.write { try $0.execute(sql: "DROP TRIGGER extraction_reject") }
                    }
                    _ = try await consumer.consume(delivery)
                    previous = delivery.checkpoint.head
                }
                #expect(
                    try await fixture.database.read {
                        try Int.fetchOne($0, sql: "SELECT count(*) FROM memory_extraction_jobs")
                    } == 1)
                await consumer.close()
            } catch {
                await consumer.close()
                throw error
            }
        }
    }

    @Test func forgedBatchCannotCreateAJobOrCheckpoint() async throws {
        try await withTaskWorkflow(outputs: [[.blockStarted(.init(id: "text", content: .text("Done"))), .blockFinished(id: "text"), .finished(.stop)]], memoryEnabled: true) { fixture in
            try await enable(fixture)
            let address = try await fixture.run("I prefer green tea")
            let first = try #require(
                try await fixture.library.read(sessionID: address.sessionID, after: 0, limit: 1).first)
            let events = first.events.map {
                SessionEvent(id: UUID(), sequence: $0.sequence, occurredAt: $0.occurredAt, fact: $0.fact)
            }
            let forged = SessionBatch(
                id: first.id, sessionID: first.sessionID, expectedSequence: first.expectedSequence, events: events)
            let consumer = try makeConsumer(fixture)
            let delivery = AgentSessionConsumerDelivery(
                consumer: SQLiteMemoryExtractionConsumer.identity,
                previous: .init(cursor: .init(sessionID: address.sessionID, sequence: 0), batchID: nil), batch: forged)
            do {
                await #expect(throws: MiraError.self) { try await consumer.consume(delivery) }
                #expect(try await consumer.checkpoint(sessionID: address.sessionID) == nil)
                await consumer.close()
            } catch {
                await consumer.close()
                throw error
            }
        }
    }

    @Test func disabledCaptureStillAdvancesWithoutEnqueueing() async throws {
        try await withTaskWorkflow(outputs: [[.blockStarted(.init(id: "text", content: .text("Done"))), .blockFinished(id: "text"), .finished(.stop)]], memoryEnabled: true) { fixture in
            let address = try await fixture.run("I prefer green tea")
            let consumer = try makeConsumer(fixture)
            do {
                var previous = SessionJournalHead(
                    cursor: .init(sessionID: address.sessionID, sequence: 0), batchID: nil)
                for batch in try await fixture.library.read(
                    sessionID: address.sessionID, after: 0, limit: SessionFormatLimits.maximumReadBatches)
                {
                    let delivery = AgentSessionConsumerDelivery(
                        consumer: SQLiteMemoryExtractionConsumer.identity, previous: previous, batch: batch)
                    _ = try await consumer.consume(delivery)
                    previous = delivery.checkpoint.head
                }
                #expect(
                    try await fixture.database.read {
                        try Int.fetchOne($0, sql: "SELECT count(*) FROM memory_extraction_jobs")
                    } == 0)
                #expect(try await consumer.checkpoint(sessionID: address.sessionID)?.head == previous)
                await consumer.close()
            } catch {
                await consumer.close()
                throw error
            }
        }
    }

    private func makeConsumer(_ fixture: TaskWorkflowFixture) throws -> SQLiteSessionConsumer {
        try SQLiteSessionConsumer(
            database: fixture.database, identity: SQLiteMemoryExtractionConsumer.identity,
            handler: SQLiteMemoryExtractionConsumer(
                journal: fixture.library, payloads: fixture.library,
                access: fixture.access, scope: fixture.scope, now: { TaskWorkflowFixture.now }))
    }
    private func enable(_ fixture: TaskWorkflowFixture) async throws {
        let store = try #require(fixture.memory)
        try await store.saveMemoryCapturePolicy(
            .init(
                revision: 2, mode: .automaticWithUndo,
                dailyTokenLimit: 100_000, enabledAt: TaskWorkflowFixture.now), expectedRevision: 1,
            authorization: fixture.authority.authorization(), at: TaskWorkflowFixture.now)
    }
}
