import Foundation
import Testing
@testable import MiraCore
@testable import MiraData

@Suite("Agent model retry integration", .timeLimit(.minutes(1)))
struct AgentModelRetryIntegrationTests {
    @Test func transientFailureRetriesWithStableStepAndNewAttempts() async throws {
        let fixture = try await RetryFixture.make(behaviors: [.transient(0), .success])
        try await withRetryFixture(fixture) { fixture in
            let result = await fixture.kernel.run()
            guard case .committed = result else { Issue.record("Retry execution did not settle: \(result)"); return }
            let state = await fixture.runtime.snapshot()
            let execution = try #require(state.executions[fixture.executionID])
            #expect(execution.completion?.status == .completed)
            #expect(await fixture.probe.dispatchCount == 2)
            let inputs = await fixture.probe.inputs
            try #require(inputs.count == 2)
            let attempts = execution.attemptIDs.compactMap { state.attempts[$0] }
            try #require(attempts.count == 2)
            #expect(inputs[0] == inputs[1])
            #expect(attempts[0].attempt.request == attempts[1].attempt.request)
            var requests: [AgentSessionRequest] = []
            for attempt in attempts {
                requests.append(try SessionCodec.decode(AgentSessionRequest.self,
                    from: await fixture.library.read(attempt.attempt.request)))
            }
            #expect(requests[0] == requests[1])
            #expect(requests[0].instructions == inputs[0].instructions)
            #expect(requests[0].tools == inputs[0].tools)
            #expect(requests[0].contextMessages == inputs[0].messages.filter { $0.role == .context })
            #expect(attempts.map { $0.attempt.stepIndex } == [1, 1])
            #expect(attempts.map { $0.attempt.attemptIndex } == [1, 2])
            #expect(attempts[0].attempt.id != attempts[1].attempt.id)
            #expect(attempts[0].resolution?.status == .failed)
            let errorReference = try #require(attempts[0].resolution?.error)
            let record = try SessionCodec.decode(AgentModelAttemptFailureRecord.self,
                from: await fixture.library.read(errorReference))
            #expect(record.receivedStreamEvents == false)
            #expect(record.failure.retryAdvice == .transient(minimumDelayMilliseconds: 0))
            #expect(await fixture.clock.shortDelays == [.milliseconds(500)])
            let lease = try await fixture.libraryAccessFixture.acquire()
            let audit = try await lease.read {
                let snapshot = try await JournalSessionReader(journal: fixture.library, payloads: fixture.library)
                    .snapshot(sessionID: state.id)
                return try await SessionAuditReader.read(
                    snapshot: snapshot, sessionID: state.id, executionID: fixture.executionID,
                    beforeSequence: nil, limit: 1, maximumPageBytes: 64 * 1_024 * 1_024,
                    payloads: lease.reader(from: fixture.library))
            }
            #expect(audit.attempts.count == 1 && audit.hasMore)
            #expect(audit.modelUsage.map(\.id) == attempts.reversed().map { $0.attempt.id })
            #expect(audit.modelUsage.map(\.isComplete) == [true, false])
        }
    }

    @Test func unclassifiedFailureDoesNotRetry() async throws {
        let fixture = try await RetryFixture.make(behaviors: [.unclassified, .success])
        try await withRetryFixture(fixture) { fixture in
            let result = await fixture.kernel.run()
            guard case .committed = result else { Issue.record("Failure did not settle: \(result)"); return }
            let state = await fixture.runtime.snapshot()
            #expect(state.executions[fixture.executionID]?.completion?.status == .failed)
            #expect(await fixture.probe.dispatchCount == 1)
            #expect(state.executions[fixture.executionID]?.attemptIDs.count == 1)
        }
    }

