import Foundation
import Testing
@testable import MiraCore

@Suite("Journal agent history")
struct JournalAgentHistoryReaderTests {
    @Test func localDriverHistoryNeedsNoProviderReplayPolicy() async throws {
        let fixture = try await Fixture.make(adapter: .init(mode: .omit), includeLocalAnswer: true)
        let history = try await fixture.reader.read(state: fixture.state, request: fixture.request,
            route: fixture.route, adapter: fixture.adapter, authorizer: fixture.authorizer)
        #expect(history.context.messages.map(\.text) == ["Local question", "Local answer"])
        #expect(history.context.sources == [
            .sessionExecution(sessionID: fixture.state.id, executionID: fixture.localExecutionID!)
        ])
    }

    @Test func includesOnlyCompletedCommittedExchange() async throws {
        let fixture = try await Fixture.make()
        let history = try await fixture.reader.read(state: fixture.state, request: fixture.request,
            route: fixture.route, adapter: fixture.adapter, authorizer: fixture.authorizer)
        #expect(history.exchanges.count == 2)
        #expect(history.context.messages.map(\.role) == [.user, .assistant, .user, .assistant])
        #expect(history.context.messages.map(\.text) == ["Earlier question", "Earlier answer", "Second question", "Second answer"])
        #expect(history.context.messages.map(\.text).allSatisfy { !$0.contains("Failed") })
        #expect(history.exchanges.map { $0.messages.first?.text } == ["Earlier question", "Second question"])
    }

    @Test func cancelledPartialAnswerIsExplicitlyIncompleteAndPortable() async throws {
        let fixture = try await Fixture.make(includePartialAnswer: true)
        let reopened = try SessionCodec.decode(SessionState.self, from: SessionCodec.encode(fixture.state))
        let history = try await fixture.reader.read(state: reopened, request: fixture.request,
            route: fixture.route, adapter: fixture.adapter, authorizer: fixture.authorizer)
        let partial = try #require(history.exchanges.first(where: { $0.isIncomplete }))
        let answer = try #require(partial.messages.first(where: { $0.text == "Partial answer" }))
        #expect(partial.isIncomplete)
        #expect(answer.text == "Partial answer")
        #expect(answer.thinkingText.isEmpty)
        #expect(answer.toolCalls.isEmpty)
        #expect(answer.continuation == nil)
    }

    @Test func incompleteHistoryGetsNeutralContinuationNoticeInPreparedInput() async throws {
        let fixture = try await Fixture.make(includePartialAnswer: true)
        let history = try await fixture.reader.read(state: fixture.state, request: fixture.request,
            route: fixture.route, adapter: fixture.adapter, authorizer: fixture.authorizer)
        let build = try await AgentContextAssembler().build(request: fixture.request, stepID: UUID(), instructions: "Answer.",
            history: history, currentTrace: .init(messages: [], sources: []), tools: [], route: fixture.route,
            adapter: fixture.adapter, contributors: [], authorizer: fixture.authorizer)
        #expect(build.prepared.input.messages.contains { $0.text.contains("was interrupted") })
        #expect(build.prepared.input.messages.contains { $0.text == "Partial answer" })
    }

    @Test func thinkingOnlyInterruptionKeepsUserQuestionInPreparedInput() async throws {
        let fixture = try await Fixture.make(includePartialAnswer: true, partialAnswer: false)
        let history = try await fixture.reader.read(state: fixture.state, request: fixture.request,
            route: fixture.route, adapter: fixture.adapter, authorizer: fixture.authorizer)
        let build = try await AgentContextAssembler().build(request: fixture.request, stepID: UUID(), instructions: "Answer.",
            history: history, currentTrace: .init(messages: [], sources: []), tools: [], route: fixture.route,
            adapter: fixture.adapter, contributors: [], authorizer: fixture.authorizer)
        #expect(build.prepared.input.messages.contains { $0.text == "Partial question" })
        #expect(build.prepared.input.messages.contains { $0.text.contains("was interrupted") })
        #expect(!build.prepared.input.messages.contains { $0.text == "Partial answer" })
    }

    @Test func interruptedPartialAnswerRemainsIncompleteHistory() async throws {
        let fixture = try await Fixture.make(includePartialAnswer: true, interruptPartial: true)
        let history = try await fixture.reader.read(state: fixture.state, request: fixture.request,
            route: fixture.route, adapter: fixture.adapter, authorizer: fixture.authorizer)
        #expect(history.context.messages.contains { $0.text == "Partial answer" })
        #expect(history.exchanges.contains { $0.isIncomplete })
    }

    @Test func adapterOmitDropsWholeExchangeAndVisibleAnswerIsNotFallback() async throws {
        let fixture = try await Fixture.make(adapter: FixtureAdapter(mode: .omit))
        let history = try await fixture.reader.read(state: fixture.state, request: fixture.request,
            route: fixture.route, adapter: fixture.adapter, authorizer: fixture.authorizer)
        #expect(history.isEmpty)
        #expect(history.context.messages.isEmpty)
    }

    @Test func removingOldestExchangeDropsOnlyItsPrivateSources() async throws {
        let fixture = try await Fixture.make()
        let history = try await fixture.reader.read(state: fixture.state, request: fixture.request,
            route: fixture.route, adapter: fixture.adapter, authorizer: fixture.authorizer)
        let trimmed = history.removingOldestExchange()
        #expect(trimmed.exchanges.count == 1)
        #expect(trimmed.context.messages.map(\.text) == ["Second question", "Second answer"])
        #expect(trimmed.context.sources.contains(fixture.sharedSource))
        #expect(!trimmed.context.sources.contains(fixture.firstOnlySource))
        #expect(trimmed.context.sources.contains(
            .sessionExecution(sessionID: fixture.state.id, executionID: fixture.firstExecutionID)))
    }

    @Test func normalAndLocalExchangesCarryExactSessionExecutionSources() async throws {
        let fixture = try await Fixture.make()
        let history = try await fixture.reader.read(state: fixture.state, request: fixture.request,
            route: fixture.route, adapter: fixture.adapter, authorizer: fixture.authorizer)
        #expect(history.exchanges[0].sources.contains(
            .sessionExecution(sessionID: fixture.state.id, executionID: fixture.firstExecutionID)))
        #expect(history.exchanges[1].sources.contains(
            .sessionExecution(sessionID: fixture.state.id, executionID: fixture.secondExecutionID)))

        let localFixture = try await Fixture.make(adapter: .init(mode: .omit), includeLocalAnswer: true)
        let localHistory = try await localFixture.reader.read(state: localFixture.state,
            request: localFixture.request, route: localFixture.route, adapter: localFixture.adapter,
            authorizer: localFixture.authorizer)
        #expect(localHistory.exchanges.count == 1)
        #expect(localHistory.exchanges[0].sources == [
            .sessionExecution(sessionID: localFixture.state.id, executionID: localFixture.localExecutionID!)
        ])
    }

    @Test func sourceAuthorizerCanDenySessionExecutionReplay() async throws {
        let fixture = try await Fixture.make(authorizer: SessionExecutionRejectingAuthorizer())
        await #expect(throws: MiraError.self) {
            try await fixture.reader.read(state: fixture.state, request: fixture.request,
                route: fixture.route, adapter: fixture.adapter, authorizer: fixture.authorizer)
        }
    }

    @Test func ownExecutionSourceConsumesTheFiniteSourceBudget() async throws {
        let fixture = try await Fixture.make(includeSourceBudgetBoundary: true)
        let history = try await fixture.reader.read(state: fixture.state, request: fixture.request,
            route: fixture.route, adapter: fixture.adapter, authorizer: fixture.authorizer)
        #expect(history.exchanges.map { $0.messages.first?.text } == ["Earlier question"])
        #expect(!history.context.messages.contains { $0.text == "Second question" })
    }

    @Test func zeroBudgetsReturnEmptyHistory() async throws {
        let fixture = try await Fixture.make()
        let byMessages = try await fixture.reader.read(state: fixture.state, request: fixture.request,
            route: fixture.route, adapter: fixture.adapter, authorizer: fixture.authorizer, maximumMessages: 0)
        let byBytes = try await fixture.reader.read(state: fixture.state, request: fixture.request,
            route: fixture.route, adapter: fixture.adapter, authorizer: fixture.authorizer, maximumBytes: 0)
        #expect(byMessages.isEmpty)
        #expect(byBytes.isEmpty)
    }

    @Test func smallMessageBudgetRetainsWholeExchangesOnly() async throws {
        let fixture = try await Fixture.make()
        let history = try await fixture.reader.read(state: fixture.state, request: fixture.request,
            route: fixture.route, adapter: fixture.adapter, authorizer: fixture.authorizer, maximumMessages: 2)
        #expect(history.context.messages.map(\.text) == ["Second question", "Second answer"])
        #expect(history.context.messages.allSatisfy { $0.role != .tool && $0.toolCalls.isEmpty })
    }

    @Test func sourceAuthorizationFailureIsPropagated() async throws {
        let fixture = try await Fixture.make(authorizer: RejectingAuthorizer())
        var rejected = false
        do {
            _ = try await fixture.reader.read(state: fixture.state, request: fixture.request,
                route: fixture.route, adapter: fixture.adapter, authorizer: fixture.authorizer)
        } catch { rejected = true }
        #expect(rejected)
    }

    @Test func adapterCannotInjectThinkingContent() async throws {
        let injected = AgentModelMessage(role: .assistant, blocks: [
            .init(id: "text", content: .text("Earlier answer")),
            .init(id: "thinking", content: .thinking("forged"))
        ])
        let fixture = try await Fixture.make(adapter: FixtureAdapter(mode: .include([injected])))
        var rejected = false
        do {
            _ = try await fixture.reader.read(state: fixture.state, request: fixture.request,
                route: fixture.route, adapter: fixture.adapter, authorizer: fixture.authorizer)
        } catch { rejected = true }
        #expect(rejected)
    }
}

