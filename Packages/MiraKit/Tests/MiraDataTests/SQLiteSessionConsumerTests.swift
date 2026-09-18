import Foundation
import Testing
import GRDB
@testable import MiraCore
@testable import MiraData

@Suite("SQLite session consumer", .timeLimit(.minutes(1)))
struct SQLiteSessionConsumerTests {
    @Test func handlerAndCheckpointShareAtomicRollback() async throws {
        let fixture = try await ConsumerFixture.make()
        try await withConsumerFixture(fixture) { fixture in
            let batches = try await fixture.batches()
            let first = try #require(batches.first)
            let second = try #require(batches.dropFirst().first)
            let initial = fixture.delivery(batch: first)
            let consumer = try fixture.consumer()
            let firstCheckpoint = try await consumer.consume(initial)
            #expect(firstCheckpoint == initial.checkpoint)
            #expect(try fixture.jobCount() == 1)

            await consumer.close()
            let failing = try fixture.consumer(handler: ConsumerHandler(failOnPhaseBatch: true))
            let secondDelivery = fixture.delivery(batch: second, previous: firstCheckpoint.head)
            await #expect(throws: Error.self) { try await failing.consume(secondDelivery) }
            #expect(try fixture.jobCount() == 1)
            #expect(try await failing.checkpoint(sessionID: fixture.sessionID) == firstCheckpoint)
            await failing.close()

            let retry = try fixture.consumer()
            #expect(try await retry.consume(secondDelivery) == secondDelivery.checkpoint)
            #expect(try fixture.jobCount() == 2)
            await retry.close()
        }
    }

    @Test func lostCommitConfirmationPersistsCheckpointWithoutRedispatch() async throws {
        let fixture = try await ConsumerFixture.make()
        try await withConsumerFixture(fixture) { fixture in
            let batch = try #require(try await fixture.batches().first)
            let delivery = fixture.delivery(batch: batch)
            let uncertain = try fixture.consumer(afterCommitHook: { throw ConsumerHookFailure.lost })
            await #expect(throws: Error.self) { try await uncertain.consume(delivery) }
            #expect(try await uncertain.checkpoint(sessionID: fixture.sessionID) == delivery.checkpoint)
            #expect(try fixture.jobCount() == 1)
            await uncertain.close()

            let reopened = try fixture.consumer()
            #expect(try await reopened.consume(delivery) == delivery.checkpoint)
            #expect(try fixture.jobCount() == 1)
            await reopened.close()
        }
    }