    @Test func usageOnlyEventDoesNotRetry() async throws {
        let fixture = try await RetryFixture.make(behaviors: [.partialUsage, .success])
        try await withRetryFixture(fixture) { fixture in
            let result = await fixture.kernel.run()
            guard case .committed = result else { Issue.record("Usage failure did not settle: \(result)"); return }
            let state = await fixture.runtime.snapshot()
            #expect(state.executions[fixture.executionID]?.completion?.status == .failed)
            #expect(await fixture.probe.dispatchCount == 1)
            let execution = try #require(state.executions[fixture.executionID])
            let attempt = try #require(execution.attemptIDs.first.flatMap { state.attempts[$0] })
            let reference = try #require(attempt.resolution?.error)
            let record = try SessionCodec.decode(AgentModelAttemptFailureRecord.self,
                from: await fixture.library.read(reference))
            #expect(record.receivedStreamEvents)
            #expect(attempt.resolution?.usage == .init(inputTokens: 1, outputTokens: 1))
            #expect(execution.completion?.usage == .init(inputTokens: 1, outputTokens: 1))
        }
    }

    @Test func anyReceivedStreamEventDisablesAutomaticRetry() async throws {
        for behavior in [RetryBehavior.partialText, .partialThinking, .partialTool] {
            let fixture = try await RetryFixture.make(behaviors: [behavior, .success])
            try await withRetryFixture(fixture) { fixture in
                let result = await fixture.kernel.run()
                guard case .committed = result else { Issue.record("Partial failure did not settle: \(result)"); return }
                let state = await fixture.runtime.snapshot()
                #expect(state.executions[fixture.executionID]?.completion?.status == .failed)
                #expect(await fixture.probe.dispatchCount == 1)
                let execution = try #require(state.executions[fixture.executionID])
                let attempt = try #require(execution.attemptIDs.first.flatMap { state.attempts[$0] })
                let errorReference = try #require(attempt.resolution?.error)
                let record = try SessionCodec.decode(AgentModelAttemptFailureRecord.self,
                    from: await fixture.library.read(errorReference))
                #expect(record.receivedStreamEvents)
            }
        }
    }

    @Test func retryPolicyAndProviderDelayCeilingAreEnforced() async throws {
        let capped = try await RetryFixture.make(behaviors: [.transient(0), .success],
            limits: .init(modelRetryPolicy: .init(maximumAttempts: 1, initialDelayMilliseconds: 0, maximumDelayMilliseconds: 5_000)))
        try await withRetryFixture(capped) { fixture in
            let result = await fixture.kernel.run()
            guard case .committed = result else { Issue.record("Capped retry did not settle: \(result)"); return }
            #expect(await fixture.probe.dispatchCount == 1)
            let state = await fixture.runtime.snapshot()
            #expect(state.executions[fixture.executionID]?.completion?.status == .failed)
            #expect(state.executions[fixture.executionID]?.attemptIDs.count == 1)
        }

        let overCeiling = try await RetryFixture.make(behaviors: [.transient(5_001), .success])
        try await withRetryFixture(overCeiling) { fixture in
            let result = await fixture.kernel.run()
            guard case .committed = result else { Issue.record("Ceiling retry did not settle: \(result)"); return }
            #expect(await fixture.probe.dispatchCount == 1)
            #expect(await fixture.clock.shortDelays.isEmpty)
            let state = await fixture.runtime.snapshot()
            #expect(state.executions[fixture.executionID]?.completion?.status == .failed)
            #expect(state.executions[fixture.executionID]?.attemptIDs.count == 1)
        }

        let reserved = try await RetryFixture.make(behaviors: [.transient(0), .success],
            limits: .init(maximumReservedOutputTokens: 128,
                modelTimeoutMilliseconds: 60_000, executionTimeoutMilliseconds: 60_000,
                modelRetryPolicy: .init(maximumAttempts: 3, initialDelayMilliseconds: 0, maximumDelayMilliseconds: 5_000)))
        try await withRetryFixture(reserved) { fixture in
            let result = await fixture.kernel.run()
            guard case .committed = result else { Issue.record("Reserved output retry did not settle: \(result)"); return }
            #expect(await fixture.probe.dispatchCount == 1)
            let state = await fixture.runtime.snapshot()
            #expect(state.executions[fixture.executionID]?.completion?.status == .failed)
            #expect(state.executions[fixture.executionID]?.attemptIDs.count == 1)
        }
    }

