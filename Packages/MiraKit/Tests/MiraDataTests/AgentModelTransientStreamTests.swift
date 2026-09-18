import Foundation
import Testing
@testable import MiraCore
@testable import MiraData

@Suite("Process-local model stream", .timeLimit(.minutes(1)))
struct AgentModelTransientStreamTests {
    @Test func pausedStreamHasNoDurableStreamingWrites() async throws {
        let fixture = try await TransientStreamFixture.make()
        let task = Task { try await fixture.execute() }
        do {
            await fixture.probe.waitUntilDispatched()
            _ = try await fixture.waitForProcessLocalPrefix()
            let before = try await fixture.journal.read(sessionID: fixture.sessionID, after: 0,
                                                         limit: SessionFormatLimits.maximumReadBatches)
            try await Task.sleep(for: .milliseconds(650))
            let after = try await fixture.journal.read(sessionID: fixture.sessionID, after: 0,
                                                        limit: SessionFormatLimits.maximumReadBatches)
            #expect(after == before)

            task.cancel()
            do { _ = try await task.value; Issue.record("A cancelled paused stream completed") }
            catch { #expect(error is CancellationError || (error as? MiraError)?.code == .cancelled) }
            await fixture.probe.waitUntilDrained()
            #expect(await fixture.executor.interruptedAttempts()[fixture.attemptID]?.output?.text == "partial answer")
        } catch {
            task.cancel(); _ = try? await task.value
            await fixture.close()
            throw error
        }
    }

    @Test func orderlyCancellationRetainsPartialOutputAndStreamInMemory() async throws {
        let fixture = try await TransientStreamFixture.make()
        let task = Task { try await fixture.execute() }
        do {
            await fixture.probe.waitUntilDispatched()
            let prefix = try await fixture.waitForProcessLocalPrefix()
            #expect(prefix.output?.text == "partial answer")
            #expect(prefix.output?.thinkingText == "partial thinking")
            #expect(prefix.output?.continuation?.isComplete == false)
            #expect(!prefix.stream.isEmpty)
            task.cancel()
            _ = try? await task.value
            await fixture.probe.waitUntilDrained()
            let recovered = await fixture.executor.interruptedAttempts()
            let retained = try #require(recovered[fixture.attemptID])
            #expect(retained.output == prefix.output)
            #expect(retained.stream.count == prefix.stream.count + 1)
            #expect(Array(retained.stream.dropLast()) == prefix.stream)
            let endedAborted: Bool
            if let last = retained.stream.last, case .chunk(_, let chunk) = last {
                if case .finish(let reason, _) = chunk {
                    endedAborted = if case .aborted = reason { true } else { false }
                } else {
                    endedAborted = false
                }
            } else {
                endedAborted = false
            }
            #expect(endedAborted)
            #expect(await fixture.runtime.snapshot().attempts[fixture.attemptID]?.resolution == nil)
        } catch {
            task.cancel(); _ = await task.result; await fixture.close(); throw error
        }
        await fixture.close()
    }
}

private final class TransientStreamFixture: Sendable {
    let directory: URL
    let journal: any SessionJournal
    let payloads: any SessionContentReader
    let runtime: SessionRuntime
    let scheduler: RuntimeScheduler
    let executor: AgentModelExecutor
    let adapter: TransientStreamAdapter
    let probe: TransientStreamProbe
    let sessionID: ConversationID
    let executionID: ExecutionID
    let attemptID: UUID
    let request: AgentContextRequest
    let build: AgentContextBuild
    let route: AgentModelRoute
    let tools: [String: SessionEffectKind]
    let authority: TransientStreamAuthority
    let libraryAccessFixture: LibraryAccessFixture

