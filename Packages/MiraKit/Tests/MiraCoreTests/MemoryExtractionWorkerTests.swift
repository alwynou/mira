import Foundation
import Testing

@testable import MiraCore

@Suite("Memory extraction worker", .timeLimit(.minutes(1)))
struct MemoryExtractionWorkerTests {
    @Test func requestBuilderSubstitutesEvidenceAndAttemptIdentity() async throws {
        let fixture = try await WorkerFixture.make()
        try await fixture.withCleanup { fixture in
            let claim = try await fixture.store.makeClaim()
            let input = try MemoryExtractionRequestBuilder.input(for: claim)
            #expect(input.stepID == claim.attemptID)
            #expect(input.executionID == claim.executionID)
            #expect(input.tools.isEmpty)
            #expect(input.messages.count == 1)
            #expect(input.messages[0].role == .user)
            #expect(input.messages[0].text.contains(claim.source.text))
            #expect(input.messages[0].text.contains("createdAt"))
            #expect(input.messages[0].text.contains("timeZone"))
            #expect(!input.messages[0].text.contains(claim.source.reference.body.digest))
        }
    }

    @Test func extractionPreservesForegroundPrefixAndDisablesTools() async throws {
        let fixture = try await WorkerFixture.make()
        try await fixture.withCleanup { fixture in
            var claim = try await fixture.store.makeClaim()
            let original = AgentModelInput(stepID: UUID(), executionID: claim.job.origin.completedExecutionID,
                instructions: "Stable conversation instructions.", messages: [
                    .init(role: .context, blocks: [.init(id: "context", content: .text("Current data"))]),
                    .init(role: .user, blocks: [.init(id: "user", content: .text(claim.source.text))])
                ], tools: [])
            claim.prefix = MemoryExtractionPrefix(route: claim.route, input: original, sources: []).bounded(for: claim)
            let input = try MemoryExtractionRequestBuilder.input(for: claim)
            #expect(input.instructions == original.instructions)
            #expect(Array(input.messages.prefix(original.messages.count)) == original.messages)
            #expect(input.messages.last?.text.contains("Target input:") == true)
            #expect(input.prefixMessageCount == original.messages.count)
            #expect(input.allowsToolCalls == false)
            #expect(input.outputTokenLimit == min(2_048, claim.route.maximumOutputTokens))
        }
    }

    @Test func untrackedOrOversizedHistoryKeepsOnlyStableInstructions() async throws {
        let fixture = try await WorkerFixture.make()
        try await fixture.withCleanup { fixture in
            let claim = try await fixture.store.makeClaim()
            for (text, sources) in [
                ("Untracked history", [AgentSourceReference.sessionExecution(sessionID: claim.source.reference.sessionID, executionID: .init())]),
                (String(repeating: "x", count: 17_000), [])
            ] {
                let original = AgentModelInput(stepID: UUID(), executionID: claim.job.origin.completedExecutionID,
                    instructions: "Stable prefix", messages: [.init(role: .user, blocks: [.init(id: "user", content: .text(text))])], tools: [])
                let bounded = MemoryExtractionPrefix(route: claim.route, input: original, sources: sources).bounded(for: claim)
                #expect(bounded.input.messages.isEmpty)
                #expect(bounded.input.instructions == original.instructions)
                #expect(bounded.sources.isEmpty)
            }
        }
    }

    @Test func workerPersistsSharedThinkingAndUsageAccumulator() async throws {
        let probe = WorkerProbe()
        let continuation = AgentModelContinuation(
            adapter: .init(id: "memory.fixture", revision: 1), format: "fixture",
            payload: .array([.string("opaque")]), isComplete: true)
        let fixture = try await WorkerFixture.make(
            adapter: .init(
                probe: probe,
                events: [
                    .blockStarted(.init(id: "thinking", content: .thinking("classify"))), .continuation(continuation), .blockFinished(id: "thinking"),
                    .blockStarted(.init(id: "text", content: .text("{\"version\":3,\"items\":[]}"))), .blockFinished(id: "text"),
                    .usage(.init(inputTokens: 10, outputTokens: 4)), .finished(.stop),
                ]))
        try await fixture.withCleanup { fixture in
            await fixture.worker.wake()
            try await fixture.store.wait { $0.completed == 1 }
            #expect(await fixture.store.failed == 0)
            #expect(await fixture.store.prepared == 1)
            #expect(await fixture.store.dispatched == 1)
            #expect(probe.prepareCount == 1)
            #expect(probe.streamCount == 1)
            #expect(probe.lastInput?.instructions == "You are a helpful assistant.")
            #expect(probe.lastInput?.prefixMessageCount == 1)
            #expect(probe.lastInput?.allowsToolCalls == false)
            #expect(await fixture.store.output?.thinkingText == "classify")
            #expect(await fixture.store.output?.continuation == continuation)
            #expect(await fixture.store.output?.usage == .init(inputTokens: 10, outputTokens: 4))
        }
    }

