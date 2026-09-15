import Foundation
import Testing
@testable import MiraCore
@testable import MiraData

@Suite("Durable model draft timer", .timeLimit(.minutes(1)))
struct AgentModelDraftTimerTests {
    @Test func pausedStreamDraftSurvivesCancellationAndReopen() async throws {
        let fixture = try await DraftTimerFixture.make()
        let task = Task { try await fixture.execute() }
        do {
            await fixture.probe.waitUntilDispatched()
            let draft = try await fixture.waitForDraft()
            #expect(draft[.answer] == Data("partial answer".utf8))
            #expect(draft[.thinking] == Data("partial thinking".utf8))
            let transcript = try SessionCodec.decode(JSONValue.self, from: #require(draft[.transcript]))
            #expect(transcript["continuation"]?["payload"] == .object(["opaque": .string("timer-proof")]))
            #expect(transcript["continuation"]?["isComplete"] == .bool(false))

            task.cancel()
            do { _ = try await task.value; Issue.record("A cancelled paused stream completed") }
            catch { #expect(error is CancellationError || (error as? MiraError)?.code == .cancelled) }
            await fixture.probe.waitUntilDrained()
            let before = await fixture.runtime.snapshot()
            #expect(before.executions[fixture.executionID]?.completion == nil)
            await fixture.runtime.close()
            try await fixture.journal.close()

            let reopenedLibrary = try FileSessionLibrary(directory: fixture.directory)
            do {
                let reopened = try await SessionRuntime.open(id: fixture.sessionID, journal: reopenedLibrary, payloads: reopenedLibrary)
                do {
                    let reopenedState = await reopened.snapshot()
                    let reopenedDraft = try await SessionDraftReader(journal: reopenedLibrary, payloads: reopenedLibrary)
                        .read(state: reopenedState, executionID: fixture.executionID)
                    #expect(reopenedDraft == draft)
                    await reopened.close()
                    try await reopenedLibrary.close()
                } catch {
                    await reopened.close(); try? await reopenedLibrary.close(); throw error
                }
            } catch {
                try? await reopenedLibrary.close(); throw error
            }
            await fixture.close()
        } catch {
            task.cancel(); _ = try? await task.value
            await fixture.close()
            throw error
        }
    }

    @Test func maintenanceClosesPausedModelProducerAndPreventsAnotherDispatch() async throws {
        let fixture = try await DraftTimerFixture.make()
        let task = Task { try await fixture.execute() }
        do {
            await fixture.probe.waitUntilDispatched()
            let access = fixture.libraryAccessFixture.access
            let initial = await access.snapshot()
            // Transport drain and revocable live visibility have separate owned lifetimes.
            #expect(initial.activeResources == 2)
            _ = try await access.begin(.init(id: UUID(), namespace: "test.purge", revision: 1,
                scope: .library, requestedAt: Date()), expected: initial.authorization)
            do { _ = try await task.value; Issue.record("A revoked paused stream completed successfully.") }
            catch { #expect(error is CancellationError || error is MiraError) }
            #expect(await fixture.probe.drained)
            #expect(await fixture.probe.count == 1)
            #expect((await access.snapshot()).activeResources == 0)
            // The enclosing execution remains explicitly owned after its stream closes.
            #expect((await access.snapshot()).activeLeases == 1)
            await #expect(throws: MiraError.self) { try await fixture.execute() }
            #expect(await fixture.probe.count == 1)
        } catch {
            task.cancel(); _ = await task.result; await fixture.close(); throw error
        }
        await fixture.close()
    }

    @Test(arguments: [DraftFaultMode.notCommitted, .indeterminate])
    func checkpointDurabilityFailureDoesNotWriteErrorOrRedispatch(_ mode: DraftFaultMode) async throws {
        let fixture = try await DraftTimerFixture.make(fault: mode)
        let task = Task { try await fixture.execute() }
        do {
            await fixture.probe.waitUntilDispatched()
            await fixture.fault!.waitUntilTriggered()
            let triggeredBatchID = await fixture.fault!.triggeredBatchID()
            do {
                _ = try await task.value
                Issue.record("A draft checkpoint durability failure completed")
            } catch let error as AgentDurabilityFailure {
                switch (mode, error) {
                case (.notCommitted, .rejected(let failure)): #expect(failure.code == .storage)
                case (.indeterminate, .uncertain(_, let failure)): #expect(failure.code == .storage)
                default: Issue.record("Unexpected durability failure classification: \(error)")
                }
            } catch { Issue.record("Unexpected checkpoint error: \(error)") }
            await fixture.probe.waitUntilDrained()
            #expect(await fixture.probe.count == 1)
            let state = await fixture.runtime.snapshot()
            #expect(state.attempts[fixture.attemptID]?.resolution == nil)
            let batches = try await fixture.journal.read(sessionID: fixture.sessionID, after: 0,
                                                         limit: SessionFormatLimits.maximumReadBatches)
            #expect(batches.filter { batch in batch.events.contains { if case .attemptStarted = $0.fact { return true }; return false } }.count == 1)
            #expect(batches.filter { batch in batch.events.contains { if case .draftCheckpoint = $0.fact { return true }; return false } }.count == (mode == .indeterminate ? 1 : 0))
            #expect(batches.allSatisfy { batch in batch.events.allSatisfy { event in
                if case .attemptResolved = event.fact { return false }; return true
            }})
            if mode == .indeterminate {
                let expectedBatchID = try #require(triggeredBatchID)
                #expect(batches.contains { $0.id == expectedBatchID })
                let reconciliation = await fixture.runtime.reconcile()
                guard case .committed = reconciliation else {
                    throw MiraError(.storage, "The indeterminate draft batch did not reconcile: \(reconciliation)")
                }
                let state = await fixture.runtime.snapshot()
                let drafts = try await SessionDraftReader(journal: fixture.journal, payloads: fixture.payloads)
                    .read(state: state, executionID: fixture.executionID)
                #expect(drafts[.answer] == Data("partial answer".utf8))
                #expect(drafts[.thinking] == Data("partial thinking".utf8))
                let reconciledBatches = try await fixture.journal.read(sessionID: fixture.sessionID, after: 0,
                                                                        limit: SessionFormatLimits.maximumReadBatches)
                #expect(reconciledBatches.filter { $0.id == expectedBatchID }.count == 1)
                #expect(await fixture.probe.count == 1)
            }
        } catch {
            task.cancel(); _ = try? await task.value
            await fixture.close()
            throw error
        }
        await fixture.close()
    }