    @Test func successfulRetryPreservesThinkingContinuation() async throws {
        let fixture = try await RetryFixture.make(behaviors: [.transient(0), .thinkingSuccess])
        try await withRetryFixture(fixture) { fixture in
            let result = await fixture.kernel.run()
            guard case .committed = result else { Issue.record("Thinking retry did not settle: \(result)"); return }
            let state = await fixture.runtime.snapshot()
            let completion = try #require(state.executions[fixture.executionID]?.completion)
            #expect(completion.status == .completed)
            #expect(await fixture.probe.dispatchCount == 2)
            let thinking = try #require(completion.visibleThinking)
            #expect(String(data: try await fixture.library.read(thinking), encoding: .utf8) == "private")
        }
    }

    @Test func retryThatSucceedsWithToolCallContinuesWithCommittedToolExchange() async throws {
        let fixture = try await RetryFixture.make(behaviors: [.transient(0), .tool, .success], includeTool: true)
        try await withRetryFixture(fixture) { fixture in
            let result = await fixture.kernel.run()
            guard case .committed = result else { Issue.record("Tool retry did not settle: \(result)"); return }
            let state = await fixture.runtime.snapshot()
            #expect(state.executions[fixture.executionID]?.completion?.status == .completed)
            #expect(await fixture.probe.dispatchCount == 3)
            #expect(await fixture.toolProbe.executeCount == 1)

            let attempts = try #require(state.executions[fixture.executionID]).attemptIDs.compactMap { state.attempts[$0] }
            try #require(attempts.count == 3)
            #expect(attempts.map { $0.attempt.stepIndex } == [1, 1, 2])
            #expect(attempts.map { $0.attempt.attemptIndex } == [1, 2, 1])
            #expect(attempts[0].resolution?.status == .failed)
            #expect(attempts[1].resolution?.status == .completed)

            let inputs = await fixture.probe.inputs
            try #require(inputs.count == 3)
            let assistant = try #require(inputs[2].messages.first(where: { $0.role == .assistant }))
            #expect(assistant.toolCalls == [.init(id: "read-once", name: "retry.read", arguments: "{}")])
            let tool = try #require(inputs[2].messages.first(where: { $0.role == .tool }))
            #expect(tool.toolResults.first?.callID == "read-once")
        }
    }

