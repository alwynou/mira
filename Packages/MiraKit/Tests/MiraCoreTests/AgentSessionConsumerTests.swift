import Foundation
import Testing
@testable import MiraCore

@Suite("Agent session consumers", .timeLimit(.minutes(1)))
struct AgentSessionConsumerTests {
    @Test func boundedPassUsesCapturedPrefixAndResumesFromCheckpoint() async throws {
        let fixture = try await ConsumerFixture.make(batchCount: 3)
        do {
            let target = try await fixture.journal.head(sessionID: fixture.sessionID)
            let first = try await fixture.coordinator.advance(consumerID: fixture.consumer.identity.id, through: target, maximumBatches: 2)
            #expect(first.processedBatches == 2)
            #expect(first.hasMore)
            #expect(first.checkpoint.head.cursor.sequence == 2)
            #expect(await fixture.consumer.deliveredSequences == [1, 2])

            _ = await fixture.journal.append(ConsumerFixture.batch(sessionID: fixture.sessionID, expected: 3, sequence: 4))
            let second = try await fixture.coordinator.advance(consumerID: fixture.consumer.identity.id, through: target, maximumBatches: 2)
            #expect(second.processedBatches == 1)
            #expect(!second.hasMore)
            #expect(second.checkpoint.head == target)
            #expect(await fixture.consumer.deliveredSequences == [1, 2, 3])
            let third = try await fixture.coordinator.advance(consumerID: fixture.consumer.identity.id, sessionID: fixture.sessionID)
            #expect(third.checkpoint.head.cursor.sequence == 4)
            #expect(await fixture.consumer.deliveredSequences == [1, 2, 3, 4])
        } catch { await fixture.close(); throw error }
        await fixture.close()
    }

    @Test func duplicateRequestUsesStoredCheckpointWithoutRedispatch() async throws {
        let fixture = try await ConsumerFixture.make(batchCount: 2)
        do {
            let target = try await fixture.journal.head(sessionID: fixture.sessionID)
            let first = try await fixture.coordinator.advance(consumerID: fixture.consumer.identity.id, through: target)
            let second = try await fixture.coordinator.advance(consumerID: fixture.consumer.identity.id, through: target)
            #expect(first.checkpoint == second.checkpoint)
            #expect(second.processedBatches == 0)
            #expect(await fixture.consumer.consumeCount == 2)
        } catch { await fixture.close(); throw error }
        await fixture.close()
    }