    @Test func oversizedPrefixRefitsBeforeAnyNetworkDispatch() async throws {
        let probe = WorkerProbe()
        let fixture = try await WorkerFixture.make(adapter: .init(probe: probe, requiresCompactInput: true))
        try await fixture.withCleanup { fixture in
            await fixture.worker.wake()
            try await fixture.store.wait { $0.completed == 1 }
            #expect(probe.prepareCount == 2)
            #expect(probe.streamCount == 1)
            #expect(probe.lastInput?.prefixMessageCount == nil)
            #expect(probe.lastInput?.instructions == "You are a helpful assistant.")
            #expect(probe.lastInput?.allowsToolCalls == false)
            #expect(await fixture.store.prepared == 1)
        }
    }

    @Test func malformedUsageFailsAndBackgroundCapacityDoesNotDispatch() async throws {
        let malformedProbe = WorkerProbe()
        let malformed = try await WorkerFixture.make(
            adapter: .init(
                probe: malformedProbe, events: [.usage(.init(inputTokens: -1, outputTokens: 2)), .finished(.stop)]))
        try await malformed.withCleanup { malformed in
            await malformed.worker.wake()
            try await malformed.store.wait { $0.failed == 1 }
            #expect(await malformed.store.completed == 0)
            #expect(await malformed.store.lastError?.code == .malformedStream)
        }

        let capacityProbe = WorkerProbe()
        let capacity = try await WorkerFixture.make(adapter: .init(probe: capacityProbe), backgroundCapacity: 0)
        try await capacity.withCleanup { capacity in
            await capacity.worker.wake()
            try await capacity.store.wait { $0.failed == 1 }
            #expect(await capacity.store.prepared == 1)
            #expect(await capacity.store.dispatched == 0)
            #expect(capacityProbe.streamCount == 0)
            #expect(await capacity.store.lastError?.code == .unsupported)
        }
    }

    @Test func revokedSourcePausesBeforeClaimOrPrepare() async throws {
        let probe = WorkerProbe()
        let fixture = try await WorkerFixture.make(adapter: .init(probe: probe), sourceAvailable: false)
        try await fixture.withCleanup { fixture in
            await fixture.worker.wake()
            try await fixture.store.wait { $0.paused == 1 }
            #expect(await fixture.store.claimed == 0)
            #expect(probe.prepareCount == 0)
            #expect(probe.streamCount == 0)
            #expect(await fixture.store.lastError?.code == .unauthorized)
        }
    }

    @Test func preparedSemanticInputSubstitutionIsRejectedBeforeStorePreparation() async throws {
        let probe = WorkerProbe()
        let fixture = try await WorkerFixture.make(adapter: .init(probe: probe, mutateInput: true))
        try await fixture.withCleanup { fixture in
            await fixture.worker.wake()
            try await fixture.store.wait { $0.failed == 1 }
            #expect(await fixture.store.prepared == 0)
            #expect(probe.streamCount == 0)
            #expect(await fixture.store.lastError?.code == .configuration)
        }
    }