    static func make(environment: RuntimeEnvironment = .init()) async throws -> Self {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mira-model-transient-stream-\(UUID().uuidString)")
        let library = try FileSessionLibrary(directory: directory)
        var runtime: SessionRuntime?
        var accessFixture: LibraryAccessFixture?
        do {
            let sessionID = ConversationID(), executionID = ExecutionID(), attemptID = UUID()
            let journal: any SessionJournal = library
            let payloads: any SessionContentStore = library
            let opened = try await SessionRuntime.open(id: sessionID, journal: journal, payloads: payloads)
            runtime = opened
            let route = AgentModelRoute(id: RouteID(), revision: 1, connectionID: ConnectionID(), connectionRevision: 1,
                modelDescriptorID: ModelDescriptorID(), modelRevision: 1, modelAuthorizationRevision: 1, adapter: .init(id: "synthetic.transient-stream", revision: 1),
                invocationID: "test-invocation", invocationRevision: 1, endpointID: "test-endpoint", modelID: "fixture", credential: nil, contextWindow: 4_096, maximumOutputTokens: 512,
                capabilities: .init(streamsText: true, callsTools: false, producesThinking: true), configuration: .object([:]))
            try AgentDurabilityFailure.requireCommitted(await opened.commit(id: UUID()) { context in
                let title = try await context.stageBytes(Data("Transient stream fixture".utf8), kind: .title)
                let user = try await context.stageBytes(Data("Question".utf8), kind: .userText)
                let plan = try await context.stage(AgentExecutionPlan(runtimeID: UUID(), catalogGeneration: 1,
                    driverID: "mira.default", driverRevision: 1, instructions: "Answer the user.", limits: .init(),
                    priority: .foreground, route: route), kind: .executionPlan)
                return [.opened(.init(workspaceID: nil, title: title)),
                        .admitted(.init(executionID: executionID, userMessageID: MessageID(), userBody: user,
                            plan: plan, hasModelRoute: true, authorizationEpoch: 0, timeZoneIdentifier: "UTC"))]
            })
            let scheduler = RuntimeScheduler(modelCapacity: 1, backgroundCapacity: 0)
            let openedAccessFixture = try await LibraryAccessFixture.make()
            accessFixture = openedAccessFixture
            let libraryLease = try await openedAccessFixture.acquire()
            let probe = TransientStreamProbe()
            let authority = TransientStreamAuthority()
            let adapter = TransientStreamAdapter(identity: route.adapter, probe: probe)
            let request = AgentContextRequest(sessionID: sessionID, executionID: executionID, workspaceID: nil,
                userText: "Question", authorizationEpoch: 0, destination: .model(route))
            let input = AgentModelInput(stepID: UUID(), executionID: executionID, instructions: "Answer the user.",
                messages: [.init(role: .user, blocks: [.init(id: "text", content: .text("Question"))])], tools: [])
            let build = AgentContextBuild(request: request, prepared: try adapter.prepare(input, route: route),
                inheritedSources: [], evidence: [], omissions: [])
            return .init(directory: directory, journal: journal, payloads: payloads, runtime: opened,
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

    private init(directory: URL, journal: any SessionJournal, payloads: any SessionContentReader, runtime: SessionRuntime,
                 scheduler: RuntimeScheduler, executor: AgentModelExecutor, adapter: TransientStreamAdapter,
                 probe: TransientStreamProbe, sessionID: ConversationID, executionID: ExecutionID, attemptID: UUID,
                 request: AgentContextRequest, build: AgentContextBuild, route: AgentModelRoute,
                 tools: [String: SessionEffectKind], authority: TransientStreamAuthority, libraryAccessFixture: LibraryAccessFixture) {
        self.directory = directory; self.journal = journal; self.payloads = payloads; self.runtime = runtime
        self.scheduler = scheduler; self.executor = executor; self.adapter = adapter; self.probe = probe
        self.sessionID = sessionID; self.executionID = executionID; self.attemptID = attemptID
        self.request = request; self.build = build; self.route = route; self.tools = tools; self.authority = authority; self.libraryAccessFixture = libraryAccessFixture
    }

    func execute() async throws -> AgentModelStepResult {
        try await executor.execute(stepIndex: 1, attemptID: attemptID, build: build, request: request, route: route,
            adapter: adapter, toolEffects: tools, authorizer: authority, priority: .foreground)
    }

    func waitForProcessLocalPrefix() async throws -> AgentRecoveredAttempt {
        for _ in 0..<200 {
            if let prefix = await executor.interruptedAttempts()[attemptID], prefix.output != nil {
                return prefix
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw MiraError(.timeout, "The model stream did not produce a process-local prefix within the test bound.")
    }

    func close() async {
        await scheduler.shutdown()
        await runtime.close(); await libraryAccessFixture.close(); try? await journal.close(); try? FileManager.default.removeItem(at: directory)
    }
}

private actor TransientStreamProbe {
    private(set) var count = 0
    private(set) var drained = false
    private var dispatchWaiters: [CheckedContinuation<Void, Never>] = []
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    func dispatched() { count += 1; dispatchWaiters.forEach { $0.resume() }; dispatchWaiters.removeAll() }
    func drainedNow() { drained = true; drainWaiters.forEach { $0.resume() }; drainWaiters.removeAll() }
    func waitUntilDispatched() async { if count == 0 { await withCheckedContinuation { dispatchWaiters.append($0) } } }
    func waitUntilDrained() async { if !drained { await withCheckedContinuation { drainWaiters.append($0) } } }
}

private actor TransientStreamGate {
    private var open = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async {
        if open { return }
        await withCheckedContinuation { waiter = $0; if open { waiter?.resume(); waiter = nil } }
    }
    func release() { open = true; waiter?.resume(); waiter = nil }
}

private struct TransientStreamAdapter: AgentModelAdapter {
    let identity: AgentAdapterIdentity
    let probe: TransientStreamProbe
    func prepare(_ input: AgentModelInput, route: AgentModelRoute) throws -> AgentPreparedModelRequest {
        .init(adapter: identity, input: input, wirePayload: .object(["fixture": .bool(true)]), estimatedInputTokens: 32)
    }
    func stream(_ request: AgentPreparedModelRequest, route: AgentModelRoute) -> AgentModelOperation {
        let (events, continuation) = AsyncThrowingStream<AgentModelStreamEvent, any Error>.makeStream()
        let gate = TransientStreamGate()
        let worker = Task {
            await probe.dispatched()
            continuation.yield(.blockStarted(.init(id: "text", content: .text("partial answer"))))
            continuation.yield(.blockStarted(.init(id: "thinking", content: .thinking("partial thinking"))))
            continuation.yield(.continuation(.init(adapter: identity,
                format: "synthetic.transient-stream", payload: .object(["opaque": .string("transient-stream-proof")]), isComplete: false)))
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

private struct TransientStreamAuthority: AgentSourceAuthorizer {
    func validate(_ sources: [AgentSourceReference], for request: AgentContextRequest) async throws {}
}