    @Test func retryAfterToolStepDoesNotDuplicateToolExecution() async throws {
        let fixture = try await RetryFixture.make(behaviors: [.toolWithThinking, .transient(0), .success], includeTool: true)
        try await withRetryFixture(fixture) { fixture in
            let result = await fixture.kernel.run()
            guard case .committed = result else { Issue.record("Tool retry did not settle: \(result)"); return }
            let state = await fixture.runtime.snapshot()
            #expect(state.executions[fixture.executionID]?.completion?.status == .completed)
            #expect(await fixture.probe.dispatchCount == 3)
            #expect(await fixture.toolProbe.executeCount == 1)
            let execution = try #require(state.executions[fixture.executionID])
            let attempts = execution.attemptIDs.compactMap { state.attempts[$0] }
            try #require(attempts.count == 3)
            #expect(attempts[1].attempt.stepID == attempts[2].attempt.stepID)
            #expect(attempts[0].attempt.stepID != attempts[1].attempt.stepID)
            let inputs = await fixture.probe.inputs
            try #require(inputs.count == 3)
            #expect(inputs[1] == inputs[2])
            let assistant = try #require(inputs[1].messages.first(where: { $0.role == .assistant }))
            #expect(assistant.toolCalls == [.init(id: "read-once", name: "retry.read", arguments: "{}")])
            #expect(assistant.thinkingText == "tool reasoning")
            #expect(assistant.continuation == .init(adapter: .init(id: "retry.synthetic", revision: 1),
                format: "retry.blocks", payload: .object(["opaque": .string("tool-continuation")]), isComplete: true))
            let tool = try #require(inputs[1].messages.first(where: { $0.role == .tool }))
            #expect(tool.toolResults.first?.callID == "read-once")
        }
    }

    @Test func cancellationDoesNotStartAnotherRetry() async throws {
        let fixture = try await RetryFixture.make(behaviors: [.hold, .success])
        try await withRetryFixture(fixture) { fixture in
            let running = Task { await fixture.kernel.run() }
            await fixture.probe.waitUntilEntered()
            await fixture.kernel.cancel()
            await fixture.probe.release()
            _ = await running.value
            #expect(await fixture.probe.dispatchCount == 1)
            let state = await fixture.runtime.snapshot()
            #expect(state.executions[fixture.executionID]?.completion?.status == .cancelled)
        }
    }

    @Test func cancellationDuringRetryBackoffDoesNotDispatchAgain() async throws {
        let fixture = try await RetryFixture.make(behaviors: [.transient(0), .success])
        await fixture.clock.holdShortDelays()
        try await withRetryFixture(fixture) { fixture in
            let running = Task { await fixture.kernel.run() }
            await fixture.clock.waitUntilShortDelay()
            #expect(await fixture.probe.dispatchCount == 1)
            do {
                let lease = try await fixture.scheduler.acquire(executionID: fixture.executionID, priority: .foreground)
                await lease.release()
            } catch { Issue.record("Backoff still owned the model lease: \(error)") }
            await fixture.kernel.cancel()
            _ = await running.value
            #expect(await fixture.probe.dispatchCount == 1)
            let state = await fixture.runtime.snapshot()
            #expect(state.executions[fixture.executionID]?.completion?.status == .cancelled)
            #expect(await fixture.clock.shortDelays == [.milliseconds(500)])
        }
    }

    @Test func successfulRetryReopensWithIdenticalJournalAndNoRedispatch() async throws {
        let fixture = try await RetryFixture.make(behaviors: [.transient(0), .success])
        try await withRetryFixture(fixture) { fixture in
            let result = await fixture.kernel.run()
            guard case .committed = result else { Issue.record("Reopen retry did not settle: \(result)"); return }
            let before = await fixture.runtime.snapshot()
            let batches = try await fixture.library.read(sessionID: before.id, after: 0,
                limit: SessionFormatLimits.maximumReadBatches)
            let count = await fixture.probe.dispatchCount
            let reopened = try await fixture.reopen()
            #expect(reopened.state == before)
            #expect(reopened.batches == batches)
            #expect(await fixture.probe.dispatchCount == count)
        }
    }
}

private func withRetryFixture<T>(_ fixture: RetryFixture,
                                 _ body: (RetryFixture) async throws -> T) async throws -> T {
    do {
        let value = try await body(fixture)
        await fixture.shutdown()
        return value
    } catch {
        await fixture.shutdown()
        throw error
    }
}

private enum RetryBehavior: Sendable {
    case transient(Int)
    case unclassified
    case partialText
    case partialThinking
    case partialTool
    case partialUsage
    case success
    case thinkingSuccess
    case tool
    case toolWithThinking
    case hold
}

