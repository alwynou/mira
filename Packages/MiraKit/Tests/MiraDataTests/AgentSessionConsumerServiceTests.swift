import Foundation
import Testing

@testable import MiraCore
@testable import MiraData

@Suite("Library session consumer service", .timeLimit(.minutes(1)))
struct AgentSessionConsumerServiceTests {
    @Test func boundedPagesRotatePastHotSessionsAndFailedConsumers() async throws {
        let ids = [session(1), session(2), session(3)]
        let journal = ServiceJournal(counts: [ids[0]: 5, ids[1]: 1, ids[2]: 1])
        let healthy = ServiceConsumer(id: "healthy")
        let broken = ServiceConsumer(id: "broken", fails: true)
        try await withService(journal: journal, consumers: [healthy, broken]) { f in
            for _ in 0..<100 { await f.service.wake() }
            try await wait { await healthy.delivered.count == 7 }
            #expect(Array(await healthy.delivered.prefix(3)) == ids)
            #expect(await healthy.checkpoint(sessionID: ids[0])?.head.cursor.sequence == 5)
            #expect(await broken.delivered.isEmpty)
            #expect(await broken.attempts > 0)
            #expect(await journal.largestRequestedPage == 1)
        }
    }

    @Test func periodicScanFindsNewEarlierSessionWithoutNotifications() async throws {
        let original = session(2)
        let added = session(1)
        let journal = ServiceJournal(counts: [original: 1])
        let consumer = ServiceConsumer(id: "durable")
        try await withService(journal: journal, consumers: [consumer]) { f in
            try await wait { await consumer.delivered.count == 1 }
            await journal.add(sessionID: original)
            await journal.add(sessionID: added)
            // There is deliberately no wake and no application event delivery.
            try await wait { await consumer.delivered.count == 3 }
            #expect(await consumer.checkpoint(sessionID: added)?.head.cursor.sequence == 1)
            #expect(await consumer.checkpoint(sessionID: original)?.head.cursor.sequence == 2)
            await f.service.close()
            let reopened = try await AgentSessionConsumerService.open(
                journal: journal, registry: f.registry,
                access: f.data.access, scope: f.scope,
                limits: .init(
                    sessionsPerPage: 1, batchesPerPass: 1,
                    reconciliationSeconds: 1, pageDelayMilliseconds: 1))
            do {
                let before = await journal.pages
                try await wait { await journal.pages >= before + 3 }
                #expect(await consumer.delivered.count == 3)
                await journal.add(sessionID: original)
                await reopened.wake()
                try await wait { await consumer.delivered.count == 4 }
            } catch {
                await reopened.close()
                throw error
            }
            await reopened.close()
        }
    }

    @Test(arguments: [false, true])
    func closeAndMaintenanceDrainTheRealConsumer(revokeLibrary: Bool) async throws {
        let journal = ServiceJournal(counts: [session(1): 1])
        let consumer = ServiceConsumer(id: "held", held: true)
        try await withService(journal: journal, consumers: [consumer]) { f in
            try await wait { await consumer.gate.entered }
            if revokeLibrary {
                _ = try await f.data.access.begin(
                    .init(
                        id: UUID(), namespace: "synthetic.maintenance", revision: 1,
                        scope: .library, requestedAt: TaskWorkflowFixture.now),
                    expected: f.data.authority.authorization())
            }
            let finished = ServiceFlag()
            let closer = Task {
                await f.service.close()
                await finished.mark()
            }
            do {
                try await wait { await consumer.gate.cancelled }
                #expect(await finished.value == false)
                #expect(await consumer.delivered.isEmpty)
                await consumer.gate.open()
                await closer.value
                #expect(await f.service.status() == .closed)
                #expect(await consumer.delivered.isEmpty)
                if revokeLibrary {
                    #expect(await f.data.runtime.shutdown().isSettled)
                    await f.data.tasks.close()
                    await f.data.reminders.close()
                    try await f.data.access.waitForQuiescence()
                    #expect(await f.data.access.snapshot().activeLeases == 0)
                }
            } catch {
                await consumer.gate.open()
                await closer.value
                throw error
            }
        }
    }

    @Test func scopeDisposalClosesServiceBeforeReleasingRegistrations() async throws {
        let journal = ServiceJournal(counts: [session(1): 1])
        let consumer = ServiceConsumer(id: "scoped")
        try await withService(journal: journal, consumers: [consumer]) { f in
            try await wait { await consumer.delivered.count == 1 }
            await f.scope.dispose()
            #expect(await f.service.status() == .closed)
            let stream = try await f.service.events()
            var iterator = stream.makeAsyncIterator()
            #expect(await iterator.next() == nil)
            // The shared journal is still owned by composition, not by this service.
            await journal.add(sessionID: session(1))
            #expect(try await journal.head(sessionID: session(1)).cursor.sequence == 2)
        }
    }

