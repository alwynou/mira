import Foundation

public enum SessionCommitResult: Sendable, Equatable {
    case committed(SessionCursor)
    case notCommitted(MiraError)
    case indeterminate(batchID: UUID, error: MiraError)
}

/// A wake-up hint can be coalesced. Consumers read durable batches after their own cursor.
public struct SessionObservation: Sendable, Equatable {
    public let cursor: SessionCursor
    public let activeExecutionID: ExecutionID?
    public let requiresReconciliation: Bool
    public let isClosing: Bool
    public let cancellationRequested: Set<ExecutionID>
}

struct SessionCommandContext: Sendable {
    let batchID: UUID
    let state: SessionState
    let payloads: any SessionPayloadStore

    func stage<T: Encodable & Sendable>(_ value: T, kind: SessionPayloadKind,
                                        retentionGroup: UUID) async throws -> SessionPayloadReference {
        try await stageBytes(SessionCodec.encode(value), kind: kind, retentionGroup: retentionGroup)
    }

    func stageBytes(_ bytes: Data, kind: SessionPayloadKind,
                    retentionGroup: UUID) async throws -> SessionPayloadReference {
        try await payloads.stage(bytes, sessionID: state.id, batchID: batchID,
                                 retentionGroup: retentionGroup, kind: kind)
    }
}