private actor RetryProbe {
    let behaviors: [RetryBehavior]
    private var index = 0
    private(set) var inputs: [AgentModelInput] = []
    private var entered = false
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(behaviors: [RetryBehavior]) { self.behaviors = behaviors }
    var dispatchCount: Int { inputs.count }

    func next(_ input: AgentModelInput) -> RetryBehavior {
        inputs.append(input)
        let value = behaviors[min(index, max(behaviors.count - 1, 0))]
        index += 1
        return value
    }

    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { waiters.append($0) } }
    }

    func waitForRelease() async {
        if !released { await withCheckedContinuation { waiters.append($0) } }
    }

    func markEntered() {
        entered = true
        let pending = waiters; waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }

    func release() {
        released = true
        let pending = waiters; waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private actor RetryClock: RuntimeClock {
    private(set) var durations: [Duration] = []
    private(set) var streamCadences: [Duration] = []
    private(set) var retryBackoffDurations: [Duration] = []
    private var pending: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var holdShort = false
    private var shortDelayWaiters: [CheckedContinuation<Void, Never>] = []

    /// Retry backoff is tracked separately from the executor's draft and live output cadences.
    var shortDelays: [Duration] { retryBackoffDurations }

    func holdShortDelays() { holdShort = true }

    func waitUntilShortDelay() async {
        if !retryBackoffDurations.isEmpty { return }
        await withCheckedContinuation { shortDelayWaiters.append($0) }
    }

    func sleep(for duration: Duration) async throws {
        durations.append(duration)
        let isStreamCadence = duration == .milliseconds(250) || duration == .milliseconds(100)
        if isStreamCadence {
            streamCadences.append(duration)
        } else if duration <= .seconds(5) {
            retryBackoffDurations.append(duration)
            let observers = shortDelayWaiters
            shortDelayWaiters.removeAll()
            for observer in observers { observer.resume() }
            guard holdShort else { return }
        }
        let id = UUID()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { pending[id] = continuation }
            }
        }, onCancel: {
            Task { await self.cancel(id) }
        })
    }

    private func cancel(_ id: UUID) {
        pending.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}

private struct RetryModelAdapter: AgentModelAdapter {
    let identity = AgentAdapterIdentity(id: "retry.synthetic", revision: 1)
    let probe: RetryProbe

    func prepare(_ input: AgentModelInput, route: AgentModelRoute) throws -> AgentPreparedModelRequest {
        try input.validate(for: route)
        return .init(adapter: identity, input: input, wirePayload: .object(["step": .string(input.stepID.uuidString)]), estimatedInputTokens: 1)
    }

    func stream(_ request: AgentPreparedModelRequest, route: AgentModelRoute) -> AgentModelOperation {
        let (stream, continuation) = AsyncThrowingStream<AgentModelStreamEvent, any Error>.makeStream()
        let producer = Task {
            let behavior = await probe.next(request.input)
            await probe.markEntered()
            switch behavior {
            case .transient(let delay):
                continuation.finish(throwing: AgentModelFailure(error: .init(.network, "Synthetic transient failure."),
                    retryAdvice: .transient(minimumDelayMilliseconds: delay)))
            case .unclassified:
                continuation.finish(throwing: MiraError(.network, "Synthetic unclassified failure."))
            case .partialText:
                continuation.yield(.blockStarted(.init(id: "text", content: .text("partial"))))
                continuation.finish(throwing: AgentModelFailure(error: .init(.network, "Partial text failure."), retryAdvice: .transient(minimumDelayMilliseconds: 0)))
            case .partialThinking:
                continuation.yield(.blockStarted(.init(id: "thinking", content: .thinking("partial reasoning"))))
                continuation.finish(throwing: AgentModelFailure(error: .init(.network, "Partial thinking failure."), retryAdvice: .transient(minimumDelayMilliseconds: 0)))
            case .partialTool:
                continuation.yield(.blockStarted(.init(id: "tool-0", content: .toolCall(.init(id: "partial-call", name: "retry.read", arguments: "{}")))))
                continuation.finish(throwing: AgentModelFailure(error: .init(.network, "Partial tool failure."), retryAdvice: .transient(minimumDelayMilliseconds: 0)))
            case .partialUsage:
                continuation.yield(.usage(.init(inputTokens: 1, outputTokens: 1)))
                continuation.finish(throwing: AgentModelFailure(error: .init(.network, "Usage-only failure."), retryAdvice: .transient(minimumDelayMilliseconds: 0)))
            case .success:
                continuation.yield(.blockStarted(.init(id: "text", content: .text("done"))))
                continuation.yield(.blockFinished(id: "text"))
                continuation.yield(.finished(.stop))
                continuation.finish()
            case .thinkingSuccess:
                let continuationData = AgentModelContinuation(adapter: identity, format: "retry.blocks",
                    payload: .object(["opaque": .string("continuation")]), isComplete: true)
                continuation.yield(.blockStarted(.init(id: "thinking", content: .thinking("private"))))
                continuation.yield(.continuation(continuationData))
                continuation.yield(.blockFinished(id: "thinking"))
                continuation.yield(.blockStarted(.init(id: "text", content: .text("done"))))
                continuation.yield(.blockFinished(id: "text"))
                continuation.yield(.finished(.stop))
                continuation.finish()
            case .tool:
                continuation.yield(.blockStarted(.init(id: "tool-0", content: .toolCall(.init(id: "read-once", name: "retry.read", arguments: "{}")))))
                continuation.yield(.blockFinished(id: "tool-0"))
                continuation.yield(.finished(.toolCalls))
                continuation.finish()
            case .toolWithThinking:
                let continuationData = AgentModelContinuation(adapter: identity, format: "retry.blocks",
                    payload: .object(["opaque": .string("tool-continuation")]), isComplete: true)
                continuation.yield(.blockStarted(.init(id: "thinking", content: .thinking("tool reasoning"))))
                continuation.yield(.continuation(continuationData))
                continuation.yield(.blockFinished(id: "thinking"))
                continuation.yield(.blockStarted(.init(id: "tool-0", content: .toolCall(.init(id: "read-once", name: "retry.read", arguments: "{}")))))
                continuation.yield(.blockFinished(id: "tool-0"))
                continuation.yield(.finished(.toolCalls))
                continuation.finish()
            case .hold:
                await probe.waitForRelease()
                continuation.finish(throwing: CancellationError())
            }
        }
        return AgentModelOperation(events: stream, cancelAndDrain: {
            producer.cancel()
            _ = await producer.value
        })
    }