    @Test func failedConsumerDoesNotAdvanceAndNextPassResumes() async throws {
        let fixture = try await ConsumerFixture.make(batchCount: 3)
        do {
            await fixture.consumer.fail(sequence: 2)
            let target = try await fixture.journal.head(sessionID: fixture.sessionID)
            await #expect(throws: MiraError.self) {
                try await fixture.coordinator.advance(consumerID: fixture.consumer.identity.id, through: target)
            }
            #expect(await fixture.consumer.storedSequence == 1)
            await fixture.consumer.fail(sequence: nil)
            let progress = try await fixture.coordinator.advance(consumerID: fixture.consumer.identity.id, through: target)
            #expect(progress.checkpoint.head == target)
            #expect(await fixture.consumer.deliveredSequences == [1, 2, 3])
        } catch { await fixture.close(); throw error }
        await fixture.close()
    }

    @Test func invalidJournalAndCheckpointDataAreRejectedBeforeConsume() async throws {
        let malformed = try await ConsumerFixture.make(batches: [ConsumerFixture.batch(sessionID: ConversationID(), expected: 0, sequence: 2)])
        do {
            let target = try await malformed.journal.head(sessionID: malformed.sessionID)
            await #expect(throws: MiraError.self) {
                try await malformed.coordinator.advance(consumerID: malformed.consumer.identity.id, through: target)
            }
            #expect(await malformed.consumer.consumeCount == 0)
        } catch { await malformed.close(); throw error }
        await malformed.close()

        let wrongRevision = try await ConsumerFixture.make(batchCount: 1)
        do {
            let target = try await wrongRevision.journal.head(sessionID: wrongRevision.sessionID)
            await wrongRevision.consumer.overrideCheckpoint(.init(
                consumer: .init(id: wrongRevision.consumer.identity.id, revision: 2), head: target))
            await #expect(throws: MiraError.self) {
                try await wrongRevision.coordinator.advance(consumerID: wrongRevision.consumer.identity.id, through: target)
            }
            #expect(await wrongRevision.consumer.consumeCount == 0)
        } catch { await wrongRevision.close(); throw error }
        await wrongRevision.close()

        let gapSession = ConversationID()
        let gap = try await ConsumerFixture.make(batches: [
            ConsumerFixture.batch(sessionID: gapSession, expected: 0, sequence: 1),
            ConsumerFixture.batch(sessionID: gapSession, expected: 2, sequence: 3)
        ])
        do {
            let target = try await gap.journal.head(sessionID: gap.sessionID)
            await #expect(throws: MiraError.self) {
                try await gap.coordinator.advance(consumerID: gap.consumer.identity.id, through: target)
            }
            #expect(await gap.consumer.deliveredSequences == [1])
        } catch { await gap.close(); throw error }
        await gap.close()

        let ahead = try await ConsumerFixture.make(batchCount: 1)
        do {
            let target = try await ahead.journal.head(sessionID: ahead.sessionID)
            let head = SessionJournalHead(cursor: .init(sessionID: ahead.sessionID, sequence: target.cursor.sequence + 1), batchID: UUID())
            await ahead.consumer.overrideCheckpoint(.init(consumer: ahead.consumer.identity, head: head))
            await #expect(throws: MiraError.self) {
                try await ahead.coordinator.advance(consumerID: ahead.consumer.identity.id, through: target)
            }
            #expect(await ahead.consumer.consumeCount == 0)
        } catch { await ahead.close(); throw error }
        await ahead.close()

        let mismatched = try await ConsumerFixture.make(batchCount: 1)
        do {
            let target = try await mismatched.journal.head(sessionID: mismatched.sessionID)
            let head = SessionJournalHead(cursor: target.cursor, batchID: UUID())
            await mismatched.consumer.overrideCheckpoint(.init(consumer: mismatched.consumer.identity, head: head))
            await #expect(throws: MiraError.self) {
                try await mismatched.coordinator.advance(consumerID: mismatched.consumer.identity.id, through: target)
            }
            #expect(await mismatched.consumer.consumeCount == 0)
        } catch { await mismatched.close(); throw error }
        await mismatched.close()

        let unknown = try await ConsumerFixture.make(extensionBatch: true)
        do {
            let target = try await unknown.journal.head(sessionID: unknown.sessionID)
            await #expect(throws: MiraError.self) {
                try await unknown.coordinator.advance(consumerID: unknown.consumer.identity.id, through: target)
            }
            #expect(await unknown.consumer.consumeCount == 0)
        } catch { await unknown.close(); throw error }
        await unknown.close()
    }

    @Test func cancelledWaiterLeavesOriginalOwnerToComplete() async throws {
        let fixture = try await ConsumerFixture.make(batchCount: 1)
        do {
            await fixture.consumer.hold(sequence: 1)
            let target = try await fixture.journal.head(sessionID: fixture.sessionID)
            let owner = Task { try await fixture.coordinator.advance(consumerID: fixture.consumer.identity.id, through: target) }
            await fixture.consumer.entered.wait()
            owner.cancel()
            await fixture.consumer.release()
            await #expect(throws: CancellationError.self) { try await owner.value }
            let progress = try await fixture.coordinator.advance(consumerID: fixture.consumer.identity.id, through: target)
            #expect(progress.checkpoint.head == target)
            #expect(progress.processedBatches == 0)
            #expect(await fixture.consumer.consumeCount == 1)
        } catch { await fixture.close(); throw error }
        await fixture.close()
    }

    @Test func closeCancelsAndDrainsConsumerBeforeScopeDisposal() async throws {
        let fixture = try await ConsumerFixture.make(batchCount: 1)
        do {
            let target = try await fixture.journal.head(sessionID: fixture.sessionID)
            await fixture.consumer.hold(sequence: 1)
            let owner = Task { try await fixture.coordinator.advance(consumerID: fixture.consumer.identity.id, through: target) }
            await fixture.consumer.entered.wait()
            let closeFinished = AsyncGate()
            let closing = Task {
                await fixture.coordinator.close()
                await closeFinished.release()
            }
            await fixture.consumer.cancelObserved.wait()
            #expect(!(await closeFinished.isOpen))
            let scopeClosing = AsyncGate(), scopeCleaned = AsyncGate()
            _ = try await fixture.scope.registerClosing { await scopeClosing.release() }
            try await fixture.scope.registerCleanup { await scopeCleaned.release() }
            let disposing = Task { await fixture.scope.dispose() }
            await scopeClosing.wait()
            #expect(!(await scopeCleaned.isOpen))
            await fixture.consumer.finishDrain()
            await closeFinished.wait()
            #expect(await fixture.consumer.drained)
            await disposing.value
            #expect(await scopeCleaned.isOpen)
            _ = try? await owner.value
            _ = await closing.value
            try? await fixture.journal.close()
        } catch {
            await fixture.consumer.finishDrain()
            await fixture.close()
            throw error
        }
    }

    @Test func duplicateConsumerIdentitiesAreRejectedByCatalog() async throws {
        let registry = RuntimeRegistry<AgentCapability>()
        let scope = RuntimeScope(kind: .application)
        let first = RecordingConsumer(identity: .init(id: "duplicate", revision: 1))
        let second = RecordingConsumer(identity: .init(id: "duplicate", revision: 2))
        try await registry.register(id: "first", value: .consumer(first), scope: scope)
        try await registry.register(id: "second", value: .consumer(second), scope: scope)
        let snapshot = try await registry.freeze()
        do {
            _ = try AgentRuntimeCatalog(snapshot: snapshot)
            Issue.record("Duplicate consumer identities were accepted.")
            await snapshot.release()
        } catch {
            await snapshot.release()
        }
        await scope.dispose()
    }
}

