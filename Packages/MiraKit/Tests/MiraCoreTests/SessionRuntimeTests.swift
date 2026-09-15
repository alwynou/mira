import Foundation
import Testing
@testable import MiraCore

@Suite("Session command lane")
struct SessionRuntimeTests {
    @Test func closeDrainsCheckpointPublicationAndCancellationPreservesTheCommit() async throws {
        let store = RuntimeJournalFixture(), runtime = try await openedRuntime(store)
        await store.pauseNextCache()
        let commit = Task { await runtime.commit(id: UUID()) { _ in [.archived(revision: 2)] } }
        do {
            try await eventually { await store.cacheEntered }
            commit.cancel()
            let completed = PreparationCounter()
            let close = Task { await runtime.close(); await completed.increment() }
            try await eventually { await runtime.currentObservation().isClosing }
            #expect(await completed.value == 0)
            #expect(await runtime.snapshot().isArchived)
            await store.releaseCache()
            guard case .committed = await commit.value else { Issue.record("Cache cancellation changed an acknowledged commit."); await close.value; return }
            await close.value
            #expect(await completed.value == 1)
            #expect(await store.cachedSequences == [0, 1, 2])
        } catch {
            await store.releaseCache(); _ = await commit.value; await runtime.close(); throw error
        }
    }

    @Test func uncertainStateIsCachedOnlyAfterReconciliationAcknowledgesIt() async throws {
        let store = RuntimeJournalFixture(), runtime = try await openedRuntime(store)
        let before = await store.cachedSequences
        await store.setMode(.commitWithoutAcknowledgement)
        guard case .indeterminate = await admit(runtime, executionID: ExecutionID()) else { Issue.record("Expected uncertainty."); return }
        #expect(await store.cachedSequences == before)
        guard case .committed = await runtime.reconcile() else { Issue.record("Expected reconciliation."); return }
        #expect(await store.cachedSequences == before + [2])
        await runtime.close()
    }

    private func eventually(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw MiraError(.interrupted, "Synthetic checkpoint wait expired.") }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    @Test func competingAdmissionCannotPassSuspendedCommit() async throws {
        let store = RuntimeJournalFixture()
        let runtime = try await openedRuntime(store)
        await store.pauseNextAppend()
        let firstID = ExecutionID(); let secondID = ExecutionID()
        let first = Task { await admit(runtime, executionID: firstID) }
        await store.waitForAppend()
        let second = Task { await admit(runtime, executionID: secondID) }
        await store.releaseAppend()
        guard case .committed = await first.value else { Issue.record("First admission did not commit"); return }
        guard case .notCommitted = await second.value else { Issue.record("Competing admission was accepted"); return }
        let state = await runtime.snapshot()
        #expect(state.executionOrder == [firstID])
        #expect(await store.appendCount == 2)
        await runtime.close()
    }

    @Test func uncertainCommitFencesNewCommandsAndReconcilesOriginalIdentity() async throws {
        let store = RuntimeJournalFixture(); let runtime = try await openedRuntime(store)
        let executionID = ExecutionID(); let commandID = UUID()
        await store.setMode(.commitWithoutAcknowledgement)
        guard case .indeterminate(let pendingID, _) = await admit(runtime, executionID: executionID, commandID: commandID) else {
            Issue.record("Uncertainty was not surfaced"); return
        }
        #expect(pendingID == commandID)
        #expect(await runtime.snapshot().activeExecutionID == nil)
        let counter = PreparationCounter()
        let blocked = await runtime.commit(id: UUID()) { _ in await counter.increment(); return [] }
        guard case .indeterminate = blocked else { Issue.record("New command passed the fence"); return }
        #expect(await counter.value == 0)
        guard case .committed = await runtime.reconcile() else { Issue.record("Original commit was not reconciled"); return }
        #expect(await runtime.snapshot().activeExecutionID == executionID)
        let duplicate = await runtime.commit(id: commandID) { _ in await counter.increment(); return [] }
        guard case .committed = duplicate else { Issue.record("Duplicate command lost its result"); return }
        #expect(await counter.value == 0)
        #expect(await store.appendCount == 2)
        await runtime.close()
    }

    @Test func uncertainAbsentCommitReusesPreparedBatchAndPayloads() async throws {
        let store = RuntimeJournalFixture(); let runtime = try await openedRuntime(store)
        await store.setMode(.uncertainBeforePublication)
        let executionID = ExecutionID()
        guard case .indeterminate = await admit(runtime, executionID: executionID) else { Issue.record("Expected uncertainty"); return }
        let stagedCount = await store.stageCount
        guard case .committed = await runtime.reconcile() else { Issue.record("Reconciliation failed"); return }
        #expect(await store.stageCount == stagedCount)
        let state = await runtime.snapshot()
        #expect(state.activeExecutionID == executionID)
        let reopened = try await SessionRuntime.open(id: state.id, journal: store, payloads: store)
        #expect(await reopened.snapshot() == state)
        await runtime.close(); await reopened.close()
    }