    func replay(_ messages: [AgentModelMessage], from source: AgentModelRoute,
                to target: AgentModelRoute, boundary: AgentReplayBoundary) throws -> AgentReplayDecision {
        .include(messages)
    }
}

private actor RetryToolProbe { private(set) var executeCount = 0; func executed() { executeCount += 1 } }

private struct RetryReadTool: AgentReadTool {
    let policy: AgentToolPolicyRequirement = .hostOnly
    let descriptor: AgentToolDescriptor
    let probe: RetryToolProbe
    func prepare(_ arguments: JSONValue, context: AgentToolContext) async throws -> AgentToolPlan {
        .init(input: arguments, sources: [], targets: [])
    }
    func execute(_ plan: AgentToolPlan, context: AgentToolContext) async throws -> JSONValue {
        await probe.executed()
        return .object(["ok": .bool(true)])
    }
}

private struct RetryAllowPolicy: AgentToolPolicy {
    func evaluate(_ proposal: AgentToolProposal, context: AgentToolContext) async throws -> AgentToolPolicyDecision { .allow }
    func validate(_ proposal: AgentToolProposal, context: AgentToolContext) async throws {}
}

private struct RetryAllowAuthority: AgentEffectAuthority {
    let value: AgentLibraryAuthorization
    func authorization(for proposal: AgentToolProposal, context: AgentToolContext) async throws -> AgentLibraryAuthorization { value }
    func validate(_ authorization: AgentLibraryAuthorization, proposal: AgentToolProposal, context: AgentToolContext) async throws {}
}

private struct RetryAllowAuthorizer: AgentSourceAuthorizer {
    func validate(_ sources: [AgentSourceReference], for request: AgentContextRequest) async throws {}
}

private struct RetryNoopBusiness: AgentBusinessEffects {
    func fenceExecution(sessionID: ConversationID, executionID: ExecutionID) async throws {}
    func commit(_ proof: AgentEffectProof) async -> AgentBusinessCommitOutcome { .notCommitted(.init(.unsupported, "No business effects in retry tests.")) }
    func receipt(for proof: AgentEffectProof) async -> AgentBusinessReceiptLookup { .absent }
    func unpublished(after receiptID: UUID?, limit: Int) async throws -> [AgentReceiptPublication] { [] }
    func acknowledge(_ receipt: AgentBusinessReceiptReference, at cursor: SessionCursor) async throws {}
}