private actor AsyncGate {
    private var open = false
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    var isOpen: Bool { open }

    func wait() async {
        if open { return }
        let id = UUID()
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                if open { continuation.resume() } else { waiters[id] = continuation }
            }
        }, onCancel: { Task { await self.cancel(id) } })
    }

    func waitIgnoringCancellation() async {
        if open { return }
        await withCheckedContinuation { continuation in
            if open { continuation.resume() } else { waiters[UUID()] = continuation }
        }
    }

    func release() {
        open = true
        let pending = waiters.values
        waiters.removeAll()
        for continuation in pending { continuation.resume() }
    }

    private func cancel(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume()
    }
}

private actor RecordingConsumer: AgentSessionConsumer {
    let identity: AgentSessionConsumerIdentity
    private var checkpointValue: AgentSessionConsumerCheckpoint?
    private(set) var deliveredSequences: [Int64] = []
    private(set) var consumeCount = 0
    private(set) var drained = false
    private var failureSequence: Int64?
    private var holdSequence: Int64?
    private var holdGate: AsyncGate?
    let entered = AsyncGate()
    let cancelObserved = AsyncGate()
    private let drainGate = AsyncGate()
    init(identity: AgentSessionConsumerIdentity = .init(id: "consumer", revision: 1)) { self.identity = identity }

    func checkpoint(sessionID: ConversationID) async throws -> AgentSessionConsumerCheckpoint? { checkpointValue }
    var storedSequence: Int64? { checkpointValue?.head.cursor.sequence }
    func fail(sequence: Int64?) { failureSequence = sequence }
    func hold(sequence: Int64?) { holdSequence = sequence }
    func release() async {
        holdSequence = nil
        await holdGate?.release()
    }
    func finishDrain() async { await drainGate.release() }
    func overrideCheckpoint(_ value: AgentSessionConsumerCheckpoint) { checkpointValue = value }

    func consume(_ delivery: AgentSessionConsumerDelivery) async throws -> AgentSessionConsumerCheckpoint {
        do {
            if failureSequence == delivery.batch.cursor.sequence {
                await entered.release()
                throw MiraError(.storage, "Synthetic consumer failure.")
            }
            if holdSequence == delivery.batch.cursor.sequence {
                let gate = AsyncGate()
                holdGate = gate
                await entered.release()
                await withTaskCancellationHandler(operation: {
                    await gate.wait()
                }, onCancel: { Task { await gate.release() } })
                holdGate = nil
                if Task.isCancelled {
                    await cancelObserved.release()
                    await drainGate.waitIgnoringCancellation()
                }
            } else {
                await entered.release()
            }
            try Task.checkCancellation()
            let checkpoint = delivery.checkpoint
            checkpointValue = checkpoint
            deliveredSequences.append(delivery.batch.cursor.sequence)
            consumeCount += 1
            return checkpoint
        } catch {
            drained = true
            throw error
        }
    }
}

