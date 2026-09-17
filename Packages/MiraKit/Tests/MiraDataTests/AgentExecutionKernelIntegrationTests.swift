import Foundation
import Testing
@testable import MiraCore
@testable import MiraData

@Suite("Agent execution kernel integration")
struct AgentExecutionKernelIntegrationTests {
    @Test func actualKernelWritesReadableEventsAndReopensTheSameState() async throws {
        let fixture = try await KernelFixture.make(outputs: [.read, .complete], driverID: "mira.default")
        try await withKernelFixture(fixture) { fixture in
            let kernel = try await fixture.kernel()
            guard case .committed = await kernel.run() else { Issue.record("The example did not settle"); return }
            let state = await fixture.runtime.snapshot()
            let url = fixture.directory.appendingPathComponent("sessions/\(fixture.sessionID.rawValue.uuidString).jsonl")
            let bytes = try Data(contentsOf: url)
            let rows = try bytes.split(separator: 10).map {
                try #require(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any])
            }
            let types = Set(rows.compactMap { $0["type"] as? String })
            #expect(types.isSuperset(of: ["session", "turn/start", "request/start", "assistant/message",
                                         "tool/call", "tool/result", "turn/end", "transaction_commit"]))
            #expect(rows.allSatisfy { $0["record"] == nil && $0["payloads"] == nil })
            let requestRows = rows.filter { $0["type"] as? String == "request/start" }
            #expect(requestRows.count == 2)
            for row in requestRows {
                let payload = try #require(row["payload"] as? [String: Any])
                let node = try #require(payload["request"] as? [String: Any])
                let request = try #require(node["json"] as? [String: Any])
                #expect(request["header"] is [String: Any])
                #expect(request["entries"] is [Any])
                #expect(request["wirePayload"] == nil && request["prepared"] == nil && request["input"] == nil)
            }
            // Synthetic data only; this opt-in artifact is useful for inspecting
            // the actual runtime output without publishing personal conversations.
            if let sample = ProcessInfo.processInfo.environment["MIRA_TYPED_JOURNAL_SAMPLE"] {
                try bytes.write(to: URL(fileURLWithPath: sample))
            }
            _ = await kernel.shutdown()
            await fixture.runtime.close()
            try await fixture.library.close()
            let reopenedLibrary = try FileSessionLibrary(directory: fixture.directory)
            do {
                let reopened = try await SessionRuntime.open(id: fixture.sessionID, journal: reopenedLibrary, payloads: reopenedLibrary)
                #expect(await reopened.snapshot() == state)
                await reopened.close()
                try await reopenedLibrary.close()
            } catch { try? await reopenedLibrary.close(); throw error }
        }
    }

    @Test func admittedPlanCannotRunInAnotherApplicationRuntime() async throws {
        let fixture = try await KernelFixture.make(outputs: [.complete])
        try await withKernelFixture(fixture) { fixture in
            await #expect(throws: MiraError.self) { try await fixture.kernel(runtimeID: UUID()) }
            #expect(await fixture.modelProbe.dispatchCount == 0)
            #expect(await fixture.runtime.snapshot().executions[fixture.executionID]?.completion == nil)
        }
    }

    @Test func closedSessionCannotBeReportedAsSuccessfulKernelSettlement() async throws {
        let fixture = try await KernelFixture.make(outputs: [.complete])
        try await withKernelFixture(fixture) { fixture in
            let kernel = try await fixture.kernel()
            await fixture.runtime.close()
            guard case .notCommitted(let error) = await kernel.run() else {
                Issue.record("Closing a session was reported as committed settlement"); return
            }
            #expect(error.code == .interrupted)
            #expect(await fixture.runtime.snapshot().executions[fixture.executionID]?.completion == nil)
            #expect(await fixture.modelProbe.dispatchCount == 0)
        }
    }

    @Test func duplicateToolCallAcrossStepsFailsBeforeSecondToolDispatch() async throws {
        let fixture = try await KernelFixture.make(outputs: [.read, .read, .complete], driverID: "mira.default")
        try await withKernelFixture(fixture) { fixture in
            let kernel = try await fixture.kernel()
            guard case .committed = await kernel.run() else { Issue.record("Duplicate tool call did not settle"); return }
            #expect((await fixture.runtime.snapshot()).executions[fixture.executionID]?.completion?.status == .failed)
            #expect(await fixture.modelProbe.dispatchCount == 2)
            #expect(await fixture.toolProbe.executeCount == 1)
        }
    }

    @Test func truncatedModelAnswerSettlesAsFailureWithVisiblePartialText() async throws {
        let fixture = try await KernelFixture.make(outputs: [.truncated], driverID: "mira.default")
        try await withKernelFixture(fixture) { fixture in
            let kernel = try await fixture.kernel()
            guard case .committed = await kernel.run() else { Issue.record("Truncated output did not settle"); return }
            let completion = try #require((await fixture.runtime.snapshot()).executions[fixture.executionID]?.completion)
            #expect(completion.status == .failed && completion.replay == nil)
            #expect(try await fixture.library.read(#require(completion.answer)) == Data("partial".utf8))
            let error = try SessionCodec.decode(MiraError.self, from: await fixture.library.read(#require(completion.error)))
            #expect(error.code == .outputLimit)
            #expect(await fixture.modelProbe.dispatchCount == 1)
        }
    }

    @Test func defaultDriverRunsModelReadModelAndReopensTerminalState() async throws {
        let fixture = try await KernelFixture.make(outputs: [.read, .complete], driverID: "mira.default")
        try await withKernelFixture(fixture) { fixture in
            let kernel = try await fixture.kernel()
            let result = await kernel.run()
            guard case .committed = result else { Issue.record("Default execution did not commit: \(result)"); return }
            let state = await fixture.runtime.snapshot()
            #expect(state.executions[fixture.executionID]?.completion?.status == .completed)
            #expect(await fixture.toolProbe.executeCount == 1)

            _ = await kernel.shutdown()
            await fixture.runtime.close()
            try await fixture.library.close()
            let reopenedLibrary = try FileSessionLibrary(directory: fixture.directory)
            do {
                let reopened = try await SessionRuntime.open(id: fixture.sessionID, journal: reopenedLibrary, payloads: reopenedLibrary)
                #expect(await reopened.snapshot() == state)
                await reopened.close()
                try await reopenedLibrary.close()
            } catch {
                try? await reopenedLibrary.close()
                throw error
            }
        }
    }

    @Test func customDriverReturningCompleteWithoutModelPersistsFailure() async throws {
        let fixture = try await KernelFixture.make(outputs: [], driverID: "stop.now")
        try await withKernelFixture(fixture) { fixture in
            let kernel = try await fixture.kernel()
            let result = await kernel.run()
            guard case .committed = result else { Issue.record("Driver failure did not settle: \(result)"); return }
            #expect(await fixture.runtime.snapshot().executions[fixture.executionID]?.completion?.status == .failed)
        }
    }

    @Test func modelStepBudgetFailureSettlesAndRejectsFurtherOperations() async throws {
        let fixture = try await KernelFixture.make(outputs: [.read, .complete], driverID: "budget.catch", limits: .init(maximumSteps: 1))
        try await withKernelFixture(fixture) { fixture in
            let kernel = try await fixture.kernel()
            let result = await kernel.run()
            guard case .committed = result else { Issue.record("Budget failure did not settle: \(result)"); return }
            #expect(await fixture.runtime.snapshot().executions[fixture.executionID]?.completion?.status == .failed)
            #expect(await fixture.budgetProbe.budgetRejected)
            #expect(await fixture.budgetProbe.latchRejected)
        }
    }

    @Test func localRespondCompletesWithoutModelAndReopensWithAnswer() async throws {
        let fixture = try await KernelFixture.make(outputs: [], hasModelRoute: false, driverID: "local.respond")
        try await withKernelFixture(fixture) { fixture in
            let kernel = try await fixture.kernel()
            let result = await kernel.run()
            guard case .committed = result else { Issue.record("Local response did not commit: \(result)"); return }
            let completion = try #require((await fixture.runtime.snapshot()).executions[fixture.executionID]?.completion)
            let answer = try #require(completion.answer)
            #expect(completion.status == .completed)
            #expect(String(data: try await fixture.library.read(answer), encoding: .utf8) == "Question local")
            #expect(await fixture.modelProbe.dispatchCount == 0)
            let state = await fixture.runtime.snapshot()
            #expect(state.executions[fixture.executionID]?.attemptIDs.isEmpty == true)
            #expect(completion.replay != nil)
            _ = await kernel.shutdown()
            await fixture.runtime.close(); try await fixture.library.close()
            let reopenedLibrary = try FileSessionLibrary(directory: fixture.directory)
            do {
                let reopened = try await SessionRuntime.open(id: fixture.sessionID, journal: reopenedLibrary, payloads: reopenedLibrary)
                let reopenedCompletion = try #require((await reopened.snapshot()).executions[fixture.executionID]?.completion)
                #expect(await reopened.snapshot() == state)
                let reopenedAnswer = try #require(reopenedCompletion.answer)
                #expect(String(data: try await reopenedLibrary.read(reopenedAnswer), encoding: .utf8) == "Question local")
                await reopened.close(); try await reopenedLibrary.close()
            } catch { try? await reopenedLibrary.close(); throw error }
        }
    }

    @Test func defaultDriverWithoutRouteFailsWithoutModelDispatch() async throws {
        let fixture = try await KernelFixture.make(outputs: [], hasModelRoute: false, driverID: "mira.default")
        try await withKernelFixture(fixture) { fixture in
            let kernel = try await fixture.kernel()
            let result = await kernel.run()
            guard case .committed = result else { Issue.record("Missing-route failure did not settle: \(result)"); return }
            #expect((await fixture.runtime.snapshot()).executions[fixture.executionID]?.completion?.status == .failed)
            #expect(await fixture.modelProbe.dispatchCount == 0)
        }
    }

    @Test func indeterminateTerminalCommitRetriesWithoutRedispatch() async throws {
        let fixture = try await KernelFixture.make(outputs: [.read, .complete], driverID: "mira.default", journalFault: .indeterminateTerminal)
        try await withKernelFixture(fixture) { fixture in
            let kernel = try await fixture.kernel()
            let first = await kernel.run()
            guard case .indeterminate = first else { Issue.record("Expected terminal uncertainty: \(first)"); return }
            let modelCalls = await fixture.modelProbe.dispatchCount
            let toolCalls = await fixture.toolProbe.executeCount
            let disposing = Task { await fixture.scope.dispose() }
            await fixture.scopeProbe.waitUntilClosing()
            #expect(await fixture.scopeProbe.completed == false)
            let retry = await kernel.retrySettlement()
            if case .committed = retry {} else {
                Issue.record("Uncertainty did not reconcile: \(retry)")
                _ = await kernel.shutdown()
            }
            #expect(await fixture.modelProbe.dispatchCount == modelCalls)
            #expect(await fixture.toolProbe.executeCount == toolCalls)
            #expect(await kernel.retrySettlement() == retry)
            #expect((await fixture.runtime.snapshot()).executions[fixture.executionID]?.completion?.status == .completed)
            #expect(Set(await fixture.journal.terminalBatchIDs).count == 1)
            await disposing.value
            #expect(await fixture.scopeProbe.completed)
        }
    }

    @Test func terminalNotCommittedRetriesWithoutRedispatch() async throws {
        let fixture = try await KernelFixture.make(outputs: [.read, .complete], driverID: "mira.default", journalFault: .notCommittedTerminal)
        try await withKernelFixture(fixture) { fixture in
            let kernel = try await fixture.kernel()
            let first = await kernel.run()
            guard case .notCommitted = first else { Issue.record("Expected terminal rejection: \(first)"); return }
            let modelCalls = await fixture.modelProbe.dispatchCount
            let toolCalls = await fixture.toolProbe.executeCount
            let retry = await kernel.retrySettlement()
            guard case .committed = retry else { Issue.record("Rejected terminal did not settle: \(retry)"); return }
            #expect(await fixture.modelProbe.dispatchCount == modelCalls)
            #expect(await fixture.toolProbe.executeCount == toolCalls)
            #expect(await kernel.retrySettlement() == retry)
            #expect((await fixture.runtime.snapshot()).executions[fixture.executionID]?.completion?.status == .completed)
            let ids = await fixture.journal.terminalBatchIDs
            #expect(ids.count == 2 && Set(ids).count == 1)
        }
    }

    @Test func cancelledExecutionRetainedContextCannotExecute() async throws {
        let fixture = try await KernelFixture.make(outputs: [.read], driverID: "hold.driver")
        try await withKernelFixture(fixture) { fixture in
            let kernel = try await fixture.kernel()
            let running = Task { await kernel.run() }
            await fixture.driverProbe.waitUntilEntered()
            await kernel.cancel()
            await fixture.driverProbe.release()
            _ = await running.value
            guard let context = await fixture.driverProbe.context else { Issue.record("Driver did not retain context"); return }
            await #expect(throws: Error.self) { _ = try await context.modelStep() }
        }
    }

    @Test func replaySourcesAccumulateExecutionProvenanceAcrossThreeTurnsAndReopen() async throws {
        let fixture = try await KernelFixture.make(outputs: [.complete, .complete, .complete])
        try await withKernelFixture(fixture) { fixture in
            let first = try await fixture.kernel()
            guard case .committed = await first.run() else { Issue.record("First execution did not commit"); return }
            _ = await first.shutdown()
            let firstSource = AgentSourceReference.sessionExecution(sessionID: fixture.sessionID, executionID: fixture.executionID)
            let secondID = try await fixture.admitNext()
            let second = try await fixture.kernel(executionID: secondID)
            guard case .committed = await second.run() else { Issue.record("Second execution did not commit"); return }
            _ = await second.shutdown()
            let thirdID = try await fixture.admitNext()
            let third = try await fixture.kernel(executionID: thirdID)
            guard case .committed = await third.run() else { Issue.record("Third execution did not commit"); return }
            _ = await third.shutdown()

            let state = await fixture.runtime.snapshot()
            let secondReplay = try #require(state.executions[secondID]?.completion?.replay)
            let secondValue = try await AgentReplayManifest.read(secondReplay, state: state, payloads: fixture.library)
            #expect(secondValue.sources == [firstSource])
            let secondSource = AgentSourceReference.sessionExecution(sessionID: fixture.sessionID, executionID: secondID)
            let thirdReplay = try #require(state.executions[thirdID]?.completion?.replay)
            let thirdValue = try await AgentReplayManifest.read(thirdReplay, state: state, payloads: fixture.library)
            #expect(Set(thirdValue.sources) == Set([firstSource, secondSource]))
            let thirdExecution = try #require(state.executions[thirdID])
            #expect(thirdExecution.completion?.status == .completed)
            #expect(thirdExecution.attemptIDs.count == 1)
            let attemptID = try #require(thirdExecution.attemptIDs.first)
            let attempt = try #require(state.attempts[attemptID])
            let request = try await AgentRequestRecord.read(attempt.attempt.request, payloads: fixture.library)
            #expect(Set(request.inheritedSources) == Set([firstSource, secondSource]))
            #expect(request.sources == thirdValue.sources)
            #expect(request.request.executionID == thirdID)
            #expect(await fixture.modelProbe.dispatchCount == 3)

            await fixture.runtime.close(); try await fixture.library.close()
            let reopenedLibrary = try FileSessionLibrary(directory: fixture.directory)
            var reopenedRuntime: SessionRuntime?
            do {
                let reopened = try await SessionRuntime.open(id: fixture.sessionID, journal: reopenedLibrary, payloads: reopenedLibrary)
                reopenedRuntime = reopened
                let reopenedState = await reopened.snapshot()
                let reopenedSecond = try #require(reopenedState.executions[secondID]?.completion?.replay)
                let reopenedThird = try #require(reopenedState.executions[thirdID]?.completion?.replay)
                let secondAfter = try await AgentReplayManifest.read(reopenedSecond, state: reopenedState, payloads: reopenedLibrary)
                let thirdAfter = try await AgentReplayManifest.read(reopenedThird, state: reopenedState, payloads: reopenedLibrary)
                #expect(secondAfter.sources == [firstSource])
                #expect(Set(thirdAfter.sources) == Set([firstSource, secondSource]))
                let requestAfter = try await AgentRequestRecord.read(attempt.attempt.request, payloads: reopenedLibrary)
                #expect(requestAfter == request)
                await reopened.close(); try await reopenedLibrary.close()
            } catch { await reopenedRuntime?.close(); try? await reopenedLibrary.close(); throw error }
        }
    }

    @Test func optionalContributorIsCollectedOncePerStepAcrossHistoryTrimming() async throws {
        let contributor = CountingContributor()
        let fixture = try await KernelFixture.make(outputs: [.complete, .complete, .complete], maximumPreparedMessages: 4, contributors: [contributor])
        try await withKernelFixture(fixture) { fixture in
            let first = try await fixture.kernel()
            guard case .committed = await first.run() else { Issue.record("First execution did not commit"); return }
            _ = await first.shutdown()
            let secondID = try await fixture.admitNext()
            let second = try await fixture.kernel(executionID: secondID)
            guard case .committed = await second.run() else { Issue.record("Second execution did not commit"); return }
            _ = await second.shutdown()
            let thirdID = try await fixture.admitNext()
            let third = try await fixture.kernel(executionID: thirdID)
            guard case .committed = await third.run() else { Issue.record("Third execution did not commit"); return }
            #expect(await contributor.count == 3)
            let thirdState = await fixture.runtime.snapshot()
            let thirdAttemptID = try #require(thirdState.executions[thirdID]?.attemptIDs.last)
            let thirdAttempt = try #require(thirdState.attempts[thirdAttemptID])
            let thirdBuild = try await AgentRequestRecord.read(thirdAttempt.attempt.request, payloads: fixture.library)
            let firstSource = AgentSourceReference.sessionExecution(sessionID: fixture.sessionID, executionID: fixture.executionID)
            let secondSource = AgentSourceReference.sessionExecution(sessionID: fixture.sessionID, executionID: secondID)
            #expect(Set(thirdBuild.inheritedSources) == Set([firstSource, secondSource]))
            #expect(thirdBuild.omissions.isEmpty)
            #expect(thirdBuild.input.messages.contains { $0.role == .context && $0.text.contains("contribution-3") })
            #expect(thirdBuild.input.messages.count == 4)
            #expect(thirdBuild.evidence.map(\.itemID) == ["item-3"])
            #expect(thirdState.executions.values.filter { $0.completion?.status == .completed }.count == 3)
            _ = await third.shutdown()
        }
    }
}

private func withKernelFixture<T>(_ fixture: KernelFixture, _ body: (KernelFixture) async throws -> T) async throws -> T {
    do {
        let result = try await body(fixture)
        await fixture.shutdown()
        return result
    } catch {
        await fixture.shutdown()
        throw error
    }
}

private enum SyntheticOutput: Sendable { case read, complete, truncated }
private enum JournalFault: Sendable { case none, indeterminateTerminal, notCommittedTerminal }

private actor FaultJournal: SessionJournal {
    let base: any SessionJournal
    let fault: JournalFault
    private var injected = false
    private(set) var terminalBatchIDs: [UUID] = []
    init(base: any SessionJournal, fault: JournalFault) { self.base = base; self.fault = fault }
    func append(_ batch: SessionBatch) async -> SessionAppendOutcome {
        guard batch.events.contains(where: { if case .finished = $0.fact { true } else { false } }) else {
            return await base.append(batch)
        }
        terminalBatchIDs.append(batch.id)
        guard !injected else { return await base.append(batch) }
        injected = true
        switch fault {
        case .none: return await base.append(batch)
        case .indeterminateTerminal:
            let outcome = await base.append(batch)
            guard case .committed = outcome else { return outcome }
            return .indeterminate(.init(.storage, "Synthetic terminal acknowledgement was lost."))
        case .notCommittedTerminal: return .notCommitted(.init(.storage, "Synthetic terminal append was rejected."))
        }
    }
    func reconcile(_ batch: SessionBatch) async -> SessionAppendOutcome { await base.reconcile(batch) }
    func batch(id: UUID, sessionID: ConversationID) async throws -> SessionBatch? { try await base.batch(id: id, sessionID: sessionID) }
    func head(sessionID: ConversationID) async throws -> SessionJournalHead { try await base.head(sessionID: sessionID) }
    func read(sessionID: ConversationID, after sequence: Int64, limit: Int) async throws -> [SessionBatch] { try await base.read(sessionID: sessionID, after: sequence, limit: limit) }
    func sessions(after: ConversationID?, limit: Int) async throws -> [ConversationID] { try await base.sessions(after: after, limit: limit) }
    func flush() async throws { try await base.flush() }
    func close() async throws { try await base.close() }
}

private actor ModelProbe {
    var index = 0
    let outputs: [SyntheticOutput]
    init(outputs: [SyntheticOutput]) { self.outputs = outputs }
    private(set) var dispatchCount = 0
    func next() throws -> SyntheticOutput {
        guard !outputs.isEmpty else { throw MiraError(.malformedStream, "Synthetic model output was exhausted.") }
        dispatchCount += 1
        defer { index += 1 }
        return outputs[min(index, outputs.count - 1)]
    }
}

private struct KernelModel: AgentModelAdapter {
    let identity = AgentAdapterIdentity(id: "synthetic.model", revision: 1)
    let probe: ModelProbe
    let maximumMessages: Int?
    func prepare(_ input: AgentModelInput, route: AgentModelRoute) throws -> AgentPreparedModelRequest {
        if let maximumMessages, input.messages.count > maximumMessages { throw MiraError(.contextLimit, "Synthetic adapter input limit exceeded.") }
        return .init(adapter: identity, input: input, wirePayload: .object([:]), estimatedInputTokens: 1)
    }
    func stream(_ request: AgentPreparedModelRequest, route: AgentModelRoute) -> AgentModelOperation {
        let (stream, continuation) = AsyncThrowingStream<AgentModelStreamEvent, any Error>.makeStream()
        let producer = Task {
                do {
                    switch try await probe.next() {
                    case .read:
                        continuation.yield(.blockStarted(.init(id: "tool-0", content: .toolCall(.init(id: "read-1", name: "tests.read", arguments: "{}")))))
                        continuation.yield(.blockFinished(id: "tool-0"))
                        continuation.yield(.finished(.toolCalls))
                    case .complete:
                        continuation.yield(.blockStarted(.init(id: "text", content: .text("done"))))
                        continuation.yield(.blockFinished(id: "text"))
                        continuation.yield(.finished(.stop))
                    case .truncated:
                        continuation.yield(.blockStarted(.init(id: "text", content: .text("partial"))))
                        continuation.yield(.blockFinished(id: "text"))
                        continuation.yield(.finished(.outputLimit))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
        }
        return AgentModelOperation(events: stream, cancelAndDrain: {
            producer.cancel()
            _ = await producer.value
        })
    }
    func replay(_ messages: [AgentModelMessage], from source: AgentModelRoute, to target: AgentModelRoute, boundary: AgentReplayBoundary) throws -> AgentReplayDecision { .include(messages) }
}

private actor CountingContributor: AgentContextContributor {
    let id = "tests.optional"
    let isRequired = false
    private(set) var count = 0
    func contribute(to request: AgentContextRequest) async throws -> [AgentContextItem] {
        count += 1
        return [.init(id: "item-\(count)", text: "contribution-\(count)", sources: [])]
    }
}

private actor DriverProbe {
    var context: AgentRunContext?
    private var entered = false
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func retain(_ context: AgentRunContext) { self.context = context; entered = true; waiters.forEach { $0.resume() }; waiters.removeAll() }
    func waitUntilEntered() async { if !entered { await withCheckedContinuation { waiters.append($0) } } }
    func release() { released = true; waiters.forEach { $0.resume() }; waiters.removeAll() }
    func waitForRelease() async { if !released { await withCheckedContinuation { waiters.append($0) } } }
}

private struct StopDriver: AgentDriver {
    let id = "stop.now"
    let revision = 1
    func run(in context: AgentRunContext) async throws -> AgentDriverDecision { .complete }
}

private struct LocalResponseDriver: AgentDriver {
    let id = "local.respond"
    let revision = 1
    func run(in context: AgentRunContext) async throws -> AgentDriverDecision { .respond(text: context.userText + " local") }
}

private actor BudgetProbe {
    private(set) var budgetRejected = false
    private(set) var latchRejected = false
    func markBudgetRejected() { budgetRejected = true }
    func markLatchRejected() { latchRejected = true }
}

private struct BudgetCatchingDriver: AgentDriver {
    let id = "budget.catch"
    let revision = 1
    let probe: BudgetProbe
    func run(in context: AgentRunContext) async throws -> AgentDriverDecision {
        do {
            let first = try await context.modelStep()
            if first.hasToolCalls { _ = try await context.executeTools(for: first) }
            _ = try await context.modelStep()
        } catch let error as MiraError where error.code == .outputLimit {
            await probe.markBudgetRejected()
            do { _ = try await context.modelStep() }
            catch { await probe.markLatchRejected() }
        }
        return .complete
    }
}

private struct HoldingDriver: AgentDriver {
    let id = "hold.driver"
    let revision = 1
    let probe: DriverProbe
    func run(in context: AgentRunContext) async throws -> AgentDriverDecision {
        await probe.retain(context); await probe.waitForRelease(); return .complete
    }
}

private struct KernelReadTool: AgentReadTool {
    let policy: AgentToolPolicyRequirement = .hostOnly
    let descriptor: AgentToolDescriptor
    let probe: ToolProbe
    func prepare(_ arguments: JSONValue, context: AgentToolContext) async throws -> AgentToolPlan { .init(input: arguments, sources: [], targets: []) }
    func execute(_ plan: AgentToolPlan, context: AgentToolContext) async throws -> JSONValue { await probe.executed(); return .object(["ok": .bool(true)]) }
}

private actor ToolProbe {
    private(set) var executeCount = 0
    func executed() { executeCount += 1 }
}

private actor ScopeProbe {
    private(set) var completed = false
    private var closing = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func beginClosing() { closing = true; waiters.forEach { $0.resume() }; waiters.removeAll() }
    func waitUntilClosing() async {
        if !closing { await withCheckedContinuation { waiters.append($0) } }
    }
    func finish() { completed = true }
}

private actor KernelHolder {
    private var kernel: AgentExecutionKernel?
    func store(_ kernel: AgentExecutionKernel) { self.kernel = kernel }
    func shutdown() async { _ = await kernel?.shutdown(); kernel = nil }
}

private struct AllowPolicy: AgentToolPolicy {
    func evaluate(_ proposal: AgentToolProposal, context: AgentToolContext) async throws -> AgentToolPolicyDecision { .allow }
    func validate(_ proposal: AgentToolProposal, context: AgentToolContext) async throws {}
}

private struct AllowAuthority: AgentEffectAuthority {
    let value: AgentLibraryAuthorization
    func authorization(for proposal: AgentToolProposal, context: AgentToolContext) async throws -> AgentLibraryAuthorization { value }
    func validate(_ authorization: AgentLibraryAuthorization, proposal: AgentToolProposal, context: AgentToolContext) async throws {}
}

private struct AllowAuthorizer: AgentSourceAuthorizer {
    func validate(_ sources: [AgentSourceReference], for request: AgentContextRequest) async throws {}
}

private struct NoopBusiness: AgentBusinessEffects {
    func fenceExecution(sessionID: ConversationID, executionID: ExecutionID) async throws {}
    func commit(_ proof: AgentEffectProof) async -> AgentBusinessCommitOutcome { .notCommitted(.init(.unsupported, "No business effects in read-only test.")) }
    func receipt(for proof: AgentEffectProof) async -> AgentBusinessReceiptLookup { .absent }
    func unpublished(after receiptID: UUID?, limit: Int) async throws -> [AgentReceiptPublication] { [] }
    func acknowledge(_ receipt: AgentBusinessReceiptReference, at cursor: SessionCursor) async throws {}
}

private final class KernelFixture: Sendable {
    let directory: URL
    let library: FileSessionLibrary
    let journal: FaultJournal
    let runtime: SessionRuntime
    let sessionID: ConversationID
    let executionID: ExecutionID
    let modelProbe: ModelProbe
    let toolProbe: ToolProbe
    let driverProbe: DriverProbe
    let budgetProbe: BudgetProbe
    let catalog: AgentRuntimeCatalog
    let scope: RuntimeScope
    let kernelHolder: KernelHolder
    let scopeProbe: ScopeProbe
    let libraryAccessFixture: LibraryAccessFixture
    let scheduler = RuntimeScheduler()

    static func make(outputs: [SyntheticOutput], hasModelRoute: Bool = true, driverID: String = "mira.default", limits: AgentExecutionLimits = .init(), journalFault: JournalFault = .none, maximumPreparedMessages: Int? = nil, contributors: [any AgentContextContributor] = []) async throws -> KernelFixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mira-kernel-\(UUID().uuidString)")
        let library = try FileSessionLibrary(directory: directory)
        let journal = FaultJournal(base: library, fault: journalFault)
        var cleanupRuntime: SessionRuntime?
        var cleanupScope: RuntimeScope?
        var cleanupCatalog: AgentRuntimeCatalog?
        var cleanupSnapshot: RuntimeRegistrySnapshot<AgentCapability>?
        var cleanupAccessFixture: LibraryAccessFixture?
        do {
        let sessionID = ConversationID(), executionID = ExecutionID()
        let runtime = try await SessionRuntime.open(id: sessionID, journal: journal, payloads: library)
        cleanupRuntime = runtime
        let modelProbe = ModelProbe(outputs: outputs), toolProbe = ToolProbe(), driverProbe = DriverProbe(), budgetProbe = BudgetProbe()
        let scopeProbe = ScopeProbe()
        let toolDescriptor = AgentToolDescriptor(definition: .init(name: "tests.read", description: "Read test", inputSchema: .object(["type": .string("object"), "properties": .object([:]), "additionalProperties": .bool(false)])), revision: 1, outputSchema: .object(["type": .string("object"), "properties": .object(["ok": .object(["type": .string("boolean")])]), "required": .array([.string("ok")]), "additionalProperties": .bool(false)]), executionMode: .exclusive, timeoutMilliseconds: 1_000, maximumResultBytes: 1_024)
        let tool = AgentTool.read(KernelReadTool(descriptor: toolDescriptor, probe: toolProbe))
        let registry = RuntimeRegistry<AgentCapability>(), scope = RuntimeScope(kind: .application)
        _ = try await scope.registerClosing { await scopeProbe.beginClosing() }
        try await scope.registerCleanup { await scopeProbe.finish() }
        cleanupScope = scope
        if hasModelRoute { try await registry.register(id: "model", value: .model(KernelModel(probe: modelProbe, maximumMessages: maximumPreparedMessages)), scope: scope) }
        for (index, contributor) in contributors.enumerated() { try await registry.register(id: "contributor-\(index)", value: .context(contributor), scope: scope) }
        try await registry.register(id: "tool", value: .tool(tool), scope: scope)
        try await registry.register(id: "stop", value: .driver(StopDriver()), scope: scope)
        try await registry.register(id: "hold", value: .driver(HoldingDriver(probe: driverProbe)), scope: scope)
        try await registry.register(id: "default", value: .driver(DefaultAgentDriver()), scope: scope)
        try await registry.register(id: "budget", value: .driver(BudgetCatchingDriver(probe: budgetProbe)), scope: scope)
        try await registry.register(id: "local", value: .driver(LocalResponseDriver()), scope: scope)
        let snapshot = try await registry.freeze()
        cleanupSnapshot = snapshot
        let catalog = try AgentRuntimeCatalog(snapshot: snapshot)
        cleanupCatalog = catalog
        cleanupSnapshot = nil
        let plan = AgentExecutionPlan(runtimeID: UUID(), catalogGeneration: catalog.generation, driverID: driverID, driverRevision: 1, instructions: "Answer.", limits: limits, priority: .foreground, route: hasModelRoute ? AgentModelRoute(id: RouteID(), revision: 1, connectionID: ConnectionID(), connectionRevision: 1, modelDescriptorID: ModelDescriptorID(), modelRevision: 1, modelAuthorizationRevision: 1, adapter: .init(id: "synthetic.model", revision: 1), invocationID: "test-invocation", invocationRevision: 1, endpointID: "test-endpoint", metadataEvidence: [], modelID: "synthetic", credential: nil, contextWindow: 4096, maximumOutputTokens: 128, capabilities: .init(streamsText: true, callsTools: true, producesThinking: false), configuration: .object([:])) : nil)
        let admission = await runtime.commit(id: UUID()) { context in
            let title = try await context.stageBytes(Data("Synthetic".utf8), kind: .title, retentionGroup: UUID())
            let user = try await context.stageBytes(Data("Question".utf8), kind: .userText, retentionGroup: UUID())
            let planRef = try await context.stage(plan, kind: .executionPlan, retentionGroup: UUID())
            return [.opened(.init(workspaceID: nil, title: title)), .admitted(.init(executionID: executionID, userMessageID: MessageID(), userBody: user, plan: planRef, hasModelRoute: hasModelRoute, authorizationEpoch: 0, timeZoneIdentifier: "UTC"))]
        }
        guard case .committed = admission else { throw MiraError(.storage, "Kernel fixture admission failed.") }
        let accessFixture = try await LibraryAccessFixture.make()
        cleanupAccessFixture = accessFixture
        return .init(directory: directory, library: library, journal: journal, runtime: runtime, sessionID: sessionID, executionID: executionID, modelProbe: modelProbe, toolProbe: toolProbe, driverProbe: driverProbe, budgetProbe: budgetProbe, catalog: catalog, scope: scope, kernelHolder: KernelHolder(), scopeProbe: scopeProbe, libraryAccessFixture: accessFixture)
        } catch {
            await cleanupAccessFixture?.close()
            await cleanupSnapshot?.release()
            await cleanupCatalog?.release()
            await cleanupScope?.dispose()
            await cleanupRuntime?.close()
            try? await library.close()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private init(directory: URL, library: FileSessionLibrary, journal: FaultJournal, runtime: SessionRuntime, sessionID: ConversationID, executionID: ExecutionID, modelProbe: ModelProbe, toolProbe: ToolProbe, driverProbe: DriverProbe, budgetProbe: BudgetProbe, catalog: AgentRuntimeCatalog, scope: RuntimeScope, kernelHolder: KernelHolder, scopeProbe: ScopeProbe, libraryAccessFixture: LibraryAccessFixture) {
        self.directory = directory; self.library = library; self.journal = journal; self.runtime = runtime; self.sessionID = sessionID; self.executionID = executionID; self.modelProbe = modelProbe; self.toolProbe = toolProbe; self.driverProbe = driverProbe; self.budgetProbe = budgetProbe; self.catalog = catalog; self.scope = scope; self.kernelHolder = kernelHolder; self.scopeProbe = scopeProbe; self.libraryAccessFixture = libraryAccessFixture
    }

    func kernel(executionID: ExecutionID? = nil, runtimeID: UUID? = nil) async throws -> AgentExecutionKernel {
        let id = executionID ?? self.executionID
        let state = await runtime.snapshot()
        let plan = try await AgentExecutionPlan.read(for: state.executions[id]!.admission, from: library)
        let libraryLease = try await libraryAccessFixture.acquire()
        let kernel = try await AgentExecutionKernel(runtime: runtime, journal: journal, payloads: library, libraryLease: libraryLease, executionID: id, runtimeID: runtimeID ?? plan.runtimeID, catalog: catalog, policy: AllowPolicy(), authority: AllowAuthority(value: libraryLease.authorization), business: NoopBusiness(), authorizer: AllowAuthorizer(), approvals: RuntimeApprovalService(), scheduler: scheduler)
        await kernelHolder.store(kernel)
        return kernel
    }

    func admitNext() async throws -> ExecutionID {
        let executionID = ExecutionID()
        let command = await runtime.commit(id: UUID()) { context in
            let user = try await context.stageBytes(Data("Question".utf8), kind: .userText, retentionGroup: UUID())
            let state = context.state
            let plan = try await AgentExecutionPlan.read(for: state.executions[self.executionID]!.admission, from: library)
            let planRef = try await context.stage(plan, kind: .executionPlan, retentionGroup: UUID())
            return [.admitted(.init(executionID: executionID, userMessageID: MessageID(), userBody: user, plan: planRef, hasModelRoute: true, authorizationEpoch: 0, timeZoneIdentifier: "UTC"))]
        }
        guard case .committed = command else { throw MiraError(.storage, "Kernel fixture admission failed.") }
        return executionID
    }

    func shutdown() async { await kernelHolder.shutdown(); await scheduler.shutdown(); await runtime.close(); await libraryAccessFixture.close(); await catalog.release(); await scope.dispose(); try? await journal.close(); try? await library.close(); try? FileManager.default.removeItem(at: directory) }
}
