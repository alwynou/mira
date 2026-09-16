import Foundation
import Testing
@testable import MiraCore
@testable import MiraData

@Suite("Agent live output integration", .timeLimit(.minutes(1)))
struct AgentLiveOutputIntegrationTests {
    @Test func answerPhasePublishesWhileThinkingIsRetainedAndStreamIsUnfinished() async throws {
        try await withTaskWorkflow(outputs: [[
            .blockStarted(.init(id: "thought", content: .thinking("Plan"))),
            .blockStarted(.init(id: "answer", content: .text("Partial answer"))),
            .blockFinished(id: "thought"), .blockFinished(id: "answer"), .finished(.stop)
        ]], thinkingEnabled: true) { fixture in
            await fixture.model.holdStream(number: 1, afterEvents: 2)
            let address = try await submit("Question", in: fixture)
            let probe = OutputProbe()
            let observer = observe(try await fixture.runtime.observeSessionOutput(id: address.sessionID), into: probe)
            do {
                try await taskEventually { await fixture.model.streamHeld }
                try await taskEventually {
                    await probe.observations.contains {
                        $0.value?.phase == .answering && $0.value?.thinking == "Plan"
                            && $0.value?.answer == "Partial answer"
                            && $0.value?.blocks.map(\.id) == ["thought", "answer"]
                    }
                }
                #expect(try await fixture.runtime.sessionSnapshot(id: address.sessionID)
                    .executions[address.executionID]?.completion == nil)
                await fixture.model.releaseStream()
                try taskRequireCommitted(await fixture.runtime.waitForExecution(id: address.executionID, sessionID: address.sessionID))
                try await taskEventually {
                    await probe.observations.contains { $0.value == nil && $0.handoffExecutionID == address.executionID }
                }
            } catch {
                await fixture.model.releaseStream()
                observer.cancel()
                await observer.value
                throw error
            }
            observer.cancel()
            await observer.value
        }
    }
    @Test func visibleOutputCoalescesIndependentlyFromDurableDrafts() async throws {
        let clock = LiveOutputClock()
        let environment = RuntimeEnvironment(now: { TaskWorkflowFixture.now }, sleep: { duration in
            try await clock.sleep(for: duration)
        })
        try await withTaskWorkflow(
            outputs: [[
                .blockStarted(.init(id: "answer-1", content: .text("Hello"))),
                .blockFinished(id: "answer-1"),
                .blockStarted(.init(id: "reasoning", content: .thinking("Plan"))),
                .blockFinished(id: "reasoning"),
                .blockStarted(.init(id: "answer-2", content: .text(" world"))),
                .blockFinished(id: "answer-2"), .finished(.stop)
            ]], environment: environment, thinkingEnabled: true
        ) { fixture in
            await fixture.model.holdStream(number: 1, afterEvents: 4)
            let address = try await submit("Question", in: fixture)
            let stream = try await fixture.runtime.observeSessionOutput(id: address.sessionID)
            let probe = OutputProbe()
            let observer = observe(stream, into: probe)
            do {
                try await taskEventually { await fixture.model.streamHeld }
                try await taskEventually { await probe.hasValue(executionID: address.executionID, answer: "Hello", thinking: "") }
                try await taskEventually { await clock.isEntered(.visible) }
                try await taskEventually { await clock.isEntered(.durable) }

                let beforeHead = try await fixture.library.head(sessionID: address.sessionID)
                #expect(try await fixture.library.activeDraft(sessionID: address.sessionID) == nil)

                await clock.release(.visible)
                try await taskEventually { await probe.hasValue(executionID: address.executionID, answer: "Hello", thinking: "Plan") }
                #expect(try await fixture.library.head(sessionID: address.sessionID) == beforeHead)
                #expect(try await fixture.library.activeDraft(sessionID: address.sessionID) == nil)

                observer.cancel()
                await observer.value
                #expect(await fixture.model.streamHeld)

                await fixture.model.releaseStream()
                try taskRequireCommitted(await fixture.runtime.waitForExecution(id: address.executionID, sessionID: address.sessionID))
                try await taskEventually { await fixture.model.streamDrained }
                let finalState = try await fixture.runtime.sessionSnapshot(id: address.sessionID)
                let completion = try #require(finalState.executions[address.executionID]?.completion)
                #expect(completion.status == .completed)
                #expect(try await fixture.library.read(try #require(completion.answer)) == Data("Hello world".utf8))
                #expect(try await fixture.library.read(try #require(completion.visibleThinking)) == Data("Plan".utf8))
                #expect(await fixture.model.inputs.count == 1)
            } catch {
                observer.cancel()
                await fixture.model.releaseStream()
                _ = await observer.result
                throw error
            }
        }
    }

    @Test func runtimeCancellationClearsVisibleOutputBeforeProducerDrain() async throws {
        try await withTaskWorkflow(outputs: [[
            .blockStarted(.init(id: "answer-1", content: .text("Partial"))),
            .blockFinished(id: "answer-1"),
            .blockStarted(.init(id: "reasoning", content: .thinking("Private plan"))),
            .blockFinished(id: "reasoning"),
            .blockStarted(.init(id: "answer-2", content: .text(" never"))),
            .blockFinished(id: "answer-2"), .finished(.stop)
        ]], thinkingEnabled: true) { fixture in
            await fixture.model.holdStream(number: 1, afterEvents: 1)
            let address = try await submit("Question", in: fixture)
            let stream = try await fixture.runtime.observeSessionOutput(id: address.sessionID)
            let probe = OutputProbe()
            let observer = observe(stream, into: probe)
            do {
                try await taskEventually { await fixture.model.streamHeld }
                try await taskEventually { await probe.hasValue(executionID: address.executionID, answer: "Partial", thinking: "") }

                await fixture.runtime.cancel(sessionID: address.sessionID)
                try await taskEventually { await probe.hasClearedAfterValue }
                #expect(await fixture.model.streamHeld)

                await fixture.model.releaseStream()
                try taskRequireCommitted(await fixture.runtime.waitForExecution(id: address.executionID, sessionID: address.sessionID))
                try await taskEventually { await fixture.model.streamDrained }
                #expect(await fixture.model.inputs.count == 1)
                let state = try await fixture.runtime.sessionSnapshot(id: address.sessionID)
                #expect(state.executions[address.executionID]?.completion?.status == .cancelled ||
                        state.executions[address.executionID]?.completion?.status == .interrupted)
            } catch {
                await fixture.model.releaseStream()
                observer.cancel()
                _ = await observer.result
                throw error
            }
            observer.cancel()
            await observer.value
        }
    }

    @Test func maintenanceRevocationClearsVisibleOutputBeforeProducerDrain() async throws {
        try await withTaskWorkflow(outputs: [[
            .blockStarted(.init(id: "answer-1", content: .text("Partial"))),
            .blockFinished(id: "answer-1"),
            .blockStarted(.init(id: "reasoning", content: .thinking("Private plan"))),
            .blockFinished(id: "reasoning"),
            .blockStarted(.init(id: "answer-2", content: .text(" never"))),
            .blockFinished(id: "answer-2"), .finished(.stop)
        ]], thinkingEnabled: true) { fixture in
            await fixture.model.holdStream(number: 1, afterEvents: 1)
            let address = try await submit("Question", in: fixture)
            let stream = try await fixture.runtime.observeSessionOutput(id: address.sessionID)
            let probe = OutputProbe()
            let observer = observe(stream, into: probe)
            var operation: AgentLibraryMaintenanceOperation?
            do {
                try await taskEventually { await fixture.model.streamHeld }
                try await taskEventually { await probe.hasValue(executionID: address.executionID, answer: "Partial", thinking: "") }

                let authorization = await fixture.access.snapshot().authorization
                operation = try await fixture.access.begin(.init(
                    id: UUID(), namespace: "privacy.fixture", revision: 1, scope: .library,
                    requestedAt: TaskWorkflowFixture.now
                ), expected: authorization)
                try await taskEventually { await probe.hasClearedAfterValue }
                #expect(await fixture.model.streamHeld)

                await fixture.model.releaseStream()
                try taskRequireCommitted(await fixture.runtime.waitForExecution(id: address.executionID, sessionID: address.sessionID))
                try await taskEventually { await fixture.model.streamDrained }
                let report = await fixture.runtime.shutdown()
                #expect(report.isSettled)
                try await fixture.access.waitForQuiescence()
                _ = try await fixture.access.complete(operation!, at: TaskWorkflowFixture.now)
                #expect(await fixture.model.inputs.count == 1)
            } catch {
                await fixture.model.releaseStream()
                observer.cancel()
                _ = await observer.result
                throw error
            }
            observer.cancel()
            await observer.value
        }
    }

    @Test func applicationShutdownFinishesOutputStreamAfterProducerDrainAndRetainsCommittedDraftOnly() async throws {
        let clock = LiveOutputClock()
        let environment = RuntimeEnvironment(now: { TaskWorkflowFixture.now }, sleep: { duration in
            try await clock.sleep(for: duration)
        })
        try await withTaskWorkflow(outputs: [[
            .blockStarted(.init(id: "answer-1", content: .text("Final"))),
            .blockFinished(id: "answer-1"),
            .blockStarted(.init(id: "reasoning", content: .thinking("Plan"))),
            .blockFinished(id: "reasoning"),
            .blockStarted(.init(id: "answer-2", content: .text(" answer"))),
            .blockFinished(id: "answer-2"), .finished(.stop)
        ]], environment: environment, thinkingEnabled: true) { fixture in
            await fixture.model.holdStream(number: 1, afterEvents: 4)
            let address = try await submit("Question", in: fixture)
            let stream = try await fixture.runtime.observeSessionOutput(id: address.sessionID)
            let probe = OutputProbe()
            let observer = observe(stream, into: probe)
            let shutdownReturned = CompletionProbe()
            var shutdown: Task<AgentApplicationShutdownReport, Never>?
            do {
                try await taskEventually { await fixture.model.streamHeld }
                try await taskEventually { await probe.hasValue(executionID: address.executionID, answer: "Final", thinking: "") }

                try await taskEventually { await clock.isEntered(.visible) }
                await clock.release(.visible)
                try await taskEventually { await probe.hasValue(executionID: address.executionID, answer: "Final", thinking: "Plan") }
                try await taskEventually { await clock.isEntered(.durable) }
                await clock.release(.durable)
                try await taskEventually {
                    let state = try await fixture.runtime.sessionSnapshot(id: address.sessionID)
                    let drafts = try await SessionDraftReader(journal: fixture.library, payloads: fixture.library)
                        .read(state: state, executionID: address.executionID)
                    return String(data: drafts[.answer, default: Data()], encoding: .utf8) == "Final"
                        && String(data: drafts[.thinking, default: Data()], encoding: .utf8) == "Plan"
                }

                shutdown = Task {
                    let report = await fixture.runtime.shutdown()
                    await shutdownReturned.mark()
                    return report
                }
                try await taskEventually { await fixture.runtime.snapshot().phase == .closing }
                #expect(await !shutdownReturned.value)
                #expect(await !probe.finished)
                #expect(await fixture.model.streamHeld)
                try await taskEventually { await probe.hasClearedAfterValue }

                await fixture.model.releaseStream()
                let report = await shutdown!.value
                #expect(report.isSettled)
                try await taskEventually { await fixture.model.streamDrained }
                try await taskEventually { await probe.finished }
                #expect(await fixture.model.inputs.count == 1)

                let reopened = try await SessionRuntime.open(id: address.sessionID, journal: fixture.library, payloads: fixture.library,
                                                             environment: .init(now: { TaskWorkflowFixture.now }))
                let state = await reopened.snapshot()
                let completion = try #require(state.executions[address.executionID]?.completion)
                #expect(completion.status == .interrupted || completion.status == .cancelled)
                #expect(try await fixture.library.read(try #require(completion.answer)) == Data("Final".utf8))
                #expect(try await fixture.library.read(try #require(completion.visibleThinking)) == Data("Plan".utf8))
                #expect(!(await probe.hasValue(executionID: address.executionID, answer: "Final answer", thinking: "Plan")))
                await reopened.close()
            } catch {
                await fixture.model.releaseStream()
                shutdown?.cancel()
                _ = await shutdown?.result
                observer.cancel()
                _ = await observer.result
                throw error
            }
            observer.cancel()
            await observer.value
        }
    }
}