    @Test func closeWaitsForNonCooperativePrepareAndStreamCleanup() async throws {
        let prepareGate = WorkerGate()
        let prepareProbe = WorkerProbe()
        let fixture = try await WorkerFixture.make(adapter: .init(probe: prepareProbe, prepareGate: prepareGate))
        do {
            await fixture.worker.wake()
            await prepareGate.waitForEntry()
            let closeProbe = CloseProbe()
            let closeTask = Task {
                await fixture.worker.close()
                await closeProbe.returned()
            }
            try await Task.sleep(for: .milliseconds(20))
            #expect(prepareProbe.streamCount == 0)
            #expect(await closeProbe.didReturn == false)
            prepareGate.release()
            await closeTask.value
            #expect(prepareProbe.prepareCount == 1)
            await fixture.close()
        } catch {
            prepareGate.release()
            await fixture.close()
            throw error
        }

        let streamGate = WorkerGate()
        let streamProbe = WorkerProbe()
        let streamFixture = try await WorkerFixture.make(adapter: .init(probe: streamProbe, streamGate: streamGate))
        do {
            await streamFixture.worker.wake()
            try await streamProbe.waitForStream()
            let streamCloseProbe = CloseProbe()
            let streamClose = Task {
                await streamFixture.worker.close()
                await streamCloseProbe.returned()
            }
            try await Task.sleep(for: .milliseconds(20))
            #expect(streamProbe.closeCount == 0)
            #expect(await streamCloseProbe.didReturn == false)
            streamGate.release()
            await streamClose.value
            #expect(streamProbe.closeCount == 1)
            await streamFixture.close()
        } catch {
            streamGate.release()
            await streamFixture.close()
            throw error
        }
    }
}

private struct WorkerFixture: Sendable {
    let worker: MemoryExtractionWorker
    let store: WorkerStore
    let runtime: SessionRuntime
    let catalog: AgentRuntimeCatalog
    let access: AgentLibraryAccess
    let scope: RuntimeScope

    static func make(adapter: WorkerAdapter = .init(), backgroundCapacity: Int = 1, sourceAvailable: Bool = true)
        async throws -> WorkerFixture
    {
        let journal = WorkerJournal()
        let sessionID = ConversationID()
        let runtime = try await SessionRuntime.open(id: sessionID, journal: journal, payloads: journal)
        let routeInfo = WorkerRoute.make()
        let result = await runtime.commit(id: UUID()) { context in
            let title = try await context.stageBytes(Data("Memory worker".utf8), kind: .title, retentionGroup: UUID())
            let user = try await context.stageBytes(
                Data("I prefer compact interfaces".utf8), kind: .userText, retentionGroup: UUID())
            let plan = try await context.stage(
                AgentExecutionPlan(
                    runtimeID: UUID(), catalogGeneration: 1, driverID: "fixture", driverRevision: 1,
                    instructions: "You are a helpful assistant.", limits: .init(), priority: .foreground, route: routeInfo.route), kind: .executionPlan,
                retentionGroup: UUID())
            return [
                .opened(.init(workspaceID: nil, title: title)),
                .admitted(
                    .init(
                        executionID: ExecutionID(), userMessageID: MessageID(), userBody: user, plan: plan,
                        hasModelRoute: true, authorizationEpoch: 0, timeZoneIdentifier: "UTC")),
            ]
        }
        guard case .committed = result else { throw MiraError(.storage, "Worker session admission failed.") }
        let executionID = await runtime.snapshot().executionOrder[0]
        let settled = await runtime.commit(id: UUID()) { context in
            let stepID = UUID(), attemptID = UUID()
            let input = AgentModelInput(stepID: stepID, executionID: executionID,
                instructions: "You are a helpful assistant.",
                messages: [.init(role: .user, blocks: [.init(id: "user", content: .text("I prefer compact interfaces"))])], tools: [])
            let prepared = AgentPreparedModelRequest(adapter: routeInfo.route.adapter, input: input,
                wirePayload: .object(["fixture": .bool(true)]), estimatedInputTokens: 1)
            let build = AgentContextBuild(request: .init(sessionID: sessionID, executionID: executionID,
                workspaceID: nil, userText: "I prefer compact interfaces", authorizationEpoch: 0,
                destination: .model(routeInfo.route)), prepared: prepared, inheritedSources: [], evidence: [], omissions: [])
            let request = try await context.stage(try AgentRequestRecord(build), kind: .request, retentionGroup: UUID())
            let output = try await context.stage(AgentModelOutput(blocks: [.init(id: "answer", content: .text("Understood."))], continuation: nil, usage: .init(), finishReason: .stop),
                kind: .modelOutput, retentionGroup: UUID())
            let answer = try await context.stageBytes(Data("Understood.".utf8), kind: .visibleAnswer, retentionGroup: UUID())
            return [
                .phaseChanged(executionID: executionID, phase: .preparing),
                .attemptStarted(.init(id: attemptID, executionID: executionID, stepID: stepID, stepIndex: 1, attemptIndex: 1, request: request)),
                .attemptResolved(.init(attemptID: attemptID, status: .completed, output: output)),
                .phaseChanged(executionID: executionID, phase: .settling),
                .finished(.init(executionID: executionID, status: .completed, assistantMessageID: .init(), answer: answer)),
            ]
        }
        guard case .committed = settled else { throw MiraError(.storage, "Worker session settlement failed.") }
        let reader = JournalSessionReader(journal: journal, payloads: journal)
        let source = try await reader.userEvidence(sessionID: sessionID, executionID: executionID)
        if !sourceAvailable {
            try await journal.purge(sessionID: sessionID, retentionGroups: [source.reference.body.retentionGroup])
        }
        let selection = AgentModelRouteResolution(route: routeInfo.route, binding: nil)
        let settings = WorkerSettings(selection: .init(candidate: routeInfo.candidate, binding: nil))
        let scope = RuntimeScope(kind: .application)
        let registry = RuntimeRegistry<AgentCapability>()
        try await registry.register(id: "model", value: .model(adapter), scope: scope)
        try await registry.register(
            id: "configuration", value: .modelConfiguration(WorkerConfigurationProvider(identity: adapter.identity)),
            scope: scope)
        let snapshot = try await registry.freeze()
        let catalog: AgentRuntimeCatalog
        do { catalog = try AgentRuntimeCatalog(snapshot: snapshot) } catch {
            await snapshot.release()
            await scope.dispose()
            await runtime.close()
            throw error
        }
        let access = try await AgentLibraryAccess.open(store: WorkerMaintenanceStore())
        let completedHead = try await journal.head(sessionID: sessionID)
        let store = WorkerStore(source: source, head: completedHead, selection: selection)
        let worker = MemoryExtractionWorker(
            store: store, reader: reader, settings: settings, catalog: catalog,
            scheduler: RuntimeScheduler(modelCapacity: 1, backgroundCapacity: backgroundCapacity), access: access,
            scope: scope)
        return .init(worker: worker, store: store, runtime: runtime, catalog: catalog, access: access, scope: scope)
    }