private actor MemoryPayloads: SessionContentStore {
    var values: [UUID: Data] = [:]
    func put(_ reference: SessionContent, _ data: Data) { values[reference.id] = data }
    func stage(_ data: Data, sessionID: ConversationID, batchID: UUID, kind: SessionContentKind) async throws -> SessionContent {
        let reference = SessionContent(kind: kind, bytes: data); values[reference.id] = data; return reference
    }
    func read(_ reference: SessionContent) async throws -> Data {
        guard let value = values[reference.id] else { throw MiraError(.notFound, "Missing payload.") }
        return value
    }
}

private struct FixtureAdapter: AgentModelAdapter {
    enum Mode: Sendable { case passthrough, omit, include([AgentModelMessage]) }
    let identity = AgentAdapterIdentity(id: "history.adapter", revision: 1)
    let mode: Mode
    func prepare(_ input: AgentModelInput, route: AgentModelRoute) throws -> AgentPreparedModelRequest {
        .init(adapter: identity, input: input, wirePayload: .object([:]), estimatedInputTokens: 1)
    }
    func stream(_ request: AgentPreparedModelRequest, route: AgentModelRoute) -> AgentModelOperation {
        .init(events: .init { $0.finish() }, cancelAndDrain: {})
    }
    func replay(_ messages: [AgentModelMessage], from source: AgentModelRoute, to target: AgentModelRoute, boundary: AgentReplayBoundary) throws -> AgentReplayDecision {
        switch mode {
        case .passthrough: return .include(messages)
        case .omit: return .omit
        case .include(let values): return .include(values)
        }
    }
}

