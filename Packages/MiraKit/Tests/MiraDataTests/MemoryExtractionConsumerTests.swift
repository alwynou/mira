import Foundation
import GRDB
import Testing

@testable import MiraCore
@testable import MiraData

@Suite("Memory extraction journal consumer", .timeLimit(.minutes(1)))
struct MemoryExtractionConsumerTests {
    @Test func completionEnqueuesOnceAndCheckpointReopens() async throws {
        try await withTaskWorkflow(outputs: Array(repeating: [.blockStarted(.init(id: "text", content: .text("Done"))), .blockFinished(id: "text"), .finished(.stop)], count: 4), memoryEnabled: true) { fixture in
            try await enable(fixture)
            let sessionID = ConversationID()
            let address = try await fixture.run("I prefer green tea", sessionID: sessionID)
            _ = try await fixture.run("I prefer concise answers", sessionID: sessionID)
            _ = try await fixture.run("I work in the morning", sessionID: sessionID)
            _ = try await fixture.run("I prefer paper books", sessionID: sessionID)
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
                #expect(jobs.count == 1)
                #expect(jobs.first?.turns.count == 4)
                let turns = try #require(jobs.first?.turns)
                #expect(turns.map(\.source.admissionSequence) == turns.map(\.source.admissionSequence).sorted())
                for turn in turns {
                    let page = try await store.memoryExtractionStatus(sessionID: turn.source.sessionID, executionID: turn.completedExecutionID, workspaceID: nil, before: nil, limit: 4)
                    #expect(page.jobs.map(\.id) == jobs.map(\.id))
                    #expect(try await store.memoryExtractionReport(jobs[0].id, sessionID: turn.source.sessionID, executionID: turn.completedExecutionID, workspaceID: nil).job.id == jobs[0].id)
                }
                await store.close()
                // Rebuilding a consumer checkpoint cannot requeue sources already owned by a durable job.
                for turn in turns {
                    let source = try await JournalSessionReader(journal: fixture.library, payloads: fixture.library)
                        .userEvidence(sessionID: turn.source.sessionID, executionID: turn.completedExecutionID)
                    try await fixture.database.write { db in
                        _ = try SQLiteMemoryExtractionStore.enqueueBatch(turns: [(
                            origin: .init(source: turn.source, completedExecutionID: turn.completedExecutionID,
                                completionEventID: turn.completionEventID, completionHead: turn.completionHead),
                            source: source, completedAt: turn.completedAt)], at: TaskWorkflowFixture.now, in: db)
                    }
                }
                #expect(try await fixture.database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM memory_extraction_dirty") } == 0)
                // A long foreground turn must not count as background idle time.
                let completed = TaskWorkflowFixture.now.addingTimeInterval(500)
                let longTurn = MemoryExtractionTurn(source: turns[0].source,
                    completedExecutionID: turns[0].completedExecutionID, completionEventID: turns[0].completionEventID,
                    completionHead: turns[0].completionHead, admittedAt: TaskWorkflowFixture.now,
                    completedAt: completed, inputTokenEstimate: 8)
                #expect(MemoryExtractionBatching.trigger(turns: [longTurn], now: completed) == nil)
                #expect(MemoryExtractionBatching.trigger(turns: [longTurn], now: completed.addingTimeInterval(119)) == nil)
                #expect(MemoryExtractionBatching.trigger(turns: [longTurn], now: completed.addingTimeInterval(120)) == .idle)
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

    @Test func dirtyTurnFailureRollsBackTheCompletionCheckpoint() async throws {
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
                                    "CREATE TRIGGER extraction_reject BEFORE INSERT ON memory_extraction_dirty BEGIN SELECT RAISE(ABORT, 'Synthetic failure'); END"
                            )
                        }
                        await #expect(throws: MiraError.self) { try await consumer.consume(delivery) }
                        #expect(try await consumer.checkpoint(sessionID: address.sessionID)?.head == previous)
                        #expect(
                            try await fixture.database.read {
                                try Int.fetchOne($0, sql: "SELECT count(*) FROM memory_extraction_dirty")
                            } == 0)
                        try await fixture.database.write { try $0.execute(sql: "DROP TRIGGER extraction_reject") }
                    }
                    _ = try await consumer.consume(delivery)
                    previous = delivery.checkpoint.head
                }
                #expect(
                    try await fixture.database.read {
                        try Int.fetchOne($0, sql: "SELECT count(*) FROM memory_extraction_dirty")
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
        _ = fixture
    }
}