private func submit(_ text: String, in fixture: TaskWorkflowFixture,
                    sessionID: ConversationID = ConversationID()) async throws -> AgentExecutionAddress {
    let executionID = ExecutionID()
    let opening: AgentSessionOpening? = try await fixture.runtime.sessionSnapshot(id: sessionID).header == nil
        ? .init(title: "Synthetic task workflow", workspaceID: nil) : nil
    let command = AgentSubmitCommand(id: UUID(), sessionID: sessionID, executionID: executionID,
        input: .message(id: MessageID(), text: text, timeZoneIdentifier: "Asia/Shanghai"),
        options: .init(instructions: "Use the available task tools.", route: fixture.route), opening: opening)
    try taskRequireCommitted(await fixture.runtime.submit(command))
    return .init(sessionID: sessionID, executionID: executionID)
}

private func observe(_ stream: AsyncStream<SessionOutputObservation>, into probe: OutputProbe) -> Task<Void, Never> {
    Task {
        for await observation in stream { await probe.append(observation) }
        await probe.markFinished()
    }
}

private actor OutputProbe {
    private(set) var observations: [SessionOutputObservation] = []
    private(set) var finished = false

    func append(_ observation: SessionOutputObservation) { observations.append(observation) }
    func markFinished() { finished = true }

    func hasValue(executionID: ExecutionID, answer: String, thinking: String) -> Bool {
        observations.contains {
            guard let value = $0.value else { return false }
            return value.executionID == executionID && value.answer == answer && value.thinking == thinking
        }
    }

    var hasClearedAfterValue: Bool {
        var sawValue = false
        for observation in observations {
            if observation.value != nil { sawValue = true }
            else if sawValue { return true }
        }
        return false
    }
}