    @Test func cancellationDuringPreparationPreventsSuccessfulSettlement() async throws {
        let store = RuntimeJournalFixture(); let runtime = try await openedRuntime(store)
        let executionID = ExecutionID()
        _ = await admit(runtime, executionID: executionID)
        let gate = PreparationGate()
        let result = Task {
            await runtime.commit(id: UUID()) { context in
                await gate.suspend()
                let answer = try await context.stageBytes(Data("answer".utf8), kind: .visibleAnswer, retentionGroup: UUID())
                return [.phaseChanged(executionID: executionID, phase: .settling),
                        .finished(.init(executionID: executionID, status: .completed,
                            assistantMessageID: MessageID(), answer: answer))]
            }
        }
        await gate.waitForEntry()
        await runtime.requestCancellation(executionID: executionID)
        await gate.release()
        guard case .notCommitted(let error) = await result.value else { Issue.record("Cancellation was overtaken"); return }
        #expect(error.code == .cancelled)
        let cancellation = await runtime.commit(id: UUID()) { _ in
            [.phaseChanged(executionID: executionID, phase: .cancelling),
             .finished(.init(executionID: executionID, status: .cancelled))]
        }
        guard case .committed = cancellation else { Issue.record("Cancellation failed to settle"); return }
        #expect(await runtime.snapshot().executions[executionID]?.completion?.status == .cancelled)
        await runtime.close()
    }

    @Test func cancellationDuringAppendConsumesDurableOutcomeBeforeNextCommand() async throws {
        let store = RuntimeJournalFixture(); let runtime = try await openedRuntime(store)
        let executionID = ExecutionID()
        await store.pauseNextAppend()
        let task = Task { await admit(runtime, executionID: executionID) }
        await store.waitForAppend()
        task.cancel()
        await store.releaseAppend()
        guard case .committed = await task.value else { Issue.record("Committed acceptance was lost to task cancellation"); return }
        #expect(await runtime.snapshot().activeExecutionID == executionID)
        await runtime.close()
    }

    @Test func closeDrainsInFlightWriteAndRejectsPreparedNewWork() async throws {
        let store = RuntimeJournalFixture(); let runtime = try await openedRuntime(store)
        let gate = PreparationGate()
        let commit = Task {
            await runtime.commit(id: UUID()) { _ in
                await gate.suspend()
                return [.archived(revision: 2)]
            }
        }
        await gate.waitForEntry()
        var iterator = await runtime.observations().makeAsyncIterator()
        let close = Task { await runtime.close() }
        while let observation = await iterator.next(), !observation.isClosing {}
        await gate.release()
        await close.value
        guard case .notCommitted = await commit.value else { Issue.record("Closed runtime accepted prepared work"); return }
        #expect(await runtime.snapshot().isArchived == false)
    }

    @Test func coalescedObservationCanBeRecoveredFromDurableCursor() async throws {
        let store = RuntimeJournalFixture(); let runtime = try await openedRuntime(store)
        let stream = await runtime.observations()
        for revision in 2...8 {
            let result = await runtime.commit(id: UUID()) { context in
                let title = try await context.stageBytes(Data("title".utf8), kind: .title, retentionGroup: UUID())
                return [.renamed(title: title, revision: revision)]
            }
            guard case .committed = result else { Issue.record("Rename failed"); return }
        }
        var iterator = stream.makeAsyncIterator()
        let last = try #require(await iterator.next())
        #expect(last.cursor.sequence == 8)
        #expect(try await runtime.read(after: 0).flatMap(\.events).count == 8)
        await runtime.close()
    }

    private func openedRuntime(_ store: RuntimeJournalFixture) async throws -> SessionRuntime {
        let runtime = try await SessionRuntime.open(id: ConversationID(), journal: store, payloads: store)
        let result = await runtime.commit(id: UUID()) { context in
            let title = try await context.stageBytes(Data("Synthetic session".utf8), kind: .title, retentionGroup: UUID())
            return [.opened(.init(workspaceID: nil, title: title))]
        }
        guard case .committed = result else { throw MiraError(.storage, "Fixture initialization failed.") }
        return runtime
    }

    private func admit(_ runtime: SessionRuntime, executionID: ExecutionID, commandID: UUID = UUID()) async -> SessionCommitResult {
        await runtime.commit(id: commandID) { context in
            let user = try await context.stageBytes(Data("Synthetic input".utf8), kind: .userText, retentionGroup: UUID())
            let route = try await context.stageBytes(Data("Synthetic route".utf8), kind: .executionPlan, retentionGroup: UUID())
            return [.admitted(.init(executionID: executionID, userMessageID: MessageID(), userBody: user,
                                   plan: route, hasModelRoute: true, authorizationEpoch: context.state.authorizationEpoch, timeZoneIdentifier: "UTC"))]
        }
    }
}