    @Test func timerCancellationKeepsLeaseUntilClockAndTransportDrain() async throws {
        let clock = LifecycleClock()
        let fixture = try await DraftTimerFixture.make(environment: RuntimeEnvironment(sleep: { duration in
            try await clock.sleep(for: duration)
        }))
        let completion = CompletionProbe()
        let task = Task {
            do { let value = try await fixture.execute(); await completion.mark(); return value }
            catch { await completion.mark(); throw error }
        }
        do {
            await fixture.probe.waitUntilDispatched()
            await clock.waitUntilTimerEntered()
            task.cancel()
            await clock.waitUntilTimerCancellationObserved()
            await fixture.probe.waitUntilDrained()
            #expect(await completion.isDone == false)
            do {
                let lease = try await fixture.scheduler.acquire(executionID: fixture.executionID, priority: .foreground)
                await lease.release()
                Issue.record("The model lease was released before timer cleanup")
            } catch let error as MiraError { #expect(error.code == .conflict) }
            await clock.releaseTimer()
            do { _ = try await task.value; Issue.record("Cancelled lifecycle operation completed") }
            catch { #expect(error is CancellationError || (error as? MiraError)?.code == .cancelled) }
            await fixture.probe.waitUntilDrained()
            let lease = try await fixture.scheduler.acquire(executionID: fixture.executionID, priority: .foreground)
            await lease.release()
        } catch {
            await clock.releaseTimer()
            task.cancel(); _ = try? await task.value
            await fixture.close()
            throw error
        }
        await fixture.close()
    }

    @Test func unchangedPausedDraftDoesNotCreateTimerBatches() async throws {
        let fixture = try await DraftTimerFixture.make()
        let completion = CompletionProbe()
        let task = Task {
            do { let value = try await fixture.execute(); await completion.mark(); return Result<AgentModelStepResult, any Error>.success(value) }
            catch { await completion.mark(); return Result<AgentModelStepResult, any Error>.failure(error) }
        }
        do {
            await fixture.probe.waitUntilDispatched()
            _ = try await fixture.waitForDraft()
            let beforeHead = try await fixture.journal.head(sessionID: fixture.sessionID)
            let before = try await fixture.journal.read(sessionID: fixture.sessionID, after: 0, limit: SessionFormatLimits.maximumReadBatches)
            try await Task.sleep(for: .milliseconds(650))
            let afterHead = try await fixture.journal.head(sessionID: fixture.sessionID)
            let after = try await fixture.journal.read(sessionID: fixture.sessionID, after: 0, limit: SessionFormatLimits.maximumReadBatches)
            #expect(afterHead == beforeHead)
            #expect(after == before)
            #expect(await completion.isDone == false)
            task.cancel(); _ = await task.value
            await fixture.probe.waitUntilDrained()
        } catch {
            task.cancel(); _ = await task.value
            await fixture.close()
            throw error
        }
        await fixture.close()
    }

    @Test func timerFailurePersistsSanitizedInterruptedAttemptAndReleasesLease() async throws {
        let clock = TimerFailureClock()
        let fixture = try await DraftTimerFixture.make(environment: RuntimeEnvironment(sleep: { duration in
            try await clock.sleep(for: duration)
        }))
        let task = Task { try await fixture.execute() }
        do {
            await fixture.probe.waitUntilDispatched()
            await clock.waitUntilTimerEntered()
            await clock.failTimer()
            do {
                _ = try await task.value
                Issue.record("A timer failure completed the model operation")
            } catch let error as MiraError {
                #expect(error.code == .interrupted)
                #expect(error.message == "The model draft checkpoint timer failed.")
                #expect(!error.message.contains("private-timer-marker"))
            }
            await fixture.probe.waitUntilDrained()
            #expect(await fixture.probe.count == 1)
            let state = await fixture.runtime.snapshot()
            let resolution = try #require(state.attempts[fixture.attemptID]?.resolution)
            #expect(resolution.status == .failed)
            let errorReference = try #require(resolution.error)
            let record = try SessionCodec.decode(AgentModelAttemptFailureRecord.self,
                from: await fixture.payloads.read(errorReference))
            #expect(record.failure.error.code == .interrupted)
            #expect(record.failure.error.message == "The model draft checkpoint timer failed.")
            #expect(!record.failure.error.message.contains("private-timer-marker"))
            #expect(record.failure.retryAdvice == nil)
            let lease = try await fixture.scheduler.acquire(executionID: fixture.executionID, priority: .foreground)
            await lease.release()
        } catch {
            await clock.failTimer()
            task.cancel(); _ = try? await task.value
            await fixture.close()
            throw error
        }
        await fixture.close()
    }
}

enum DraftFaultMode: Sendable { case notCommitted, indeterminate }

private final class DraftTimerFixture: Sendable {
    let directory: URL
    let journal: any SessionJournal
    let payloads: any SessionPayloadReader
    let fault: DraftFaultJournal?
    let runtime: SessionRuntime
    let scheduler: RuntimeScheduler
    let executor: AgentModelExecutor
    let adapter: DraftTimerAdapter
    let probe: DraftTimerProbe
    let sessionID: ConversationID
    let executionID: ExecutionID
    let attemptID: UUID
    let request: AgentContextRequest
    let build: AgentContextBuild
    let route: AgentModelRoute
    let tools: [String: SessionEffectKind]
    let authority: DraftTimerAuthority
    let libraryAccessFixture: LibraryAccessFixture

    static func make(fault mode: DraftFaultMode? = nil, environment: RuntimeEnvironment = .init()) async throws -> Self {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mira-model-draft-timer-\(UUID().uuidString)")
        let library = try FileSessionLibrary(directory: directory)
        var runtime: SessionRuntime?
        var accessFixture: LibraryAccessFixture?
        do {
            let sessionID = ConversationID(), executionID = ExecutionID(), attemptID = UUID()
            let journalProxy = mode.map { DraftFaultJournal(base: library, mode: $0) }
            let journal: any SessionJournal = journalProxy ?? library
            let payloads: any SessionPayloadStore = journalProxy ?? library
            let opened = try await SessionRuntime.open(id: sessionID, journal: journal, payloads: payloads)
            runtime = opened
            let route = AgentModelRoute(id: RouteID(), revision: 1, connectionID: ConnectionID(), connectionRevision: 1,
                modelDescriptorID: ModelDescriptorID(), modelRevision: 1, modelAuthorizationRevision: 1, adapter: .init(id: "synthetic.timer", revision: 1),
                invocationID: "test-invocation", invocationRevision: 1, endpointID: "test-endpoint", metadataEvidence: [], modelID: "fixture", credential: nil, contextWindow: 4_096, maximumOutputTokens: 512,
                capabilities: .init(streamsText: true, callsTools: false, producesThinking: true), configuration: .object([:]))
            try AgentDurabilityFailure.requireCommitted(await opened.commit(id: UUID()) { context in
                let title = try await context.stageBytes(Data("Timer fixture".utf8), kind: .title, retentionGroup: UUID())
                let user = try await context.stageBytes(Data("Question".utf8), kind: .userText, retentionGroup: UUID())
                let plan = try await context.stage(AgentExecutionPlan(runtimeID: UUID(), catalogGeneration: 1,
                    driverID: "mira.default", driverRevision: 1, instructions: "Answer the user.", limits: .init(),
                    priority: .foreground, route: route), kind: .executionPlan, retentionGroup: UUID())
                return [.opened(.init(workspaceID: nil, title: title)),
                        .admitted(.init(executionID: executionID, userMessageID: MessageID(), userBody: user,
                            plan: plan, hasModelRoute: true, authorizationEpoch: 0, timeZoneIdentifier: "UTC"))]
            })
            let scheduler = RuntimeScheduler(modelCapacity: 1, backgroundCapacity: 0)
            let openedAccessFixture = try await LibraryAccessFixture.make()
            accessFixture = openedAccessFixture
            let libraryLease = try await openedAccessFixture.acquire()
            let probe = DraftTimerProbe()
            let authority = DraftTimerAuthority()
            let adapter = DraftTimerAdapter(identity: route.adapter, probe: probe)
            let request = AgentContextRequest(sessionID: sessionID, executionID: executionID, workspaceID: nil,
                userText: "Question", authorizationEpoch: 0, destination: .model(route))
            let input = AgentModelInput(stepID: UUID(), executionID: executionID, instructions: "Answer the user.",
                messages: [.init(role: .user, blocks: [.init(id: "text", content: .text("Question"))])], tools: [])
            let build = AgentContextBuild(request: request, prepared: try adapter.prepare(input, route: route),
                inheritedSources: [], evidence: [], omissions: [])
            return .init(directory: directory, journal: journal, payloads: payloads, fault: journalProxy, runtime: opened,
                scheduler: scheduler, executor: AgentModelExecutor(runtime: opened, journal: journal, payloads: payloads,
                    libraryLease: libraryLease, scheduler: scheduler, environment: environment), adapter: adapter, probe: probe, sessionID: sessionID,
                executionID: executionID, attemptID: attemptID, request: request, build: build, route: route, tools: [:], authority: authority,
                libraryAccessFixture: openedAccessFixture)
        } catch {
            await accessFixture?.close()
            await runtime?.close(); try? await library.close(); try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private init(directory: URL, journal: any SessionJournal, payloads: any SessionPayloadReader, fault: DraftFaultJournal?, runtime: SessionRuntime,
                 scheduler: RuntimeScheduler, executor: AgentModelExecutor, adapter: DraftTimerAdapter,
                 probe: DraftTimerProbe, sessionID: ConversationID, executionID: ExecutionID, attemptID: UUID,
                 request: AgentContextRequest, build: AgentContextBuild, route: AgentModelRoute,
                 tools: [String: SessionEffectKind], authority: DraftTimerAuthority, libraryAccessFixture: LibraryAccessFixture) {
        self.directory = directory; self.journal = journal; self.payloads = payloads; self.fault = fault; self.runtime = runtime
        self.scheduler = scheduler; self.executor = executor; self.adapter = adapter; self.probe = probe
        self.sessionID = sessionID; self.executionID = executionID; self.attemptID = attemptID
        self.request = request; self.build = build; self.route = route; self.tools = tools; self.authority = authority; self.libraryAccessFixture = libraryAccessFixture
    }

    func execute() async throws -> AgentModelStepResult {
        try await executor.execute(stepIndex: 1, attemptID: attemptID, build: build, request: request, route: route,
            adapter: adapter, toolEffects: tools, authorizer: authority, priority: .foreground)
    }

    func waitForDraft() async throws -> [SessionDraftPart: Data] {
        for _ in 0..<200 {
            let state = await runtime.snapshot()
            if let execution = state.executions[executionID], !execution.drafts.isEmpty {
                return try await SessionDraftReader(journal: journal, payloads: payloads).read(state: state, executionID: executionID)
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw MiraError(.timeout, "The model draft timer did not checkpoint within the test bound.")
    }

    func close() async {
        await scheduler.shutdown()
        await runtime.close(); await libraryAccessFixture.close(); try? await journal.close(); try? FileManager.default.removeItem(at: directory)
    }
}

private actor DraftFaultJournal: SessionJournal, SessionPayloadStore {
    let base: FileSessionLibrary
    let mode: DraftFaultMode
    var armed = true
    var triggered = false
    var triggeredID: UUID?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(base: FileSessionLibrary, mode: DraftFaultMode) { self.base = base; self.mode = mode }
    func append(_ batch: SessionBatch) async -> SessionAppendOutcome {
        if armed && batch.events.contains(where: { if case .draftCheckpoint = $0.fact { return true }; return false }) {
            armed = false; triggered = true; triggeredID = batch.id; waiters.forEach { $0.resume() }; waiters.removeAll()
            if mode == .notCommitted { return .notCommitted(.init(.storage, "Synthetic draft checkpoint rejection.")) }
            guard case .committed = await base.append(batch) else {
                return .indeterminate(.init(.storage, "Synthetic draft checkpoint publication failed."))
            }
            return .indeterminate(.init(.storage, "Synthetic draft checkpoint uncertainty."))
        }
        return await base.append(batch)
    }
    func reconcile(_ batch: SessionBatch) async -> SessionAppendOutcome { await base.reconcile(batch) }
    func batch(id: UUID, sessionID: ConversationID) async throws -> SessionBatch? { try await base.batch(id: id, sessionID: sessionID) }
    func head(sessionID: ConversationID) async throws -> SessionJournalHead { try await base.head(sessionID: sessionID) }
    func read(sessionID: ConversationID, after sequence: Int64, limit: Int) async throws -> [SessionBatch] { try await base.read(sessionID: sessionID, after: sequence, limit: limit) }
    func sessions(after: ConversationID?, limit: Int) async throws -> [ConversationID] { try await base.sessions(after: after, limit: limit) }
    func flush() async throws { try await base.flush() }
    func close() async throws { try await base.close() }
    func stage(_ data: Data, sessionID: ConversationID, batchID: UUID, retentionGroup: UUID, kind: SessionPayloadKind) async throws -> SessionPayloadReference { try await base.stage(data, sessionID: sessionID, batchID: batchID, retentionGroup: retentionGroup, kind: kind) }
    func read(_ reference: SessionPayloadReference) async throws -> Data { try await base.read(reference) }
    func purge(sessionID: ConversationID, retentionGroups: Set<UUID>) async throws { try await base.purge(sessionID: sessionID, retentionGroups: retentionGroups) }
    func waitUntilTriggered() async { if !triggered { await withCheckedContinuation { waiters.append($0) } } }
    func triggeredBatchID() -> UUID? { triggeredID }
}

private actor DraftTimerProbe {
    private(set) var count = 0
    private(set) var drained = false
    private var dispatchWaiters: [CheckedContinuation<Void, Never>] = []
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    func dispatched() { count += 1; dispatchWaiters.forEach { $0.resume() }; dispatchWaiters.removeAll() }
    func drainedNow() { drained = true; drainWaiters.forEach { $0.resume() }; drainWaiters.removeAll() }
    func waitUntilDispatched() async { if count == 0 { await withCheckedContinuation { dispatchWaiters.append($0) } } }
    func waitUntilDrained() async { if !drained { await withCheckedContinuation { drainWaiters.append($0) } } }
}

private actor DraftStreamGate {
    private var open = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async {
        if open { return }
        await withCheckedContinuation { waiter = $0; if open { waiter?.resume(); waiter = nil } }
    }
    func release() { open = true; waiter?.resume(); waiter = nil }
}

private struct DraftTimerAdapter: AgentModelAdapter {
    let identity: AgentAdapterIdentity
    let probe: DraftTimerProbe
    func prepare(_ input: AgentModelInput, route: AgentModelRoute) throws -> AgentPreparedModelRequest {
        .init(adapter: identity, input: input, wirePayload: .object(["fixture": .bool(true)]), estimatedInputTokens: 32)
    }
    func stream(_ request: AgentPreparedModelRequest, route: AgentModelRoute) -> AgentModelOperation {
        let (events, continuation) = AsyncThrowingStream<AgentModelStreamEvent, any Error>.makeStream()
        let gate = DraftStreamGate()
        let worker = Task {
            await probe.dispatched()
            continuation.yield(.blockStarted(.init(id: "text", content: .text("partial answer"))))
            continuation.yield(.blockStarted(.init(id: "thinking", content: .thinking("partial thinking"))))
            continuation.yield(.continuation(.init(adapter: identity,
                format: "synthetic.timer", payload: .object(["opaque": .string("timer-proof")]), isComplete: false)))
            await gate.wait()
            if !Task.isCancelled {
                continuation.yield(.blockFinished(id: "text"))
                continuation.yield(.blockFinished(id: "thinking"))
                continuation.yield(.finished(.stop)); continuation.finish()
            }
            await probe.drainedNow()
        }
        continuation.onTermination = { _ in worker.cancel() }
        return AgentModelOperation(events: events, cancelAndDrain: { worker.cancel(); await gate.release(); _ = await worker.value; await probe.drainedNow() })
    }
    func replay(_ messages: [AgentModelMessage], from source: AgentModelRoute, to target: AgentModelRoute, boundary: AgentReplayBoundary) throws -> AgentReplayDecision { .include(messages) }
}

private struct DraftTimerAuthority: AgentSourceAuthorizer {
    func validate(_ sources: [AgentSourceReference], for request: AgentContextRequest) async throws {}
}

private actor CompletionProbe {
    private(set) var isDone = false
    func mark() { isDone = true }
}

private actor LifecycleClock: RuntimeClock {
    private var timerWaiter: CheckedContinuation<Void, any Error>?
    private var timerEntered = false
    private var timerCancelled = false
    private var timerEntryWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []
    func sleep(for duration: Duration) async throws {
        if duration == .milliseconds(250) {
            try await withTaskCancellationHandler(operation: {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    timerWaiter = continuation; timerEntered = true
                    timerEntryWaiters.forEach { $0.resume() }; timerEntryWaiters.removeAll()
                    if timerCancelled { continuation.resume(throwing: CancellationError()); timerWaiter = nil }
                }
            }, onCancel: { Task { await self.markTimerCancelled() } })
        } else {
            try await Task.sleep(for: duration)
        }
    }
    func waitUntilTimerEntered() async { if !timerEntered { await withCheckedContinuation { timerEntryWaiters.append($0) } } }
    func waitUntilTimerCancellationObserved() async { if !timerCancelled { await withCheckedContinuation { cancellationWaiters.append($0) } } }
    func releaseTimer() { timerWaiter?.resume(throwing: CancellationError()); timerWaiter = nil }
    private func markTimerCancelled() { timerCancelled = true; cancellationWaiters.forEach { $0.resume() }; cancellationWaiters.removeAll() }
}

private actor TimerFailureClock: RuntimeClock {
    private var timerWaiter: CheckedContinuation<Void, any Error>?
    private var timerEntered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []

    func sleep(for duration: Duration) async throws {
        guard duration == .milliseconds(250) else { try await Task.sleep(for: duration); return }
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                timerWaiter = continuation; timerEntered = true
                entryWaiters.forEach { $0.resume() }; entryWaiters.removeAll()
            }
        }, onCancel: { Task { await self.cancelTimer() } })
    }

    func waitUntilTimerEntered() async {
        if !timerEntered { await withCheckedContinuation { entryWaiters.append($0) } }
    }

    func failTimer() {
        timerWaiter?.resume(throwing: MiraError(.network, "private-timer-marker")); timerWaiter = nil
    }

    private func cancelTimer() {
        timerWaiter?.resume(throwing: CancellationError()); timerWaiter = nil
    }
}