private struct AllowingAuthorizer: AgentSourceAuthorizer {
    func validate(_ sources: [AgentSourceReference], for request: AgentContextRequest) async throws {}
}
private struct SessionExecutionRejectingAuthorizer: AgentSourceAuthorizer {
    func validate(_ sources: [AgentSourceReference], for request: AgentContextRequest) async throws {
        if sources.contains(where: {
            if case .sessionExecution = $0 { return true }
            return false
        }) {
            throw MiraError(.unauthorized, "Session execution history is denied.")
        }
    }
}
private struct RejectingAuthorizer: AgentSourceAuthorizer {
    func validate(_ sources: [AgentSourceReference], for request: AgentContextRequest) async throws { throw MiraError(.unauthorized, "History source denied.") }
}

private struct Fixture {
    let reader: JournalAgentHistoryReader
    let payloads: MemoryPayloads
    let state: SessionState
    let request: AgentContextRequest
    let route: AgentModelRoute
    let adapter: FixtureAdapter
    let authorizer: any AgentSourceAuthorizer
    let sessionID: ConversationID
    let firstExecutionID: ExecutionID
    let secondExecutionID: ExecutionID
    let localExecutionID: ExecutionID?
    let sharedSource: AgentSourceReference
    let firstOnlySource: AgentSourceReference