    @Test func duplicateDigestGapAndConflictingBatchAreRejectedDeterministically() async throws {
        let fixture = try await ConsumerFixture.make()
        try await withConsumerFixture(fixture) { fixture in
            let batches = try await fixture.batches()
            let first = try #require(batches.first)
            let second = try #require(batches.dropFirst().first)
            let consumer = try fixture.consumer()
            let initial = fixture.delivery(batch: first)
            #expect(try await consumer.consume(initial) == initial.checkpoint)
            #expect(try await consumer.consume(initial) == initial.checkpoint)
            #expect(try fixture.jobCount() == 1)

            let changedEvents = first.events.map { event in
                SessionEvent(id: event.id, sequence: event.sequence, occurredAt: event.occurredAt.addingTimeInterval(1), fact: event.fact)
            }
            let conflictingBatch = SessionBatch(id: first.id, sessionID: first.sessionID,
                expectedSequence: first.expectedSequence, events: changedEvents)
            await #expect(throws: Error.self) {
                try await consumer.consume(fixture.delivery(batch: conflictingBatch))
            }
            let gap = SessionJournalHead(cursor: .init(sessionID: fixture.sessionID, sequence: 0), batchID: nil)
            await #expect(throws: Error.self) {
                try await consumer.consume(fixture.delivery(batch: second, previous: gap))
            }
            await consumer.close()
            #expect(throws: Error.self) {
                _ = try fixture.consumer(identity: .init(id: "tests.consumer", revision: 2))
            }
        }
    }

    @Test func corruptSchemaAndCheckpointValuesFailClosed() async throws {
        let fixture = try await ConsumerFixture.make()
        try await withConsumerFixture(fixture) { fixture in
            let batch = try #require(try await fixture.batches().first)
            let consumer = try fixture.consumer()
            _ = try await consumer.consume(fixture.delivery(batch: batch))
            await consumer.close()
            try await fixture.database.writeWithoutTransaction { db in
                try db.execute(sql: "PRAGMA ignore_check_constraints = ON")
                try db.execute(sql: "UPDATE mira_session_consumer_schema SET version = 99 WHERE id = 1")
            }
            #expect(throws: Error.self) {
                _ = try fixture.consumer()
            }
            try await fixture.database.writeWithoutTransaction { db in
                try db.execute(sql: "UPDATE mira_session_consumer_schema SET version = 1 WHERE id = 1")
                try db.execute(sql: "UPDATE mira_session_consumer_checkpoints SET head_batch_id = 'corrupt' WHERE consumer_id = ?",
                    arguments: ["tests.consumer"])
                try db.execute(sql: "PRAGMA ignore_check_constraints = OFF")
            }
            let corrupt = try fixture.consumer()
            await #expect(throws: Error.self) { _ = try await corrupt.checkpoint(sessionID: fixture.sessionID) }
            await corrupt.close()
        }
    }

    @Test func sharedBusinessDatabaseSurvivesConsumerCloseAndProjectionRebuild() async throws {
        let fixture = try await ConsumerFixture.make()
        try await withConsumerFixture(fixture) { fixture in
            let batches = try await fixture.batches()
            let consumer = try fixture.consumer()
            var checkpoint: AgentSessionConsumerCheckpoint?
            var previous = SessionJournalHead(cursor: .init(sessionID: fixture.sessionID, sequence: 0), batchID: nil)
            for batch in batches {
                let next = try await consumer.consume(fixture.delivery(batch: batch, previous: previous))
                checkpoint = next; previous = next.head
            }
            await consumer.close()
            let saved = try #require(checkpoint)
            try await fixture.database.write { db in
                try db.execute(sql: "CREATE TABLE IF NOT EXISTS business_sentinel (id INTEGER PRIMARY KEY, value TEXT NOT NULL)")
                try db.execute(sql: "INSERT OR REPLACE INTO business_sentinel(id, value) VALUES (1, 'alive')")
            }
            #expect(try await fixture.database.read { db in try String.fetchOne(db, sql: "SELECT value FROM business_sentinel WHERE id = 1") } == "alive")

            let projectionPath = fixture.directory.appendingPathComponent("projection.sqlite").path
            let projection = try SQLiteSessionProjection(path: projectionPath)
            let projectionCoordinator = try SessionProjectionCoordinator(journal: fixture.library, projection: projection)
            _ = try await projectionCoordinator.rebuild(sessionID: fixture.sessionID)
            await projectionCoordinator.close()
            let projectedHead = try await projection.head(sessionID: fixture.sessionID)
            let projectedSummary = try await projection.session(id: fixture.sessionID)
            try await projection.close()
            try FileManager.default.removeItem(atPath: projectionPath)
            let rebuilt = try SQLiteSessionProjection(path: projectionPath)
            let rebuiltCoordinator = try SessionProjectionCoordinator(journal: fixture.library, projection: rebuilt)
            _ = try await rebuiltCoordinator.rebuild(sessionID: fixture.sessionID)
            await rebuiltCoordinator.close()
            #expect(try await rebuilt.head(sessionID: fixture.sessionID) == projectedHead)
            #expect(try await rebuilt.session(id: fixture.sessionID) == projectedSummary)
            try await rebuilt.close()
            #expect(try await fixture.database.read { db in
                try String.fetchOne(db, sql: "SELECT value FROM business_sentinel WHERE id = 1")
            } == "alive")
            #expect(try await fixture.consumer().checkpoint(sessionID: fixture.sessionID) == saved)
            #expect(try fixture.jobCount() == batches.count)
        }
    }

    @Test func closeWaitsForInFlightAfterCommitHookToDrain() async throws {
        let fixture = try await ConsumerFixture.make()
        try await withConsumerFixture(fixture) { fixture in
            let batch = try #require(try await fixture.batches().first)
            let delivery = fixture.delivery(batch: batch)
            let gate = ConsumerHookGate()
            let consumer = try fixture.consumer(afterCommitHook: {
                gate.entered()
                gate.releaseSemaphore.wait()
                gate.exited()
                throw ConsumerHookFailure.lost
            })
            let consuming = Task { try? await consumer.consume(delivery) }
            var entered = gate.enteredStream.makeAsyncIterator()
            _ = await entered.next()
            let closing = Task {
                await consumer.close()
                gate.closed()
            }
            for _ in 0..<10_000 where !consumer.isClosing { await Task.yield() }
            #expect(consumer.isClosing)
            #expect(gate.events == ["entered"])
            gate.releaseSemaphore.signal()
            _ = await consuming.value
            await closing.value
            #expect(gate.events == ["entered", "exited", "closed"])
            #expect(try fixture.jobCount() == 1)
        }
    }

    @Test func durableSynchronizationAndStoredRevisionAreRequiredBeforeFirstCheckpoint() async throws {
        let fixture = try await ConsumerFixture.make()
        try await withConsumerFixture(fixture) { fixture in
            try await fixture.database.writeWithoutTransaction { db in try db.execute(sql: "PRAGMA synchronous = NORMAL") }
            do { _ = try fixture.consumer(); Issue.record("Consumer accepted non-durable database settings") }
            catch let error as MiraError { #expect(error.code == .configuration) }
            #expect(try await fixture.database.read { db in try db.tableExists("mira_session_consumer_schema") } == false)
            try await fixture.database.writeWithoutTransaction { db in try db.execute(sql: "PRAGMA synchronous = FULL") }
            let consumer = try fixture.consumer()
            #expect(try await consumer.checkpoint(sessionID: fixture.sessionID) == nil)
            try await fixture.database.write { db in
                try db.execute(sql: "UPDATE mira_session_consumers SET revision = 2 WHERE consumer_id = ?",
                               arguments: [fixture.identity.id])
            }
            do { _ = try await consumer.checkpoint(sessionID: fixture.sessionID); Issue.record("Missing checkpoint hid a changed consumer revision") }
            catch let error as MiraError { #expect(error.code == .conflict) }
            let first = try #require(try await fixture.batches().first)
            do { _ = try await consumer.consume(fixture.delivery(batch: first)); Issue.record("Changed consumer revision accepted a delivery") }
            catch let error as MiraError { #expect(error.code == .conflict) }
            #expect(try fixture.jobCount() == 0)
            await consumer.close()
        }
    }

    @Test func nonCooperativePreparationIsDrainedAfterCallerCancellation() async throws {
        let fixture = try await ConsumerFixture.make()
        try await withConsumerFixture(fixture) { fixture in
            let gate = PrepareGate(); let batch = try #require(try await fixture.batches().first)
            let consumer = try fixture.consumer(handler: ConsumerHandler(gate: gate))
            let consuming = Task { try await consumer.consume(fixture.delivery(batch: batch)) }
            await gate.waitUntilEntered()
            consuming.cancel()
            let closing = Task { await consumer.close() }
            for _ in 0..<10_000 where !consumer.isClosing { await Task.yield() }
            #expect(consumer.isClosing)
            await gate.release()
            _ = try? await consuming.value
            await closing.value
            #expect(try fixture.jobCount() == 1)
        }
    }

    @Test func preparationFailureLeavesCheckpointAndDomainRowsUntouched() async throws {
        let fixture = try await ConsumerFixture.make()
        try await withConsumerFixture(fixture) { fixture in
            let batch = try #require(try await fixture.batches().first)
            let consumer = try fixture.consumer(handler: ThrowingPrepareHandler())
            await #expect(throws: Error.self) { try await consumer.consume(fixture.delivery(batch: batch)) }
            #expect(try fixture.jobCount() == 0)
            #expect(try await consumer.checkpoint(sessionID: fixture.sessionID) == nil)
            await consumer.close()
        }
    }

    @Test func cooperativePreparationIsCancelledAndDrainedByClose() async throws {
        let fixture = try await ConsumerFixture.make()
        try await withConsumerFixture(fixture) { fixture in
            let batch = try #require(try await fixture.batches().first)
            let gate = PrepareGate()
            let consumer = try fixture.consumer(handler: CooperativePrepareHandler(gate: gate))
            let consuming = Task { try? await consumer.consume(fixture.delivery(batch: batch)) }
            await gate.waitUntilEntered()
            await consumer.close()
            _ = await consuming.value
            #expect(try fixture.jobCount() == 0)
        }
    }

    @Test func coordinatorAdvancesFinitePassAndReopenDoesNotDuplicateJobs() async throws {
        let fixture = try await ConsumerFixture.make()
        try await withConsumerFixture(fixture) { fixture in
            let consumer = try fixture.consumer()
            let registry = RuntimeRegistry<AgentCapability>()
            let scope = RuntimeScope(kind: .application)
            try await registry.register(id: "consumer", value: .consumer(consumer), scope: scope)
            let coordinator = try AgentSessionConsumerCoordinator(journal: fixture.library, registry: registry)
            let target = try await fixture.library.head(sessionID: fixture.sessionID)
            let firstPass = try await coordinator.advance(consumerID: "tests.consumer", through: target, maximumBatches: 1)
            #expect(firstPass.processedBatches == 1)
            #expect(firstPass.hasMore)
            let progress = try await coordinator.advance(consumerID: "tests.consumer", through: target, maximumBatches: 32)
            #expect(progress.processedBatches == (try await fixture.batches()).count - 1)
            #expect(progress.hasMore == false)
            #expect(try fixture.jobCount() == firstPass.processedBatches + progress.processedBatches)
            let checkpoint = try #require(try await consumer.checkpoint(sessionID: fixture.sessionID))
            await coordinator.close()
            await scope.dispose()
            await consumer.close()

            await fixture.runtime.close()
            try await fixture.library.close()
            try fixture.database.close()
            let reopenedLibrary = try FileSessionLibrary(directory: fixture.directory)
            let reopenedDatabase = try DatabaseQueue(path: fixture.directory.appendingPathComponent("business.sqlite").path)
            let reopened = try SQLiteSessionConsumer(database: reopenedDatabase, identity: fixture.identity, handler: ConsumerHandler())
            let reopenedRegistry = RuntimeRegistry<AgentCapability>()
            let reopenedScope = RuntimeScope(kind: .application)
            try await reopenedRegistry.register(id: "consumer", value: .consumer(reopened), scope: reopenedScope)
            let reopenedCoordinator = try AgentSessionConsumerCoordinator(journal: reopenedLibrary, registry: reopenedRegistry)
            let again = try await reopenedCoordinator.advance(consumerID: "tests.consumer", through: target, maximumBatches: 32)
            #expect(again.processedBatches == 0)
            #expect(again.checkpoint == checkpoint)
            #expect(try await reopenedDatabase.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM synthetic_consumer_jobs") } == firstPass.processedBatches + progress.processedBatches)
            await reopenedCoordinator.close()
            await reopenedScope.dispose()
            await reopened.close()
            try reopenedDatabase.close()
            try await reopenedLibrary.close()

        }
    }
}

private enum ConsumerHookFailure: Error { case lost }

private final class ConsumerHookGate: @unchecked Sendable {
    let releaseSemaphore = DispatchSemaphore(value: 0)
    let enteredStream: AsyncStream<Void>
    private let enteredContinuation: AsyncStream<Void>.Continuation
    private let lock = NSLock()
    private var recordedEvents: [String] = []
    var events: [String] { lock.withLock { recordedEvents } }

    init() {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        enteredStream = stream; enteredContinuation = continuation
    }

    func entered() {
        lock.withLock { recordedEvents.append("entered") }
        enteredContinuation.yield(())
    }
    func exited() { record("exited") }
    func closed() { record("closed") }
    private func record(_ event: String) {
        lock.withLock { recordedEvents.append(event) }
    }
}

private struct ConsumerHandler: SQLiteSessionConsumerHandler {
    let failOnPhaseBatch: Bool
    let gate: PrepareGate?

    init(failOnPhaseBatch: Bool = false, gate: PrepareGate? = nil) { self.failOnPhaseBatch = failOnPhaseBatch; self.gate = gate }

    func prepare(_ delivery: AgentSessionConsumerDelivery) async throws -> any SQLiteSessionConsumerTransaction {
        if let gate { await gate.enterAndWait() }
        return ConsumerTransaction(delivery: delivery, failOnPhaseBatch: failOnPhaseBatch)
    }
}

private actor PrepareGate {
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    func enterAndWait() async {
        entered = true; let waiters = enteredWaiters; enteredWaiters.removeAll(); waiters.forEach { $0.resume() }
        if !released { await withCheckedContinuation { releaseWaiters.append($0) } }
    }
    func markEntered() { entered = true; let waiters = enteredWaiters; enteredWaiters.removeAll(); waiters.forEach { $0.resume() } }
    func waitUntilEntered() async { if entered { return }; await withCheckedContinuation { enteredWaiters.append($0) } }
    func release() { released = true; let waiters = releaseWaiters; releaseWaiters.removeAll(); waiters.forEach { $0.resume() } }
}

private struct ThrowingPrepareHandler: SQLiteSessionConsumerHandler {
    func prepare(_ delivery: AgentSessionConsumerDelivery) async throws -> any SQLiteSessionConsumerTransaction {
        throw ConsumerHookFailure.lost
    }
}

private struct CooperativePrepareHandler: SQLiteSessionConsumerHandler {
    let gate: PrepareGate
    func prepare(_ delivery: AgentSessionConsumerDelivery) async throws -> any SQLiteSessionConsumerTransaction {
        await gate.markEntered()
        try await Task.sleep(for: .seconds(60))
        return EmptyConsumerTransaction()
    }
}

private struct EmptyConsumerTransaction: SQLiteSessionConsumerTransaction {
    func apply(in db: Database) throws {}
    func close() async {}
}

private struct ConsumerTransaction: SQLiteSessionConsumerTransaction {
    let delivery: AgentSessionConsumerDelivery
    let failOnPhaseBatch: Bool
    func apply(in db: Database) throws {
        try db.execute(sql: "CREATE TABLE IF NOT EXISTS synthetic_consumer_jobs (batch_id TEXT PRIMARY KEY, event_count INTEGER NOT NULL)")
        try db.execute(sql: "INSERT INTO synthetic_consumer_jobs(batch_id, event_count) VALUES (?, ?)",
            arguments: [delivery.batch.id.uuidString, delivery.batch.events.count])
        if failOnPhaseBatch && delivery.batch.events.contains(where: { event in
            if case .phaseChanged = event.fact { return true }; return false
        }) { throw ConsumerHookFailure.lost }
    }
    func close() async {}
}

private final class ConsumerHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var consumers: [SQLiteSessionConsumer] = []
    func add(_ consumer: SQLiteSessionConsumer) {
        lock.lock(); consumers.append(consumer); lock.unlock()
    }
    private func takeAll() -> [SQLiteSessionConsumer] {
        lock.lock(); let values = consumers; consumers.removeAll(); lock.unlock()
        return values
    }
    func closeAll() async {
        let values = takeAll()
        for consumer in values { await consumer.close() }
    }
}

private func withConsumerFixture<T>(_ fixture: ConsumerFixture,
                                    _ body: (ConsumerFixture) async throws -> T) async throws -> T {
    do {
        let result = try await body(fixture)
        await fixture.shutdown()
        return result
    } catch {
        await fixture.shutdown()
        throw error
    }
}

private final class ConsumerFixture: Sendable {
    let directory: URL
    let database: DatabaseQueue
    let library: FileSessionLibrary
    let runtime: SessionRuntime
    let sessionID: ConversationID
    let identity = AgentSessionConsumerIdentity(id: "tests.consumer", revision: 1)
    let holder = ConsumerHolder()

    static func make() async throws -> ConsumerFixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mira-session-consumer-\(UUID().uuidString)")
        let library: FileSessionLibrary
        do { library = try FileSessionLibrary(directory: directory) }
        catch { try? FileManager.default.removeItem(at: directory); throw error }
        let database: DatabaseQueue
        do { database = try DatabaseQueue(path: directory.appendingPathComponent("business.sqlite").path) }
        catch { try? await library.close(); try? FileManager.default.removeItem(at: directory); throw error }
        do {
            let sessionID = ConversationID()
            let runtime = try await SessionRuntime.open(id: sessionID, journal: library, payloads: library)
            let executionID = ExecutionID()
            let plan = AgentExecutionPlan(runtimeID: UUID(), catalogGeneration: 1, driverID: "tests.driver", driverRevision: 1,
                instructions: "", limits: .init(), priority: .foreground, route: nil)
            let admitted = await runtime.commit(id: UUID()) { context in
                let title = try await context.stageBytes(Data("Consumer test".utf8), kind: .title)
                let body = try await context.stageBytes(Data("Question".utf8), kind: .userText)
                let planReference = try await context.stage(plan, kind: .executionPlan)
                return [.opened(.init(workspaceID: nil, title: title)),
                    .admitted(.init(executionID: executionID, userMessageID: MessageID(), userBody: body,
                        plan: planReference, hasModelRoute: false, authorizationEpoch: 0, timeZoneIdentifier: "UTC"))]
            }
            guard case .committed = admitted else { throw MiraError(.storage, "Consumer fixture admission failed.") }
            let phaseResult = await runtime.commit(id: UUID()) { _ in
                [.phaseChanged(executionID: executionID, phase: .preparing)]
            }
            guard case .committed = phaseResult else { throw MiraError(.storage, "Consumer fixture phase append failed.") }
            let moduleResult = await runtime.commit(id: UUID()) { context in
                let body = try await context.stageBytes(Data("consumer-extension".utf8), kind: .module)
                return [.extensionRecorded(namespace: "tests.consumer", schemaVersion: 1, required: false, body: body)]
            }
            guard case .committed = moduleResult else { throw MiraError(.storage, "Consumer fixture extension append failed.") }
            return .init(directory: directory, database: database, library: library, runtime: runtime, sessionID: sessionID)
        } catch {
            try? database.close(); try? await library.close(); try? FileManager.default.removeItem(at: directory); throw error
        }
    }

    private init(directory: URL, database: DatabaseQueue, library: FileSessionLibrary,
                 runtime: SessionRuntime, sessionID: ConversationID) {
        self.directory = directory; self.database = database; self.library = library; self.runtime = runtime; self.sessionID = sessionID
    }

    func consumer(identity: AgentSessionConsumerIdentity? = nil,
                  handler: any SQLiteSessionConsumerHandler = ConsumerHandler(),
                  afterCommitHook: (@Sendable () throws -> Void)? = nil) throws -> SQLiteSessionConsumer {
        let value = try SQLiteSessionConsumer(database: database, identity: identity ?? self.identity,
            handler: handler, afterCommitHook: afterCommitHook)
        holder.add(value)
        return value
    }

    func batches() async throws -> [SessionBatch] {
        try await library.read(sessionID: sessionID, after: 0, limit: SessionFormatLimits.maximumReadBatches)
    }

    func delivery(batch: SessionBatch, previous: SessionJournalHead? = nil) -> AgentSessionConsumerDelivery {
        .init(consumer: identity, previous: previous ?? .init(cursor: .init(sessionID: sessionID, sequence: 0), batchID: nil), batch: batch)
    }

    func jobCount() throws -> Int {
        try database.read { db in
            guard try db.tableExists("synthetic_consumer_jobs") else { return 0 }
            return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM synthetic_consumer_jobs") ?? 0
        }
    }

    func shutdown() async {
        await holder.closeAll()
        await runtime.close()
        try? await library.close()
        try? database.close()
        try? FileManager.default.removeItem(at: directory)
    }
}