private actor CompletionProbe {
    private(set) var value = false
    func mark() { value = true }
}

private enum OutputTimer: Hashable, Sendable { case visible, durable }

private actor LiveOutputClock: RuntimeClock {
    private var waiters: [OutputTimer: [UUID: CheckedContinuation<Void, any Error>]] = [:]
    private var enteredTimers: Set<OutputTimer> = []

    func sleep(for duration: Duration) async throws {
        guard let timer = Self.timer(for: duration) else {
            try await Task.sleep(for: duration)
            return
        }
        let id = UUID()
        try Task.checkCancellation()
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters[timer, default: [:]][id] = continuation
                    enteredTimers.insert(timer)
                }
            }
        }, onCancel: {
            Task { await self.cancel(id: id, timer: timer) }
        })
    }

    func isEntered(_ timer: OutputTimer) -> Bool { enteredTimers.contains(timer) }

    func release(_ timer: OutputTimer) {
        guard let id = waiters[timer]?.keys.first,
              let continuation = waiters[timer]?.removeValue(forKey: id) else { return }
        continuation.resume()
    }

    private func cancel(id: UUID, timer: OutputTimer) {
        guard let continuation = waiters[timer]?.removeValue(forKey: id) else { return }
        continuation.resume(throwing: CancellationError())
    }

    private static func timer(for duration: Duration) -> OutputTimer? {
        if duration == .milliseconds(100) { return .visible }
        if duration == .milliseconds(250) { return .durable }
        return nil
    }
}