private final class RetryFixture: Sendable {
    let directory: URL
    let library: FileSessionLibrary
    let runtime: SessionRuntime
    let executionID: ExecutionID
    let runtimeID: UUID
    let probe: RetryProbe
    let toolProbe: RetryToolProbe
    let clock: RetryClock
    let catalog: AgentRuntimeCatalog
    let scope: RuntimeScope
    let scheduler: RuntimeScheduler
    let kernel: AgentExecutionKernel
    let libraryAccessFixture: LibraryAccessFixture

    struct Reopened: Sendable {
        let state: SessionState
        let batches: [SessionBatch]
    }

    static func make(behaviors: [RetryBehavior], includeTool: Bool = false,
                     limits: AgentExecutionLimits = .init(modelTimeoutMilliseconds: 60_000, executionTimeoutMilliseconds: 60_000,
                         modelRetryPolicy: .init(maximumAttempts: 3, initialDelayMilliseconds: 500, maximumDelayMilliseconds: 5_000))) async throws -> RetryFixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mira-model-retry-\(UUID().uuidString)")
        let library = try FileSessionLibrary(directory: directory)
        var environment = RuntimeEnvironment()
        let clock = RetryClock()
        environment.clock = clock
        var cleanupRuntime: SessionRuntime?
        var cleanupScope: RuntimeScope?
        var cleanupCatalog: AgentRuntimeCatalog?
        var cleanupSnapshot: RuntimeRegistrySnapshot<AgentCapability>?
        var cleanupAccessFixture: LibraryAccessFixture?
        do {
            let sessionID = ConversationID(), executionID = ExecutionID(), runtimeID = UUID()
            let runtime = try await SessionRuntime.open(id: sessionID, journal: library, payloads: library, environment: environment)
            cleanupRuntime = runtime
            let probe = RetryProbe(behaviors: behaviors), toolProbe = RetryToolProbe()
            let scope = RuntimeScope(kind: .application)
            cleanupScope = scope
            let registry = RuntimeRegistry<AgentCapability>()
            try await registry.register(id: "model", value: .model(RetryModelAdapter(probe: probe)), scope: scope)
            if includeTool {
                let descriptor = AgentToolDescriptor(
                    definition: .init(name: "retry.read", description: "A deterministic read tool",
                        inputSchema: .object(["type": .string("object"), "properties": .object([:]), "additionalProperties": .bool(false)])),
                    revision: 1,
                    outputSchema: .object(["type": .string("object"), "properties": .object(["ok": .object(["type": .string("boolean")])]), "required": .array([.string("ok")]), "additionalProperties": .bool(false)]),
                    executionMode: .exclusive, timeoutMilliseconds: 1_000, maximumResultBytes: 1_024)
                try await registry.register(id: "tool", value: .tool(.read(RetryReadTool(descriptor: descriptor, probe: toolProbe))), scope: scope)
            }
            try await registry.register(id: "driver", value: .driver(DefaultAgentDriver()), scope: scope)
            let snapshot = try await registry.freeze()
            cleanupSnapshot = snapshot
            let catalog = try AgentRuntimeCatalog(snapshot: snapshot)
            cleanupCatalog = catalog
            cleanupSnapshot = nil
            let route = AgentModelRoute(id: RouteID(), revision: 1, connectionID: ConnectionID(), connectionRevision: 1,
                modelDescriptorID: ModelDescriptorID(), modelRevision: 1, modelAuthorizationRevision: 1, adapter: .init(id: "retry.synthetic", revision: 1),
                invocationID: "test-invocation", invocationRevision: 1, endpointID: "test-endpoint", modelID: "synthetic", credential: nil, contextWindow: 4_096, maximumOutputTokens: 128,
                capabilities: .init(streamsText: true, callsTools: includeTool, producesThinking: true), configuration: .object([:]))
            let plan = AgentExecutionPlan(runtimeID: runtimeID, catalogGeneration: catalog.generation, driverID: "mira.default",
                driverRevision: 1, instructions: "Answer.", limits: limits, priority: .foreground, route: route)
            let admission = await runtime.commit(id: UUID()) { context in
                let title = try await context.stageBytes(Data("Retry test".utf8), kind: .title)
                let user = try await context.stageBytes(Data("Question".utf8), kind: .userText)
                let planReference = try await context.stage(plan, kind: .executionPlan)
                return [.opened(.init(workspaceID: nil, title: title)),
                    .admitted(.init(executionID: executionID, userMessageID: MessageID(), userBody: user,
                        plan: planReference, hasModelRoute: true, authorizationEpoch: 0, timeZoneIdentifier: "UTC"))]
            }
            guard case .committed = admission else { throw MiraError(.storage, "Retry fixture admission failed.") }
            let scheduler = RuntimeScheduler()
            let accessFixture = try await LibraryAccessFixture.make()
            cleanupAccessFixture = accessFixture
            let libraryLease = try await accessFixture.acquire()
            let kernel = try await AgentExecutionKernel(runtime: runtime, journal: library, payloads: library,
                libraryLease: libraryLease,
                executionID: executionID, runtimeID: runtimeID, catalog: catalog, policy: RetryAllowPolicy(),
                authority: RetryAllowAuthority(value: libraryLease.authorization), business: RetryNoopBusiness(), authorizer: RetryAllowAuthorizer(),
                approvals: RuntimeApprovalService(environment: environment), scheduler: scheduler, environment: environment)
            return .init(directory: directory, library: library, runtime: runtime, executionID: executionID, runtimeID: runtimeID,
                probe: probe, toolProbe: toolProbe, clock: clock, catalog: catalog, scope: scope, scheduler: scheduler, kernel: kernel,
                libraryAccessFixture: accessFixture)
        } catch {
            await cleanupSnapshot?.release()
            await cleanupCatalog?.release()
            await cleanupScope?.dispose()
            await cleanupRuntime?.close()
            await cleanupAccessFixture?.close()
            try? await library.close()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private init(directory: URL, library: FileSessionLibrary, runtime: SessionRuntime, executionID: ExecutionID, runtimeID: UUID,
                 probe: RetryProbe, toolProbe: RetryToolProbe, clock: RetryClock, catalog: AgentRuntimeCatalog,
                 scope: RuntimeScope, scheduler: RuntimeScheduler, kernel: AgentExecutionKernel,
                 libraryAccessFixture: LibraryAccessFixture) {
        self.directory = directory; self.library = library; self.runtime = runtime; self.executionID = executionID; self.runtimeID = runtimeID
        self.probe = probe; self.toolProbe = toolProbe; self.clock = clock; self.catalog = catalog; self.scope = scope; self.scheduler = scheduler; self.kernel = kernel
        self.libraryAccessFixture = libraryAccessFixture
    }

    func shutdown() async {
        _ = await kernel.shutdown()
        await libraryAccessFixture.close()
        await scheduler.shutdown()
        await runtime.close()
        await catalog.release()
        await scope.dispose()
        try? await library.close()
        try? FileManager.default.removeItem(at: directory)
    }

    func reopen() async throws -> Reopened {
        _ = await kernel.shutdown()
        await libraryAccessFixture.close()
        await scheduler.shutdown()
        let stateBeforeClose = await runtime.snapshot()
        await runtime.close()
        await catalog.release()
        await scope.dispose()
        try await library.close()
        let reopenedLibrary = try FileSessionLibrary(directory: directory)
        var openedRuntime: SessionRuntime?
        do {
            let reopenedRuntime = try await SessionRuntime.open(id: stateBeforeClose.id,
                journal: reopenedLibrary, payloads: reopenedLibrary)
            openedRuntime = reopenedRuntime
            let state = await reopenedRuntime.snapshot()
            let batches = try await reopenedLibrary.read(sessionID: state.id, after: 0,
                limit: SessionFormatLimits.maximumReadBatches)
            await reopenedRuntime.close()
            try await reopenedLibrary.close()
            return .init(state: state, batches: batches)
        } catch {
            await openedRuntime?.close()
            try? await reopenedLibrary.close()
            throw error
        }
    }
}