/// Owns one logical command lane across suspension points. Only kernel commands can append facts.
public actor SessionRuntime {
    public nonisolated let id: ConversationID
    private let journal: any SessionJournal
    private let payloads: any SessionPayloadStore
    private let environment: RuntimeEnvironment
    private let extensionSchemas: [String: Set<Int>]
    private var state: SessionState
    private var pending: (batch: SessionBatch, state: SessionState)?
    private var laneOccupied = false
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, any Error>)] = []
    private var cancellationRequests: Set<ExecutionID> = []
    private var observers: [UUID: AsyncStream<SessionObservation>.Continuation] = [:]
    private var outputObservers: [UUID: AsyncStream<SessionOutputObservation>.Continuation] = [:]
    private var outputWriter: OutputWriter?
    private var outputHandoff: (executionID: ExecutionID, authorizationEpoch: UInt64)?
    private var outputRevision: UInt64 = 0
    private var closed = false
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []

    private struct OutputWriter {
        let ownerID: UUID
        let executionID: ExecutionID
        let attemptID: UUID
        let stepID: UUID
        let authorizationEpoch: UInt64
        let lease: AgentLibraryAccessLease
        var value: SessionVisibleOutput?
    }

    private init(state: SessionState, journal: any SessionJournal, payloads: any SessionPayloadStore,
                 environment: RuntimeEnvironment, extensionSchemas: [String: Set<Int>]) {
        id = state.id; self.state = state; self.journal = journal; self.payloads = payloads
        self.environment = environment; self.extensionSchemas = extensionSchemas
    }

    public static func open(id: ConversationID, journal: any SessionJournal,
                            payloads: any SessionPayloadStore, environment: RuntimeEnvironment = .init(),
                            extensionSchemas: [String: Set<Int>] = [:]) async throws -> SessionRuntime {
        let snapshot = try await JournalSessionReader(journal: journal, payloads: payloads,
            extensionSchemas: extensionSchemas).snapshot(sessionID: id)
        return SessionRuntime(state: snapshot.state, journal: journal, payloads: payloads,
                              environment: environment, extensionSchemas: extensionSchemas)
    }

    public func snapshot() -> SessionState { state }

    /// Resolves original user evidence through the same journal and extension schemas as this session.
    /// This read does not grant a business permission or reserve a future commit.
    public func userEvidence(executionID: ExecutionID) async throws -> SessionUserEvidence {
        try await JournalSessionReader(journal: journal, payloads: payloads, extensionSchemas: extensionSchemas)
            .userEvidence(sessionID: id, executionID: executionID)
    }
    public func currentObservation() -> SessionObservation { observation }

    public func observations() -> AsyncStream<SessionObservation> {
        let (stream, continuation) = AsyncStream<SessionObservation>.makeStream(bufferingPolicy: .bufferingNewest(1))
        guard !closed else { continuation.finish(); return stream }
        let observerID = UUID()
        observers[observerID] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(observerID) }
        }
        continuation.yield(observation)
        return stream
    }

    /// Delivers the latest live output snapshot and coalesced updates. Cancelling a
    /// subscriber only removes that subscriber; it never cancels the execution.
    public func outputObservations() throws -> AsyncStream<SessionOutputObservation> {
        if !closed, outputObservers.count >= 256 {
            throw MiraError(.busy, "The session output observer limit was reached.")
        }
        let (stream, continuation) = AsyncStream<SessionOutputObservation>.makeStream(
            bufferingPolicy: .bufferingNewest(1))
        if closed {
            continuation.yield(outputObservation)
            continuation.finish()
            return stream
        }
        if reconcileOutput() { publishOutputObservation() }
        let observerID = UUID()
        outputObservers[observerID] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeOutputObserver(observerID) }
        }
        continuation.yield(outputObservation)
        return stream
    }

    /// Claims live output for one unresolved model attempt. The lease is retained only
    /// as a revocation signal; the producer remains owned by its execution resource.
    func beginOutput(ownerID: UUID, executionID: ExecutionID, attemptID: UUID,
                     authorizationEpoch: UInt64, lease: AgentLibraryAccessLease) throws {
        if reconcileOutput() { publishOutputObservation() }
        guard !closed, pending == nil else {
            throw MiraError(.interrupted, "Live output is unavailable while the session is closing or reconciling.")
        }
        guard outputWriter == nil else {
            throw MiraError(.conflict, "The session already has a live output writer.")
        }
        guard outputAuthorizationIsValid(executionID: executionID, attemptID: attemptID,
                                         authorizationEpoch: authorizationEpoch, lease: lease) else {
            throw MiraError(.unauthorized, "The live output attempt is no longer authorized.")
        }
        outputWriter = .init(ownerID: ownerID, executionID: executionID, attemptID: attemptID,
                             stepID: state.attempts[attemptID]!.attempt.stepID,
                             authorizationEpoch: authorizationEpoch, lease: lease,
                             value: nil)
        if outputHandoff != nil {
            outputHandoff = nil
            advanceOutputRevision()
            publishOutputObservation()
        }
    }

    /// Publishes a cumulative visible snapshot. A stale or revoked writer is rejected
    /// quietly and its previously visible value is cleared before the next wake-up.
    @discardableResult
    func publishOutput(ownerID: UUID, answer: String, thinking: String,
                       phase: SessionOutputPhase = .waiting, toolCall: CanonicalToolCall? = nil,
                       blocks: [AgentModelBlock] = []) -> Bool {
        guard var writer = outputWriter, writer.ownerID == ownerID else { return false }
        guard outputAuthorizationIsValid(executionID: writer.executionID, attemptID: writer.attemptID,
                                         authorizationEpoch: writer.authorizationEpoch, lease: writer.lease) else {
            let changed = writer.value != nil
            outputWriter = nil
            if changed { advanceOutputRevision() }
            if changed { publishOutputObservation() }
            return false
        }
        guard blocks.count <= 64, Set(blocks.map(\.id)).count == blocks.count,
              blocks.allSatisfy({ block in
                  switch block.content {
                  case .text(let text), .thinking(let text): return text.utf8.count <= 2 * 1_024 * 1_024
                  case .toolCall(let call): return call.arguments.utf8.count <= 2 * 1_024 * 1_024
                  case .toolResult: return false
                  }
              }),
              answer.utf8.count <= 2 * 1_024 * 1_024,
              thinking.utf8.count <= SessionFormatLimits.maximumPayloadBytes,
              toolCall.map({ $0.arguments.utf8.count <= 2 * 1_024 * 1_024 && $0.name.utf8.count <= 256 }) ?? true
        else { return false }
        let value = SessionVisibleOutput(executionID: writer.executionID, attemptID: writer.attemptID,
                                         stepID: writer.stepID, answer: answer, thinking: thinking,
                                         phase: phase, toolCall: toolCall, blocks: blocks)
        guard writer.value != value else { return true }
        guard outputRevision < UInt64.max else { return false }
        advanceOutputRevision()
        writer.value = value
        outputWriter = writer
        publishOutputObservation()
        return true
    }

    /// Releases only the matching writer. A late owner cannot clear a newer writer.
    func releaseOutput(ownerID: UUID) {
        guard let writer = outputWriter, writer.ownerID == ownerID else { return }
        outputWriter = nil
        if writer.value != nil {
            advanceOutputRevision()
            publishOutputObservation()
        }
    }

    public func read(after sequence: Int64, limit: Int = SessionFormatLimits.maximumReadBatches) async throws -> [SessionBatch] {
        try await journal.read(sessionID: id, after: sequence, limit: limit)
    }

    /// Records intent immediately, including while a durable append is in flight.
    func requestCancellation(executionID: ExecutionID) {
        guard state.activeExecutionID == executionID || pending?.state.activeExecutionID == executionID else { return }
        cancellationRequests.insert(executionID)
        publish()
    }

    func isCancellationRequested(executionID: ExecutionID) -> Bool {
        cancellationRequests.contains(executionID)
    }

    /// A stable ID belongs to one kernel command. Repeating it returns its first committed result.
    func commit(id commandID: UUID,
                prepare: @Sendable (SessionCommandContext) async throws -> [SessionFact]) async -> SessionCommitResult {
        do { try await acquireLane() } catch { return .notCommitted(.safe(error)) }
        defer { releaseLane() }
        guard !closed else { return .notCommitted(.init(.interrupted, "The session runtime is closed.")) }
        if let pending {
            return .indeterminate(batchID: pending.batch.id,
                                  error: .init(.storage, "A previous session commit requires reconciliation."))
        }
        do {
            if let existing = try await journal.batch(id: commandID, sessionID: id) {
                return .committed(existing.cursor)
            }
            try Task.checkCancellation()
            let facts = try await prepare(.init(batchID: commandID, state: state, payloads: payloads))
            try Task.checkCancellation()
            guard !closed else { throw MiraError(.interrupted, "The session runtime is closed.") }
            guard state.sequence <= Int64.max - Int64(facts.count) else {
                throw MiraError(.storage, "The session sequence has reached its limit.")
            }
            let batch = SessionBatch(id: commandID, sessionID: id, expectedSequence: state.sequence,
                                     events: facts.enumerated().map { offset, fact in
                .init(id: environment.uuid(), sequence: state.sequence + Int64(offset) + 1,
                      occurredAt: environment.now(), fact: fact)
            })
            var next = state
            try next.apply(batch, extensionSchemas: extensionSchemas)
            try validateCancellation(batch, next: next)
            // Once append begins, its outcome must be consumed even when the caller cancels.
            let outcome = await journal.append(batch)
            return await accept(outcome, batch: batch, next: next)
        } catch { return .notCommitted(.safe(error)) }
    }

    /// No new command or external effect may pass the fence until this original batch is resolved.
    func reconcile() async -> SessionCommitResult {
        do { try await acquireLane() } catch { return .notCommitted(.safe(error)) }
        defer { releaseLane() }
        guard let pending else { return .committed(.init(sessionID: id, sequence: state.sequence)) }
        let outcome = await journal.reconcile(pending.batch)
        return await accept(outcome, batch: pending.batch, next: pending.state)
    }

    /// Closing the session does not close the shared library. The composition owner drains that separately.
    public func close() async {
        let hadLiveOutput = outputWriter?.value != nil
        let wasClosed = closed
        closed = true
        if !wasClosed && !hadLiveOutput {
            advanceOutputRevision()
        }
        publish()
        let queued = waiters; waiters.removeAll()
        for waiter in queued { waiter.continuation.resume(throwing: MiraError(.interrupted, "The session runtime is closed.")) }
        if laneOccupied { await withCheckedContinuation { drainWaiters.append($0) } }
        for continuation in observers.values { continuation.finish() }
        observers.removeAll()
        for continuation in outputObservers.values { continuation.finish() }
        outputObservers.removeAll()
    }

    private func accept(_ outcome: SessionAppendOutcome, batch: SessionBatch, next: SessionState) async -> SessionCommitResult {
        switch outcome {
        case .committed(let cursor):
            guard cursor == batch.cursor else {
                pending = (batch, next); publish()
                return .indeterminate(batchID: batch.id, error: .init(.storage, "The journal returned an invalid commit cursor."))
            }
            state = next; pending = nil
            cancellationRequests = cancellationRequests.filter { state.executions[$0]?.completion == nil }
            publish()
            if let checkpoints = journal as? any SessionCheckpointJournal {
                // The commit lane owns and drains cache publication too. Its failure cannot
                // change the already acknowledged result or publish an uncertain state.
                await checkpoints.cache(.init(head: .init(cursor: cursor, batchID: batch.id), state: state),
                                        extensionSchemas: extensionSchemas)
            }
            return .committed(cursor)
        case .notCommitted(let error):
            pending = nil; publish()
            return .notCommitted(error)
        case .indeterminate(let error):
            pending = (batch, next); publish()
            return .indeterminate(batchID: batch.id, error: error)
        }
    }

    private func validateCancellation(_ batch: SessionBatch, next: SessionState) throws {
        for executionID in cancellationRequests {
            guard state.activeExecutionID == executionID, let result = next.executions[executionID] else { continue }
            if let completion = result.completion,
               completion.status != .cancelled && completion.status != .interrupted {
                throw MiraError(.cancelled, "A cancellation request prevents successful completion.")
            }
            for event in batch.events {
                switch event.fact {
                case .attemptStarted, .toolPrepared, .toolDispatched, .draftCheckpoint, .toolProposed,
                     .toolApprovalRequested:
                    throw MiraError(.cancelled, "A cancellation request prevents new execution work.")
                case .toolApprovalResolved(_, let approved) where approved:
                    throw MiraError(.cancelled, "A cancelled execution cannot approve a tool.")
                case .attemptResolved(let resolution) where resolution.status == .completed:
                    throw MiraError(.cancelled, "A cancelled model attempt cannot publish new output.")
                default: break
                }
            }
        }
    }

    private func acquireLane() async throws {
        try Task.checkCancellation()
        guard !closed else { throw MiraError(.interrupted, "The session runtime is closed.") }
        if !laneOccupied { laneOccupied = true; return }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append((waiterID, continuation))
            }
            if Task.isCancelled { releaseLane(); throw CancellationError() }
        } onCancel: {
            Task { await self.cancelWaiter(waiterID) }
        }
    }

    private func releaseLane() {
        if waiters.isEmpty {
            laneOccupied = false
            let drained = drainWaiters; drainWaiters.removeAll()
            for waiter in drained { waiter.resume() }
        }
        else { waiters.removeFirst().continuation.resume() }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private var observation: SessionObservation {
        .init(cursor: .init(sessionID: id, sequence: state.sequence), activeExecutionID: state.activeExecutionID,
              requiresReconciliation: pending != nil, isClosing: closed, cancellationRequested: cancellationRequests)
    }

    private func publish() {
        let outputChanged = reconcileOutput()
        for continuation in observers.values { continuation.yield(observation) }
        if outputChanged || outputWriter != nil || outputHandoff != nil || closed { publishOutputObservation() }
    }
    private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }
    private func removeOutputObserver(_ id: UUID) { outputObservers.removeValue(forKey: id) }

    private var outputObservation: SessionOutputObservation {
        .init(cursor: .init(sessionID: id, sequence: state.sequence),
              revision: outputRevision,
              value: outputWriter?.value, isClosing: closed, handoffExecutionID: outputHandoff?.executionID)
    }

    private func publishOutputObservation() {
        guard !outputObservers.isEmpty else { return }
        let value = outputObservation
        for continuation in outputObservers.values { continuation.yield(value) }
    }

    @discardableResult
    private func reconcileOutput() -> Bool {
        var handoffChanged = false
        if let handoff = outputHandoff,
           closed || pending != nil || state.authorizationEpoch != handoff.authorizationEpoch
            || state.excludedExecutionIDs.contains(handoff.executionID)
            || cancellationRequests.contains(handoff.executionID) {
            outputHandoff = nil
            advanceOutputRevision()
            handoffChanged = true
        }
        guard let writer = outputWriter,
              !outputAuthorizationIsValid(executionID: writer.executionID, attemptID: writer.attemptID,
                                          authorizationEpoch: writer.authorizationEpoch, lease: writer.lease) else {
            return handoffChanged
        }
        let changed = writer.value != nil
        if changed, !closed, pending == nil, !writer.lease.isRevoked,
           !cancellationRequests.contains(writer.executionID),
           state.authorizationEpoch == writer.authorizationEpoch,
           !state.excludedExecutionIDs.contains(writer.executionID),
           let resolution = state.attempts[writer.attemptID]?.resolution,
           resolution.status == .completed, resolution.output != nil {
            outputHandoff = (writer.executionID, writer.authorizationEpoch)
        }
        outputWriter = nil
        if changed { advanceOutputRevision() }
        return changed || handoffChanged
    }

    private func advanceOutputRevision() {
        if outputRevision < UInt64.max { outputRevision += 1 }
    }

    private func outputAuthorizationIsValid(executionID: ExecutionID, attemptID: UUID,
                                            authorizationEpoch: UInt64,
                                            lease: AgentLibraryAccessLease) -> Bool {
        guard !closed, pending == nil, !lease.isRevoked,
              !cancellationRequests.contains(executionID),
              state.authorizationEpoch == authorizationEpoch,
              state.activeExecutionID == executionID,
              let execution = state.executions[executionID],
              execution.admission.authorizationEpoch == authorizationEpoch,
              execution.phase == .waitingForModel,
              execution.attemptIDs.last == attemptID,
              let attempt = state.attempts[attemptID], attempt.resolution == nil else { return false }
        return true
    }
}