    static func make(adapter: FixtureAdapter = .init(mode: .passthrough),
                     authorizer: any AgentSourceAuthorizer = AllowingAuthorizer(),
                     includeLocalAnswer: Bool = false,
                     includeSourceBudgetBoundary: Bool = false, includePartialAnswer: Bool = false,
                     interruptPartial: Bool = false,
                     partialAnswer: Bool = true) async throws -> Fixture {
        let payloads = MemoryPayloads()
        let sessionID = ConversationID()
        let route = AgentModelRoute(id: RouteID(), revision: 1, connectionID: ConnectionID(), connectionRevision: 1,
            modelDescriptorID: ModelDescriptorID(), modelRevision: 1, modelAuthorizationRevision: 1, adapter: adapter.identity, invocationID: "test-invocation", invocationRevision: 1, endpointID: "test-endpoint", modelID: "history",
            credential: nil, contextWindow: 4096, maximumOutputTokens: 512,
            capabilities: .init(streamsText: true, callsTools: false, producesThinking: true), configuration: .object([:]))
        var state = SessionState(id: sessionID)
        let titleBatch = UUID()
        let title = ref(sessionID, .title, titleBatch)
        await payloads.put(title, Data("Title".utf8))
        try apply(&state, sessionID, titleBatch, [.opened(.init(workspaceID: nil, title: title))])

        func addCompleted(_ executionID: ExecutionID, question: String, answer: String,
                          sources: [AgentSourceReference] = [], local: Bool = false) async throws {
            let admissionBatch = UUID(), attemptBatch = UUID(), outputBatch = UUID(), finishBatch = UUID()
            let body = ref(sessionID, .userText, admissionBatch), routeRef = ref(sessionID, .executionPlan, admissionBatch)
            let requestRef = ref(sessionID, .request, attemptBatch), outputRef = ref(sessionID, .modelOutput, outputBatch)
            let answerRef = ref(sessionID, .visibleAnswer, finishBatch)
            await payloads.put(body, Data(question.utf8)); await payloads.put(routeRef, try SessionCodec.encode(AgentExecutionPlan(runtimeID: UUID(), catalogGeneration: 0, driverID: "mira.default", driverRevision: 1, instructions: "Answer.", limits: .init(), priority: .foreground, route: local ? nil : route)))
            let request = AgentContextRequest(sessionID: sessionID, executionID: executionID, workspaceID: nil,
                userText: question, authorizationEpoch: state.authorizationEpoch, destination: .model(route))
            let input = AgentModelInput(stepID: UUID(), executionID: executionID, instructions: "Answer.",
                messages: [.init(role: .user, blocks: [.init(id: "user", content: .text(question))])], tools: [])
            let prepared = AgentPreparedModelRequest(adapter: route.adapter, input: input,
                wirePayload: .object([:]), estimatedInputTokens: 1)
            await payloads.put(requestRef, try SessionCodec.encode(AgentSessionRequest(
                request: request, instructions: input.instructions, tools: input.tools,
                contextMessages: input.messages.filter { $0.role == .context },
                estimatedInputTokens: prepared.estimatedInputTokens,
                inheritedSources: sources, evidence: [], omissions: [])))
            await payloads.put(outputRef, try SessionCodec.encode(AgentModelOutput(
                blocks: [.init(id: "text", content: .text(answer))], continuation: nil,
                usage: .init(), finishReason: .stop)))
            await payloads.put(answerRef, Data(answer.utf8))
            try apply(&state, sessionID, admissionBatch, [.admitted(.init(executionID: executionID, userMessageID: MessageID(),
                userBody: body, plan: routeRef, hasModelRoute: !local, authorizationEpoch: state.authorizationEpoch, timeZoneIdentifier: "UTC"))])
            let attemptID = UUID()
            if !local {
                try apply(&state, sessionID, attemptBatch, [.phaseChanged(executionID: executionID, phase: .preparing),
                    .attemptStarted(.init(id: attemptID, executionID: executionID, stepID: UUID(), stepIndex: 1, attemptIndex: 1, request: requestRef))])
                try apply(&state, sessionID, outputBatch, [.attemptResolved(.init(attemptID: attemptID, status: .completed, output: outputRef))])
            }
            try apply(&state, sessionID, finishBatch, [.phaseChanged(executionID: executionID, phase: .settling),
                .finished(.init(executionID: executionID, status: .completed, assistantMessageID: MessageID(),
                    answer: answerRef))])
        }

        func addFailed(_ executionID: ExecutionID) async throws {
            let admissionBatch = UUID(), attemptBatch = UUID(), failedBatch = UUID(), finishBatch = UUID()
            let body = ref(sessionID, .userText, admissionBatch), routeRef = ref(sessionID, .executionPlan, admissionBatch)
            let requestRef = ref(sessionID, .request, attemptBatch)
            await payloads.put(body, Data("Failed question".utf8)); await payloads.put(routeRef, try SessionCodec.encode(AgentExecutionPlan(runtimeID: UUID(), catalogGeneration: 0, driverID: "mira.default", driverRevision: 1, instructions: "Answer.", limits: .init(), priority: .foreground, route: route))); await payloads.put(requestRef, Data("request".utf8))
            try apply(&state, sessionID, admissionBatch, [.admitted(.init(executionID: executionID, userMessageID: MessageID(),
                userBody: body, plan: routeRef, hasModelRoute: true, authorizationEpoch: state.authorizationEpoch, timeZoneIdentifier: "UTC"))])
            let attemptID = UUID()
            try apply(&state, sessionID, attemptBatch, [.phaseChanged(executionID: executionID, phase: .preparing),
                .attemptStarted(.init(id: attemptID, executionID: executionID, stepID: UUID(), stepIndex: 1, attemptIndex: 1, request: requestRef))])
            try apply(&state, sessionID, failedBatch, [.attemptResolved(.init(attemptID: attemptID, status: .failed))])
            try apply(&state, sessionID, finishBatch, [.phaseChanged(executionID: executionID, phase: .settling),
                .finished(.init(executionID: executionID, status: .failed))])
        }

        let sharedSource = AgentSourceReference.domain(namespace: "fixture", id: UUID(), revision: 1)
        let firstOnlySource = AgentSourceReference.domain(namespace: "fixture", id: UUID(), revision: 1)
        let firstID = ExecutionID(), secondID = ExecutionID(), failedID = ExecutionID(), currentID = ExecutionID()
        try await addCompleted(firstID, question: "Earlier question", answer: "Earlier answer",
            sources: [firstOnlySource, sharedSource])
        let secondSources: [AgentSourceReference] = includeSourceBudgetBoundary
            ? (0..<8_192).map { _ in .domain(namespace: "budget", id: UUID(), revision: 1) }
            : [sharedSource, .sessionExecution(sessionID: sessionID, executionID: firstID)]
        try await addCompleted(secondID, question: "Second question", answer: "Second answer", sources: secondSources)
        try await addFailed(failedID)
        if includePartialAnswer {
            let id = ExecutionID(), admissionBatch = UUID(), attemptBatch = UUID(), finishBatch = UUID()
            let body = ref(sessionID, .userText, admissionBatch), routeRef = ref(sessionID, .executionPlan, admissionBatch)
            let requestRef = ref(sessionID, .request, attemptBatch)
            let answerRef: SessionContent? = partialAnswer ? ref(sessionID, .visibleAnswer, finishBatch) : nil
            let thinkingRef: SessionContent? = partialAnswer ? nil : ref(sessionID, .visibleThinking, finishBatch)
            await payloads.put(body, Data("Partial question".utf8))
            await payloads.put(routeRef, try SessionCodec.encode(AgentExecutionPlan(runtimeID: UUID(), catalogGeneration: 0,
                driverID: "mira.default", driverRevision: 1, instructions: "Answer.", limits: .init(), priority: .foreground, route: route)))
            let requestBuild = AgentSessionRequest(request: .init(sessionID: sessionID, executionID: id, workspaceID: nil,
                userText: "Partial question", authorizationEpoch: state.authorizationEpoch, destination: .model(route)),
                instructions: "Answer.", tools: [], contextMessages: [], estimatedInputTokens: 1,
                inheritedSources: [], evidence: [], omissions: [])
            await payloads.put(requestRef, try SessionCodec.encode(requestBuild))
            if let answerRef { await payloads.put(answerRef, Data("Partial answer".utf8)) }
            if let thinkingRef { await payloads.put(thinkingRef, Data("Partial thought".utf8)) }
            let answerStatus: ExecutionStatus = interruptPartial ? .interrupted : .cancelled
            try apply(&state, sessionID, admissionBatch, [.admitted(.init(executionID: id, userMessageID: MessageID(), userBody: body,
                plan: routeRef, hasModelRoute: true, authorizationEpoch: state.authorizationEpoch, timeZoneIdentifier: "UTC"))])
            let attemptID = UUID()
            try apply(&state, sessionID, attemptBatch, [.phaseChanged(executionID: id, phase: .preparing),
                .attemptStarted(.init(id: attemptID, executionID: id, stepID: UUID(), stepIndex: 1, attemptIndex: 1, request: requestRef)),
                .attemptResolved(.init(attemptID: attemptID, status: .interrupted))])
            try apply(&state, sessionID, finishBatch, [.phaseChanged(executionID: id, phase: .cancelling),
                .finished(.init(executionID: id, status: answerStatus,
                    assistantMessageID: answerRef == nil ? MessageID() : MessageID(), answer: answerRef,
                    visibleThinking: thinkingRef))])
        }
        let localExecutionID: ExecutionID?
        if includeLocalAnswer {
            let id = ExecutionID()
            localExecutionID = id
            try await addCompleted(id, question: "Local question", answer: "Local answer", local: true)
        } else {
            localExecutionID = nil
        }
        let currentBatch = UUID(), currentBody = ref(sessionID, .userText, currentBatch), currentRoute = ref(sessionID, .executionPlan, currentBatch)
        await payloads.put(currentBody, Data("Current question".utf8)); await payloads.put(currentRoute, try SessionCodec.encode(AgentExecutionPlan(runtimeID: UUID(), catalogGeneration: 0, driverID: "mira.default", driverRevision: 1, instructions: "Answer.", limits: .init(), priority: .foreground, route: route)))
        try apply(&state, sessionID, currentBatch, [.admitted(.init(executionID: currentID, userMessageID: MessageID(), userBody: currentBody,
            plan: currentRoute, hasModelRoute: true, authorizationEpoch: state.authorizationEpoch, timeZoneIdentifier: "UTC"))])
        let request = AgentContextRequest(sessionID: sessionID, executionID: currentID, workspaceID: nil,
            userText: "Current question", authorizationEpoch: state.authorizationEpoch, destination: .model(route))
        return .init(reader: .init(payloads: payloads), payloads: payloads, state: state, request: request,
                     route: route, adapter: adapter, authorizer: authorizer, sessionID: sessionID,
                     firstExecutionID: firstID, secondExecutionID: secondID, localExecutionID: localExecutionID,
                     sharedSource: sharedSource, firstOnlySource: firstOnlySource)
    }
}

private func ref(_ session: ConversationID, _ kind: SessionContentKind, _ batchID: UUID) -> SessionContent {
    .init(id: UUID(), kind: kind, bytes: Data(kind.rawValue.utf8))
}

private func apply(_ state: inout SessionState, _ session: ConversationID, _ batchID: UUID, _ facts: [SessionFact]) throws {
    let next = state.sequence + Int64(facts.count)
    let batch = SessionBatch(id: batchID, sessionID: session, expectedSequence: state.sequence,
        events: facts.enumerated().map { offset, fact in
            SessionEvent(sequence: state.sequence + Int64(offset) + 1, occurredAt: Date(), fact: fact)
        })
    try state.apply(batch)
    _ = next
}