    func close() async {
        await worker.close()
        await access.close()
        await catalog.release()
        await runtime.close()
        await scope.dispose()
    }

    func withCleanup(_ body: (WorkerFixture) async throws -> Void) async throws {
        do {
            try await body(self)
            await close()
        } catch {
            await close()
            throw error
        }
    }
}

private actor WorkerStore: MemoryExtractionStore {
    func flushDirtyMemoryExtraction(at: Date, authorization: AgentLibraryAuthorization) async throws {}
    struct State: Sendable {
        var claimed = 0
        var prepared = 0
        var dispatched = 0
        var completed = 0
        var failed = 0
        var paused = 0
        var lastError: MiraError?
        var output: AgentModelOutput?
    }
    private var state = State()
    private let source: SessionUserEvidence
    private let head: SessionJournalHead
    private let selection: AgentModelRouteResolution
    private var job: MemoryExtractionJob
    init(source: SessionUserEvidence, head: SessionJournalHead, selection: AgentModelRouteResolution) {
        self.source = source
        self.head = head
        self.selection = selection
        let completionHead = head
        let origin = MemoryExtractionOrigin(
            source: source.reference, completedExecutionID: source.reference.originalExecutionID, completionEventID: UUID(),
            completionHead: completionHead)
        self.job = .init(
            id: .init(), origin: origin, workspaceID: nil, state: .queued,
            createdAt: source.admittedAt, updatedAt: source.admittedAt)
    }
    var claimed: Int { state.claimed }
    var prepared: Int { state.prepared }
    var dispatched: Int { state.dispatched }
    var completed: Int { state.completed }
    var failed: Int { state.failed }
    var paused: Int { state.paused }
    var lastError: MiraError? { state.lastError }
    var output: AgentModelOutput? { state.output }
    func makeClaim() throws -> MemoryExtractionClaim {
        var copy = job
        copy.state = .running
        copy.attemptCount = 1
        return .init(
            job: copy, source: source, selection: selection, leaseID: UUID(),
            leaseExpiresAt: source.admittedAt.addingTimeInterval(300), attemptID: UUID())
    }
    func wait(_ predicate: @escaping @Sendable (State) -> Bool) async throws {
        for _ in 0..<2_500 {
            if predicate(state) { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw MiraError(.timeout, "Worker fixture did not reach its expected state.")
    }
    func memoryExtractionJobs(sessionID: ConversationID?, state requested: MemoryExtractionJobState?, limit: Int)
        async throws -> [MemoryExtractionJob]
    { job.state == .queued ? [job] : [] }
    func nextQueuedMemoryExtraction(after sessionID: ConversationID?) async throws -> MemoryExtractionJob? {
        job.state == .queued ? job : nil
    }
    func claimMemoryExtraction(
        _ id: MemoryExtractionJobID, expectedAttemptCount: Int, source: SessionUserEvidence,
        selection: AgentModelRouteResolution, authorization: AgentLibraryAuthorization, at: Date
    ) async throws -> MemoryExtractionClaim? {
        guard job.id == id, job.state == .queued else { return nil }
        job.state = .running
        job.attemptCount = expectedAttemptCount + 1
        state.claimed += 1
        return .init(
            job: job, source: source, selection: selection, leaseID: UUID(),
            leaseExpiresAt: at.addingTimeInterval(300), attemptID: UUID())
    }
    func prepareMemoryExtraction(
        _ claim: MemoryExtractionClaim, request: AgentPreparedModelRequest, source: SessionUserEvidence,
        authorization: AgentLibraryAuthorization, at: Date
    ) async throws -> Int {
        state.prepared += 1
        return 10
    }
    func markMemoryExtractionDispatched(
        _ claim: MemoryExtractionClaim, source: SessionUserEvidence, authorization: AgentLibraryAuthorization, at: Date
    ) async throws { state.dispatched += 1 }
    func completeMemoryExtraction(
        _ claim: MemoryExtractionClaim, source: SessionUserEvidence, output: AgentModelOutput,
        authorization: AgentLibraryAuthorization, at: Date
    ) async throws -> MemoryExtractionJob {
        state.completed += 1
        state.output = output
        job.state = .completed
        return job
    }
    func failMemoryExtraction(
        _ claim: MemoryExtractionClaim, error: MiraError, authorization: AgentLibraryAuthorization, at: Date
    ) async throws {
        state.failed += 1
        state.lastError = error
        job.state = .failed
    }
    func pauseMemoryExtraction(
        _ id: MemoryExtractionJobID, expectedAttemptCount: Int, error: MiraError,
        authorization: AgentLibraryAuthorization, at: Date
    ) async throws {
        state.paused += 1
        state.lastError = error
        job.state = .paused
    }
    func retryMemoryExtraction(
        _ id: MemoryExtractionJobID, source: SessionUserEvidence, authorization: AgentLibraryAuthorization, at: Date
    ) async throws -> MemoryExtractionJobID { id }
    func recoverMemoryExtraction(authorization: AgentLibraryAuthorization, at: Date) async throws {}
}

private struct WorkerAdapter: AgentModelAdapter {
    let identity = AgentAdapterIdentity(id: "memory.fixture", revision: 1)
    let probe: WorkerProbe
    let events: [AgentModelStreamEvent]
    let prepareGate: WorkerGate?
    let streamGate: WorkerGate?
    let mutateInput: Bool
    let requiresCompactInput: Bool
    init(
        probe: WorkerProbe = .init(),
        events: [AgentModelStreamEvent] = [.blockStarted(.init(id: "text", content: .text("{\"version\":3,\"items\":[]}"))), .blockFinished(id: "text"), .finished(.stop)],
        prepareGate: WorkerGate? = nil, streamGate: WorkerGate? = nil, mutateInput: Bool = false, requiresCompactInput: Bool = false
    ) {
        self.probe = probe
        self.events = events
        self.prepareGate = prepareGate
        self.streamGate = streamGate
        self.mutateInput = mutateInput
        self.requiresCompactInput = requiresCompactInput
    }
    func prepare(_ input: AgentModelInput, route: AgentModelRoute) throws -> AgentPreparedModelRequest {
        probe.prepared(input)
        if requiresCompactInput, input.prefixMessageCount != nil {
            throw MiraError(.contextLimit, "Synthetic request limit.")
        }
        let preparedInput =
            mutateInput
            ? AgentModelInput(
                stepID: input.stepID, executionID: input.executionID, instructions: input.instructions + " altered",
                messages: input.messages, tools: input.tools) : input
        if let prepareGate { _ = prepareGate.blockingPrepare(input: preparedInput, adapter: identity) }
        return .init(
            adapter: identity, input: preparedInput, wirePayload: .object(["fixture": .bool(true)]),
            estimatedInputTokens: 1)
    }
    func stream(_ request: AgentPreparedModelRequest, route: AgentModelRoute) -> AgentModelOperation {
        probe.streamed()
        let pair = AsyncThrowingStream<AgentModelStreamEvent, any Error>.makeStream()
        let task = Task {
            if let streamGate { await streamGate.wait() }
            for event in events { pair.continuation.yield(event) }
            pair.continuation.finish()
            probe.finished()
        }
        return .init(
            events: pair.stream,
            cancelAndDrain: {
                task.cancel()
                await task.value
                probe.closed()
            })
    }
    func replay(
        _ messages: [AgentModelMessage], from source: AgentModelRoute, to target: AgentModelRoute,
        boundary: AgentReplayBoundary
    ) throws -> AgentReplayDecision { .include(messages) }
}

private final class WorkerProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var prepareValue = 0
    private var capturedInput: AgentModelInput?
    var lastInput: AgentModelInput? { lock.withLock { capturedInput } }
    private var streamValue = 0
    private var closeValue = 0
    var prepareCount: Int { lock.withLock { prepareValue } }
    var streamCount: Int { lock.withLock { streamValue } }
    var closeCount: Int { lock.withLock { closeValue } }
    func prepared(_ input: AgentModelInput) { lock.withLock { prepareValue += 1; capturedInput = input } }
    func streamed() { lock.withLock { streamValue += 1 } }
    func finished() {}
    func closed() { lock.withLock { closeValue += 1 } }
    func waitForStream() async throws {
        for _ in 0..<5_000 {
            if streamCount > 0 { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw MiraError(.timeout, "Worker stream was not entered.")
    }
}

private actor CloseProbe {
    private(set) var didReturn = false
    func returned() { didReturn = true }
}

private final class WorkerGate: @unchecked Sendable {
    private let lock = NSLock()
    private let releaseSignal = DispatchSemaphore(value: 0)
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func blockingPrepare(input: AgentModelInput, adapter: AgentAdapterIdentity) -> AgentPreparedModelRequest {
        let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
            entered = true
            let waiters = entryWaiters
            entryWaiters.removeAll()
            return waiters
        }
        waiters.forEach { $0.resume() }
        releaseSignal.wait()
        return .init(
            adapter: adapter, input: input, wirePayload: .object(["fixture": .bool(true)]), estimatedInputTokens: 1)
    }

    func waitForEntry() async {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock {
                if entered { return true }
                entryWaiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock {
                if released { return true }
                releaseWaiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func release() {
        let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
            released = true
            let waiters = releaseWaiters
            releaseWaiters.removeAll()
            return waiters
        }
        releaseSignal.signal()
        waiters.forEach { $0.resume() }
    }
}

private struct WorkerRoute {
    let candidate: AgentModelRouteCandidate
    let route: AgentModelRoute
    static func make() -> WorkerRoute {
        let identity = AgentAdapterIdentity(id: "memory.fixture", revision: 1)
        let connection = AgentConfiguredConnection(id: .init(), revision: 1, configurationRevision: 1, name: "Fixture", isEnabled: true, definitionID: nil, endpoints: [.init(id: "primary", configuration: .init(
                schema: .init(id: "fixture.connection", revision: 1),
                value: .object(["endpoint": .string("https://fixture.example")])), credential: nil)], discovery: nil, defaultInvocation: nil)
        let model = AgentConfiguredModel(id: .init(), revision: 1, authorizationRevision: 1, reference: .init(connectionID: connection.id, modelID: "fixture"), displayName: nil, isEnabled: true, invocations: [AgentModelInvocationSpec(id: "default", revision: 1, adapter: identity, endpointID: "primary", contextWindow: 4_096, maximumOutputTokens: nil, capabilities: [
                AgentModelCapabilityID.streamingText: .verified, AgentModelCapabilityID.jsonOutput: .verified,
                AgentModelCapabilityID.thinking: .verified,
            ], configuration: .init(schema: .init(id: "test.invocation", revision: 1), value: .object([:])), parameterSchema: .object(["type": .string("object"), "properties": .object([:]), "additionalProperties": .bool(false)]))], facts: [])
        let preset = AgentRoutePreset(id: .init(), revision: 1, name: "Fixture", modelDescriptorID: model.id, invocationID: "default", maximumOutputTokens: 512, configuration: .init(schema: .init(id: "fixture.route", revision: 1), value: .object([:])))
        let candidate = AgentModelRouteCandidate(connection: connection, model: model, preset: preset)
        return .init(
            candidate: candidate, route: try! candidate.freeze(configuration: .object(["fixture": .bool(true)])))
    }
}

private struct WorkerConfigurationProvider: AgentModelConfigurationProvider {
    let identity: AgentAdapterIdentity
    func descriptor(for invocation: AgentModelInvocationSpec) throws -> AgentModelConfigurationDescriptor {
        let connection = AgentConfigurationSchema(
            identity: .init(id: "fixture.connection", revision: 1), title: "Fixture connection",
            schema: .object([
                "type": .string("object"), "properties": .object(["endpoint": .object(["type": .string("string")])]),
                "required": .array([.string("endpoint")]), "additionalProperties": .bool(false),
            ]), defaults: .object(["endpoint": .string("https://fixture.example")]))
        let route = AgentConfigurationSchema(
            identity: .init(id: "fixture.route", revision: 1), title: "Fixture route",
            schema: .object([
                "type": .string("object"), "properties": .object([:]), "additionalProperties": .bool(false),
            ]), defaults: .object([:]))
        return .init(adapter: identity, title: invocation.id, credential: .none, connection: connection, route: route)
    }
    func configuration(for candidate: AgentModelRouteCandidate) throws -> JSONValue {
        .object(["fixture": .bool(true)])
    }
}

private actor WorkerSettings: AgentModelSettingsStore {
    let selection: AgentModelRouteSelection
    init(selection: AgentModelRouteSelection) { self.selection = selection }
    func discoverySnapshot(connectionID: ConnectionID) async throws -> AgentModelDiscoverySnapshot? { nil }
    func saveDiscoverySnapshot(_ value: AgentModelDiscoverySnapshot, expectedRevision: Int?, authorization: AgentLibraryAuthorization) async throws {}
    func select(purpose: String, explicitRouteID: RouteID?, workspaceID: WorkspaceID?) async throws -> AgentModelRouteSelection {
        throw MiraError(.configuration, "Background memory must not resolve a new purpose or default binding.")
    }
    func candidate(routeID: RouteID) async throws -> AgentModelRouteCandidate { selection.candidate }
    func connection(id: ConnectionID) async throws -> AgentConfiguredConnection? { nil }
    func model(id: ModelDescriptorID) async throws -> AgentConfiguredModel? { nil }
    func preset(id: RouteID) async throws -> AgentRoutePreset? { nil }
    func connections(after: ConnectionID?, limit: Int) async throws -> [AgentConfiguredConnection] { [] }
    func models(connectionID: ConnectionID?, after: ModelDescriptorID?, limit: Int) async throws
        -> [AgentConfiguredModel]
    { [] }
    func presets(modelID: ModelDescriptorID?, after: RouteID?, limit: Int) async throws -> [AgentRoutePreset] { [] }
    func ensureConversationDefault(authorization: AgentLibraryAuthorization) async throws -> AgentRouteBinding? { nil }
    func bindings(scope: AgentRouteScope) async throws -> [AgentRouteBinding] { [] }
    func saveConnection(_ value: AgentConfiguredConnection, expectedRevision: Int?, authorization: AgentLibraryAuthorization) async throws {}
    func saveModel(_ value: AgentConfiguredModel, expectedRevision: Int?, authorization: AgentLibraryAuthorization) async throws {}
    func savePreset(_ value: AgentRoutePreset, expectedRevision: Int?, authorization: AgentLibraryAuthorization) async throws {}
    func savePoolModel(
        _ model: AgentConfiguredModel, preset: AgentRoutePreset, expectedModelRevision: Int?,
        expectedPresetRevision: Int?
    , authorization: AgentLibraryAuthorization) async throws {}
    func saveBinding(_ value: AgentRouteBinding, expectedRevision: Int?, authorization: AgentLibraryAuthorization) async throws {}
    func deleteConnection(id: ConnectionID, expectedRevision: Int, authorization: AgentLibraryAuthorization) async throws {}
    func deleteModel(id: ModelDescriptorID, expectedRevision: Int, authorization: AgentLibraryAuthorization) async throws {}
    func deletePreset(id: RouteID, expectedRevision: Int, authorization: AgentLibraryAuthorization) async throws {}
    func deleteBinding(scope: AgentRouteScope, purpose: String, expectedRevision: Int, authorization: AgentLibraryAuthorization) async throws {}
}

private actor WorkerMaintenanceStore: AgentLibraryMaintenanceStore {
    let auth = AgentLibraryAuthorization(libraryID: UUID(), epoch: 0)
    func state() async throws -> AgentLibraryMaintenanceState { .init(authorization: auth, pending: nil) }
    func operation(id: UUID) async throws -> AgentLibraryMaintenanceOperation? { nil }
    func begin(_ request: AgentLibraryMaintenanceRequest, expected: AgentLibraryAuthorization) async throws
        -> AgentLibraryMaintenanceOperation
    { throw MiraError(.unsupported, "Fixture maintenance unavailable.") }
    func complete(_ operation: AgentLibraryMaintenanceOperation, at date: Date) async throws
        -> AgentLibraryMaintenanceOperation
    { throw MiraError(.unsupported, "Fixture maintenance unavailable.") }
}

private actor WorkerJournal: SessionJournal, SessionPayloadStore {
    private var batches: [SessionBatch] = []
    private var bytes: [SessionPayloadReference: Data] = [:]
    func append(_ batch: SessionBatch) async -> SessionAppendOutcome {
        batches.append(batch)
        return .committed(batch.cursor)
    }
    func reconcile(_ batch: SessionBatch) async -> SessionAppendOutcome {
        if !batches.contains(where: { $0.id == batch.id }) { batches.append(batch) }
        return .committed(batch.cursor)
    }
    func batch(id: UUID, sessionID: ConversationID) async throws -> SessionBatch? {
        batches.first { $0.id == id && $0.sessionID == sessionID }
    }
    func head(sessionID: ConversationID) async throws -> SessionJournalHead {
        guard
            let batch = batches.filter({ $0.sessionID == sessionID }).max(by: {
                $0.cursor.sequence < $1.cursor.sequence
            })
        else { return .init(cursor: .init(sessionID: sessionID, sequence: 0), batchID: nil) }
        return .init(cursor: batch.cursor, batchID: batch.id)
    }
    func read(sessionID: ConversationID, after sequence: Int64, limit: Int) async throws -> [SessionBatch] {
        Array(batches.filter { $0.sessionID == sessionID && $0.cursor.sequence > sequence }.prefix(limit))
    }
    func sessions(after: ConversationID?, limit: Int) async throws -> [ConversationID] {
        Array(Set(batches.map(\.sessionID)).prefix(limit))
    }
    func flush() async throws {}
    func close() async throws {}
    func stage(_ data: Data, sessionID: ConversationID, batchID: UUID, retentionGroup: UUID, kind: SessionPayloadKind)
        async throws -> SessionPayloadReference
    {
        let ref = SessionPayloadReference(
            id: UUID(), sessionID: sessionID, batchID: batchID, retentionGroup: retentionGroup, kind: kind,
            byteCount: data.count, digest: String(repeating: "0", count: 64))
        bytes[ref] = data
        return ref
    }
    func read(_ reference: SessionPayloadReference) async throws -> Data {
        guard let data = bytes[reference],
            batches.contains(where: { $0.events.contains { $0.fact.payloadReferences.contains(reference) } })
        else { throw MiraError(.unauthorized, "Fixture evidence was revoked.") }
        return data
    }
    func purge(sessionID: ConversationID, retentionGroups: Set<UUID>) async throws {
        bytes = bytes.filter { $0.key.sessionID != sessionID || !retentionGroups.contains($0.key.retentionGroup) }
    }
}