    @Test(arguments: [ServiceJournal.Fault.duplicatePage, .wrongHead, .repeatingPage])
    fileprivate func invalidCanonicalEnumerationIsReportedWithoutInventingProgress(fault: ServiceJournal.Fault)
        async throws
    {
        let journal = ServiceJournal(counts: [session(1): 1, session(2): 1], fault: fault)
        let consumer = ServiceConsumer(id: "guarded")
        try await withService(journal: journal, consumers: [consumer]) { f in
            let stream = try await f.service.events()
            let failure = Task { () -> MiraError? in
                for await event in stream {
                    if case .failure(_, _, let error) = event { return error }
                }
                return nil
            }
            let error = await failure.value
            #expect(error?.code == .storage)
            #expect(await consumer.delivered.count == (fault == .repeatingPage ? 1 : 0))
        }
    }

    @Test func openingDuringScopeDisposalCannotLeakLibraryLeases() async throws {
        let journal = ServiceJournal(counts: [:])
        try await withService(journal: journal, consumers: []) { f in
            let baseline = await f.data.access.snapshot().activeLeases - 1
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<16 {
                    group.addTask {
                        do {
                            let opened = try await AgentSessionConsumerService.open(
                                journal: journal,
                                registry: f.registry, access: f.data.access, scope: f.scope)
                            await opened.close()
                        } catch let error as RuntimeScopeError {
                            #expect(error == .disposed)
                        } catch let error as MiraError {
                            #expect([.cancelled, .unauthorized].contains(error.code))
                        } catch { Issue.record(error) }
                    }
                }
                group.addTask { await f.scope.dispose() }
            }
            #expect(await f.service.status() == .closed)
            #expect(await f.data.access.snapshot().activeLeases == baseline)
            #expect(await f.data.access.snapshot().acquiringLeases == 0)
        }
    }

    @Test func closedServiceDoesNotRetainItselfThroughRevocation() async throws {
        let journal = ServiceJournal(counts: [:])
        try await withService(journal: journal, consumers: []) { f in
            var opened: AgentSessionConsumerService? = try await AgentSessionConsumerService.open(
                journal: journal, registry: f.registry, access: f.data.access, scope: f.scope)
            weak var released = opened
            await opened?.close()
            opened = nil
            #expect(released == nil)
        }
    }

    @Test func brokenClockStopsWithoutSpinningAndRemainsObservable() async throws {
        let journal = ServiceJournal(counts: [:])
        let consumer = ServiceConsumer(id: "clock")
        try await withService(
            journal: journal, consumers: [consumer],
            environment: .init(sleep: { _ in
                throw MiraError(.storage, "Synthetic clock failure.")
            })
        ) { f in
            try await wait { if case .failed = await f.service.status() { true } else { false } }
            let before = await journal.pages
            await f.service.wake()
            let stream = try await f.service.events()
            var iterator = stream.makeAsyncIterator()
            guard case .failure = await iterator.next() else {
                Issue.record("Missing terminal failure.")
                return
            }
            #expect(await journal.pages == before)
        }
    }

    private func withService(
        journal: ServiceJournal, consumers: [ServiceConsumer],
        environment: RuntimeEnvironment = .init(),
        _ body: (ServiceFixture) async throws -> Void
    ) async throws {
        try await withTaskWorkflow(outputs: []) { data in
            let registry = RuntimeRegistry<AgentCapability>()
            let scope = RuntimeScope(kind: .application)
            for consumer in consumers {
                try await registry.register(id: consumer.identity.id, value: .consumer(consumer), scope: scope)
            }
            let service = try await AgentSessionConsumerService.open(
                journal: journal, registry: registry,
                access: data.access, scope: scope, environment: environment,
                limits: .init(
                    sessionsPerPage: 1, batchesPerPass: 1,
                    reconciliationSeconds: 1, pageDelayMilliseconds: 1))
            do { try await body(.init(service: service, scope: scope, registry: registry, data: data)) } catch {
                for consumer in consumers { await consumer.gate.open() }
                await service.close()
                await scope.dispose()
                throw error
            }
            for consumer in consumers { await consumer.gate.open() }
            await service.close()
            await scope.dispose()
        }
    }
    private func session(_ number: Int) -> ConversationID {
        .init(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!)
    }
    private func wait(_ condition: @escaping @Sendable () async throws -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while try await !condition() {
            guard clock.now < deadline else { throw MiraError(.timeout, "Synthetic consumer service wait expired.") }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}

private struct ServiceFixture: Sendable {
    let service: AgentSessionConsumerService
    let scope: RuntimeScope
    let registry: RuntimeRegistry<AgentCapability>
    let data: TaskWorkflowFixture
}
private actor ServiceFlag {
    private(set) var value = false
    func mark() { value = true }
}
private actor ServiceGate {
    private(set) var entered = false
    private(set) var cancelled = false
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        entered = true
        if !isOpen { await withCheckedContinuation { waiters.append($0) } }
    }
    func cancel() { cancelled = true }
    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}