private actor ConsumerJournal: SessionJournal {
    private var batches: [SessionBatch]
    init(batches: [SessionBatch]) { self.batches = batches }
    func append(_ batch: SessionBatch) async -> SessionAppendOutcome { batches.append(batch); return .committed(batch.cursor) }
    func reconcile(_ batch: SessionBatch) async -> SessionAppendOutcome { await append(batch) }
    func batch(id: UUID, sessionID: ConversationID) async throws -> SessionBatch? { batches.first { $0.id == id && $0.sessionID == sessionID } }
    func head(sessionID: ConversationID) async throws -> SessionJournalHead {
        guard let batch = batches.filter({ $0.sessionID == sessionID }).max(by: { $0.cursor.sequence < $1.cursor.sequence }) else {
            return .init(cursor: .init(sessionID: sessionID, sequence: 0), batchID: nil)
        }
        return .init(cursor: batch.cursor, batchID: batch.id)
    }
    func read(sessionID: ConversationID, after sequence: Int64, limit: Int) async throws -> [SessionBatch] {
        Array(batches.filter { $0.sessionID == sessionID && $0.expectedSequence >= sequence && $0.cursor.sequence > sequence }.prefix(limit))
    }
    func sessions(after: ConversationID?, limit: Int) async throws -> [ConversationID] { Array(Set(batches.map(\.sessionID)).prefix(limit)) }
    func flush() async throws {}
    func close() async throws {}
}

private final class ConsumerFixture: Sendable {
    let journal: ConsumerJournal
    let registry: RuntimeRegistry<AgentCapability>
    let scope: RuntimeScope
    let coordinator: AgentSessionConsumerCoordinator
    let consumer: RecordingConsumer
    let sessionID: ConversationID

    static func make(batchCount: Int = 0, batches: [SessionBatch]? = nil, extensionBatch: Bool = false) async throws -> ConsumerFixture {
        let sessionID = batches?.first?.sessionID ?? ConversationID()
        var entries = batches ?? (batchCount > 0 ? (1...batchCount).map {
            batch(sessionID: sessionID, expected: Int64($0 - 1), sequence: Int64($0))
        } : [])
        if extensionBatch {
            let id = UUID()
            let body = SessionPayloadReference(id: UUID(), sessionID: sessionID, batchID: id, retentionGroup: UUID(), kind: .module, byteCount: 1, digest: String(repeating: "a", count: 64))
            entries = [batch(sessionID: sessionID, expected: 0, sequence: 1, id: id, fact: .extensionRecorded(namespace: "unknown", schemaVersion: 1, required: true, body: body))]
        }
        let journal = ConsumerJournal(batches: entries)
        let registry = RuntimeRegistry<AgentCapability>(), scope = RuntimeScope(kind: .application)
        let consumer = RecordingConsumer()
        do {
            try await registry.register(id: consumer.identity.id, value: .consumer(consumer), scope: scope)
            let coordinator = try AgentSessionConsumerCoordinator(journal: journal, registry: registry)
            return .init(journal: journal, registry: registry, scope: scope, coordinator: coordinator, consumer: consumer, sessionID: sessionID)
        } catch {
            await scope.dispose(); try? await journal.close(); throw error
        }
    }

    private init(journal: ConsumerJournal, registry: RuntimeRegistry<AgentCapability>, scope: RuntimeScope,
                 coordinator: AgentSessionConsumerCoordinator, consumer: RecordingConsumer, sessionID: ConversationID) {
        self.journal = journal; self.registry = registry; self.scope = scope; self.coordinator = coordinator; self.consumer = consumer; self.sessionID = sessionID
    }

    func close() async {
        await consumer.release()
        await consumer.finishDrain()
        await coordinator.close()
        await scope.dispose()
        try? await journal.close()
    }

    static func batch(sessionID: ConversationID, expected: Int64, sequence: Int64, id: UUID = UUID(), fact: SessionFact = .archived(revision: 1)) -> SessionBatch {
        .init(id: id, sessionID: sessionID, expectedSequence: expected,
              events: [.init(sequence: sequence, occurredAt: Date(timeIntervalSince1970: Double(sequence)), fact: fact)])
    }
}