private actor PreparationCounter {
    var value = 0
    func increment() { value += 1 }
}

private actor PreparationGate {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var suspended: CheckedContinuation<Void, Never>?
    func suspend() async {
        entered = true
        for waiter in entryWaiters { waiter.resume() }; entryWaiters.removeAll()
        if !released { await withCheckedContinuation { suspended = $0 } }
    }
    func waitForEntry() async {
        if !entered { await withCheckedContinuation { entryWaiters.append($0) } }
    }
    func release() { released = true; suspended?.resume(); suspended = nil }
}

private actor RuntimeJournalFixture: SessionCheckpointJournal, SessionPayloadStore {
    enum Mode { case normal, commitWithoutAcknowledgement, uncertainBeforePublication }
    private var mode: Mode = .normal
    private var batches: [SessionBatch] = []
    private var bytes: [SessionPayloadReference: Data] = [:]
    private var pauseAppend = false
    private var appendGate = PreparationGate()
    private var pauseCache = false
    private var cacheGate = PreparationGate()
    private(set) var cacheEntered = false
    private(set) var cachedSequences: [Int64] = []
    private(set) var appendCount = 0
    private(set) var stageCount = 0

    func setMode(_ value: Mode) { mode = value }
    func pauseNextCache() { pauseCache = true; cacheEntered = false; cacheGate = PreparationGate() }
    func releaseCache() async { await cacheGate.release() }
    func recoverySummary(through head: SessionJournalHead, extensionSchemas: [String: Set<Int>]) -> SessionRecoverySummary? { nil }
    func checkpoint(through head: SessionJournalHead, extensionSchemas: [String: Set<Int>]) -> SessionJournalSnapshot? { nil }
    func cache(_ snapshot: SessionJournalSnapshot, extensionSchemas: [String: Set<Int>]) async {
        if pauseCache { pauseCache = false; cacheEntered = true; await cacheGate.suspend() }
        cachedSequences.append(snapshot.state.sequence)
    }
    func pauseNextAppend() { pauseAppend = true; appendGate = PreparationGate() }
    func waitForAppend() async { await appendGate.waitForEntry() }
    func releaseAppend() async { await appendGate.release() }
    func append(_ batch: SessionBatch) async -> SessionAppendOutcome {
        appendCount += 1
        if pauseAppend { pauseAppend = false; await appendGate.suspend() }
        let selectedMode = mode; mode = .normal
        if selectedMode != .uncertainBeforePublication { batches.append(batch) }
        return selectedMode == .normal ? .committed(batch.cursor) : .indeterminate(.init(.storage, "Synthetic uncertain commit."))
    }
    func reconcile(_ batch: SessionBatch) -> SessionAppendOutcome {
        if !batches.contains(where: { $0.id == batch.id }) { batches.append(batch) }
        return .committed(batch.cursor)
    }
    func batch(id: UUID, sessionID: ConversationID) -> SessionBatch? { batches.first { $0.id == id && $0.sessionID == sessionID } }
    func head(sessionID: ConversationID) -> SessionJournalHead {
        guard let batch = batches.filter({ $0.sessionID == sessionID }).max(by: { $0.cursor.sequence < $1.cursor.sequence }) else {
            return .init(cursor: .init(sessionID: sessionID, sequence: 0), batchID: nil)
        }
        return .init(cursor: batch.cursor, batchID: batch.id)
    }
    func read(sessionID: ConversationID, after sequence: Int64, limit: Int) -> [SessionBatch] {
        Array(batches.filter { $0.sessionID == sessionID && $0.cursor.sequence > sequence }.prefix(limit))
    }
    func sessions(after: ConversationID?, limit: Int) -> [ConversationID] { Array(Set(batches.map(\.sessionID)).prefix(limit)) }
    func flush() {}
    func close() {}
    func stage(_ data: Data, sessionID: ConversationID, batchID: UUID, retentionGroup: UUID,
               kind: SessionPayloadKind) -> SessionPayloadReference {
        stageCount += 1
        let reference = SessionPayloadReference(id: UUID(), sessionID: sessionID, batchID: batchID,
            retentionGroup: retentionGroup, kind: kind, byteCount: data.count, digest: String(repeating: "a", count: 64))
        bytes[reference] = data; return reference
    }
    func read(_ reference: SessionPayloadReference) throws -> Data {
        guard let data = bytes[reference], batches.contains(where: { $0.events.contains { $0.fact.payloadReferences.contains(reference) } }) else {
            throw MiraError(.notFound, "Fixture payload is unavailable.")
        }
        return data
    }
    func purge(sessionID: ConversationID, retentionGroups: Set<UUID>) {
        bytes = bytes.filter { $0.key.sessionID != sessionID || !retentionGroups.contains($0.key.retentionGroup) }
    }
}
