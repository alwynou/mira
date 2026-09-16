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

    @Test func includesOnlyCompletedReplayExchange() async throws {
        let fixture = try await Fixture.make()
        let history = try await fixture.reader.read(state: fixture.state, request: fixture.request,
            route: fixture.route, adapter: fixture.adapter, authorizer: fixture.authorizer)
        #expect(history.exchanges.count == 2)
        #expect(history.context.messages.map(\.role) == [.user, .assistant, .user, .assistant])
        #expect(history.context.messages.map(\.text) == ["Earlier question", "Earlier answer", "Second question", "Second answer"])
        #expect(history.context.messages.map(\.text).allSatisfy { !$0.contains("No replay") && !$0.contains("Failed") && !$0.contains("Excluded") })
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

    @Test func interruptedPartialAnswerDoesNotPromoteSuccessOrBypassPrivacy() async throws {
        let fixture = try await Fixture.make(includePartialAnswer: true, interruptPartial: true,
                                             invalidatePartial: true)
        let history = try await fixture.reader.read(state: fixture.state, request: fixture.request,
            route: fixture.route, adapter: fixture.adapter, authorizer: fixture.authorizer)
        #expect(history.context.messages.allSatisfy { $0.text != "Partial answer" })
        #expect(history.exchanges.allSatisfy { !$0.isIncomplete })
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
        let fixture = try await Fixture.make(includeToolExchange: true)
        let history = try await fixture.reader.read(state: fixture.state, request: fixture.request,
            route: fixture.route, adapter: fixture.adapter, authorizer: fixture.authorizer, maximumMessages: 2)
        #expect(history.context.messages.map(\.text) == ["Earlier question", "Earlier answer"])
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

private actor MemoryPayloads: SessionPayloadStore {
    var values: [UUID: Data] = [:]
    func put(_ reference: SessionPayloadReference, _ data: Data) { values[reference.id] = data }
    func stage(_ data: Data, sessionID: ConversationID, batchID: UUID, retentionGroup: UUID, kind: SessionPayloadKind) async throws -> SessionPayloadReference { fatalError() }
    func read(_ reference: SessionPayloadReference) async throws -> Data {
        guard let value = values[reference.id] else { throw MiraError(.notFound, "Missing payload.") }
        return value
    }
    func purge(sessionID: ConversationID, retentionGroups: Set<UUID>) async throws {}
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
                     includeToolExchange: Bool = false, includeLocalAnswer: Bool = false,
                     includeSourceBudgetBoundary: Bool = false, includePartialAnswer: Bool = false,
                     interruptPartial: Bool = false, invalidatePartial: Bool = false,
                     partialAnswer: Bool = true) async throws -> Fixture {
        let payloads = MemoryPayloads()
        let sessionID = ConversationID()
        let route = AgentModelRoute(id: RouteID(), revision: 1, connectionID: ConnectionID(), connectionRevision: 1,
            modelDescriptorID: ModelDescriptorID(), modelRevision: 1, modelAuthorizationRevision: 1, adapter: adapter.identity, invocationID: "test-invocation", invocationRevision: 1, endpointID: "test-endpoint", metadataEvidence: [], modelID: "history",
            credential: nil, contextWindow: 4096, maximumOutputTokens: 512,
            capabilities: .init(streamsText: true, callsTools: false, producesThinking: true), configuration: .object([:]))
        var state = SessionState(id: sessionID)
        let titleBatch = UUID()
        let title = ref(sessionID, .title, titleBatch)
        await payloads.put(title, Data("Title".utf8))
        try apply(&state, sessionID, titleBatch, [.opened(.init(workspaceID: nil, title: title))])

        func addCompleted(_ executionID: ExecutionID, question: String, answer: String,
                          includeReplay: Bool, sources: [AgentSourceReference] = [],
                          replayMessages: [AgentModelMessage]? = nil, local: Bool = false) async throws -> Set<UUID> {
            let admissionBatch = UUID(), attemptBatch = UUID(), outputBatch = UUID(), finishBatch = UUID()
            let body = ref(sessionID, .userText, admissionBatch), routeRef = ref(sessionID, .executionPlan, admissionBatch)
            let requestRef = ref(sessionID, .request, attemptBatch), outputRef = ref(sessionID, .modelOutput, outputBatch)
            let answerRef = ref(sessionID, .visibleAnswer, finishBatch)
            await payloads.put(body, Data(question.utf8)); await payloads.put(routeRef, try SessionCodec.encode(AgentExecutionPlan(runtimeID: UUID(), catalogGeneration: 0, driverID: "mira.default", driverRevision: 1, instructions: "Answer.", limits: .init(), priority: .foreground, route: local ? nil : route)))
            await payloads.put(requestRef, Data("request".utf8)); await payloads.put(outputRef, Data("output".utf8))
            await payloads.put(answerRef, Data(answer.utf8))
            let replayRef: SessionPayloadReference?
            if includeReplay {
                let replay = AgentReplayRecord(messages: replayMessages ?? [.init(role: .assistant, blocks: [.init(id: "text", content: .text(answer))])], sources: sources)
                let reference = ref(sessionID, .replay, finishBatch)
                await payloads.put(reference, try SessionCodec.encode(replay)); replayRef = reference
            } else { replayRef = nil }
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
                    answer: answerRef, replay: replayRef))])
            return Set([body, routeRef, requestRef, outputRef, answerRef, replayRef].compactMap { $0?.retentionGroup })
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
        let firstID = ExecutionID(), secondID = ExecutionID(), noReplayID = ExecutionID(), failedID = ExecutionID(), excludedID = ExecutionID(), currentID = ExecutionID()
        _ = try await addCompleted(firstID, question: "Earlier question", answer: "Earlier answer", includeReplay: true,
            sources: [firstOnlySource, sharedSource])
        let secondSources: [AgentSourceReference] = includeSourceBudgetBoundary
            ? (0..<8_192).map { _ in .domain(namespace: "budget", id: UUID(), revision: 1) }
            : [sharedSource, .sessionExecution(sessionID: sessionID, executionID: firstID)]
        let toolCall = CanonicalToolCall(id: "history-call", name: "lookup", arguments: "{}")
        _ = try await addCompleted(secondID, question: "Second question", answer: "Second answer", includeReplay: true,
            sources: secondSources, replayMessages: includeToolExchange ? [
                .init(role: .assistant, blocks: [.init(id: "text", content: .text("Second answer")), .init(id: "tool-0", content: .toolCall(toolCall))]),
                .init(role: .tool, blocks: [.init(id: "result-\(toolCall.id)", content: .toolResult(callID: toolCall.id, text: "Tool result"))]),
                .init(role: .assistant, blocks: [.init(id: "text", content: .text("Second answer"))])
            ] : nil)
        _ = try await addCompleted(noReplayID, question: "No replay question", answer: "No replay answer", includeReplay: false)
        try await addFailed(failedID)
        let excludedGroups = try await addCompleted(excludedID, question: "Excluded question", answer: "Excluded answer", includeReplay: true,
            sources: [AgentSourceReference.domain(namespace: "fixture", id: UUID(), revision: 1)])
        try apply(&state, sessionID, UUID(), [.invalidated(.init(operationID: UUID(), executionIDs: [excludedID],
            retentionGroups: excludedGroups, authorizationEpoch: state.authorizationEpoch + 1, reason: .forgotten))])
        if includePartialAnswer {
            let id = ExecutionID(), admissionBatch = UUID(), attemptBatch = UUID(), finishBatch = UUID()
            let body = ref(sessionID, .userText, admissionBatch), routeRef = ref(sessionID, .executionPlan, admissionBatch)
            let requestRef = ref(sessionID, .request, attemptBatch)
            let answerRef: SessionPayloadReference? = partialAnswer ? ref(sessionID, .visibleAnswer, finishBatch) : nil
            let thinkingRef: SessionPayloadReference? = partialAnswer ? nil : ref(sessionID, .visibleThinking, finishBatch)
            await payloads.put(body, Data("Partial question".utf8))
            await payloads.put(routeRef, try SessionCodec.encode(AgentExecutionPlan(runtimeID: UUID(), catalogGeneration: 0,
                driverID: "mira.default", driverRevision: 1, instructions: "Answer.", limits: .init(), priority: .foreground, route: route)))
            let requestBuild = AgentContextBuild(request: .init(sessionID: sessionID, executionID: id, workspaceID: nil,
                userText: "Partial question", authorizationEpoch: state.authorizationEpoch, destination: .model(route)),
                prepared: .init(adapter: route.adapter, input: .init(stepID: UUID(), executionID: id, instructions: "Answer.",
                    messages: [.init(role: .user, blocks: [.init(id: "user", content: .text("Partial question"))])], tools: []),
                    wirePayload: .object([:]), estimatedInputTokens: 1), inheritedSources: [], evidence: [], omissions: [])
            await payloads.put(requestRef, try SessionCodec.encode(try AgentRequestRecord(requestBuild)))
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
            if invalidatePartial {
                try apply(&state, sessionID, UUID(), [.invalidated(.init(operationID: UUID(), executionIDs: [id],
                    retentionGroups: Set([body.retentionGroup, routeRef.retentionGroup, requestRef.retentionGroup]
                        + (answerRef.map { [$0.retentionGroup] } ?? [])
                        + (thinkingRef.map { [$0.retentionGroup] } ?? [])),
                    authorizationEpoch: state.authorizationEpoch + 1, reason: .forgotten))])
            }
        }
        let localExecutionID: ExecutionID?
        if includeLocalAnswer {
            let id = ExecutionID()
            localExecutionID = id
            _ = try await addCompleted(id, question: "Local question", answer: "Local answer",
                                      includeReplay: true, local: true)
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

private func ref(_ session: ConversationID, _ kind: SessionPayloadKind, _ batchID: UUID) -> SessionPayloadReference {
    .init(id: UUID(), sessionID: session, batchID: batchID, retentionGroup: UUID(), kind: kind,
          byteCount: 1, digest: String(repeating: "0", count: 64))
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