private actor ServiceConsumer: AgentSessionConsumer {
    nonisolated let identity: AgentSessionConsumerIdentity
    let gate = ServiceGate()
    private let fails: Bool
    private let held: Bool
    private var checkpoints: [ConversationID: AgentSessionConsumerCheckpoint] = [:]
    private(set) var delivered: [ConversationID] = []
    private(set) var attempts = 0
    init(id: String, fails: Bool = false, held: Bool = false) {
        identity = .init(id: id, revision: 1)
        self.fails = fails
        self.held = held
    }
    func checkpoint(sessionID: ConversationID) -> AgentSessionConsumerCheckpoint? { checkpoints[sessionID] }
    func consume(_ delivery: AgentSessionConsumerDelivery) async throws -> AgentSessionConsumerCheckpoint {
        attempts += 1
        if fails { throw MiraError(.storage, "Synthetic consumer failure.") }
        if held {
            let gate = gate
            await withTaskCancellationHandler {
                await gate.wait()
            } onCancel: {
                Task { await gate.cancel() }
            }
        }
        try Task.checkCancellation()
        checkpoints[delivery.batch.sessionID] = delivery.checkpoint
        delivered.append(delivery.batch.sessionID)
        return delivery.checkpoint
    }
}
private actor ServiceJournal: SessionJournal {
    enum Fault: Sendable { case duplicatePage, wrongHead, repeatingPage }
    private var batches: [ConversationID: [SessionBatch]]
    private let fault: Fault?
    private(set) var pages = 0
    private(set) var largestRequestedPage = 0
    init(counts: [ConversationID: Int], fault: Fault? = nil) {
        self.fault = fault
        batches = counts.mapValues { _ in [] }
        for (id, count) in counts {
            for index in 0..<count { batches[id, default: []].append(Self.batch(id, sequence: index + 1)) }
        }
    }
    func add(sessionID: ConversationID) {
        let sequence = (batches[sessionID]?.count ?? 0) + 1
        batches[sessionID, default: []].append(Self.batch(sessionID, sequence: sequence))
    }
    func append(_ batch: SessionBatch) async -> SessionAppendOutcome {
        batches[batch.sessionID, default: []].append(batch)
        return .committed(batch.cursor)
    }
    func reconcile(_ batch: SessionBatch) async -> SessionAppendOutcome { await append(batch) }
    func batch(id: UUID, sessionID: ConversationID) -> SessionBatch? { batches[sessionID]?.first { $0.id == id } }
    func head(sessionID: ConversationID) -> SessionJournalHead {
        if fault == .wrongHead { return .init(cursor: .init(sessionID: .init(), sequence: 0), batchID: nil) }
        guard let batch = batches[sessionID]?.last else {
            return .init(cursor: .init(sessionID: sessionID, sequence: 0), batchID: nil)
        }
        return .init(cursor: batch.cursor, batchID: batch.id)
    }
    func read(sessionID: ConversationID, after sequence: Int64, limit: Int) -> [SessionBatch] {
        Array((batches[sessionID] ?? []).filter { $0.expectedSequence >= sequence }.prefix(limit))
    }
    func sessions(after: ConversationID?, limit: Int) -> [ConversationID] {
        pages += 1
        largestRequestedPage = max(largestRequestedPage, limit)
        let ids = batches.keys.sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }
        if fault == .duplicatePage, let first = ids.first { return [first, first] }
        if fault == .repeatingPage, let first = ids.first { return [first] }
        return Array(
            ids.filter { id in after.map { $0.rawValue.uuidString < id.rawValue.uuidString } ?? true }.prefix(limit))
    }
    func flush() async throws {}
    func close() async throws {}
    private static func batch(_ sessionID: ConversationID, sequence: Int) -> SessionBatch {
        .init(
            id: UUID(), sessionID: sessionID, expectedSequence: Int64(sequence - 1),
            events: [
                .init(
                    sequence: Int64(sequence), occurredAt: TaskWorkflowFixture.now, fact: .archived(revision: sequence))
            ])
    }
}
