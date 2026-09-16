import Foundation
import Testing
@testable import MiraCore
@testable import MiraData

@Suite("Session execution sources", .timeLimit(.minutes(1)))
struct SessionExecutionSourceTests {
    @Test func sameExecutionIDAcrossSessionsRemainsQualifiedBySession() async throws {
        let fixture = try await SharedSourceFixture.make()
        do {
            let selected = [fixture.sessionB.source, fixture.sessionASecond.source, fixture.sessionAFirst.source]
            let evidence = try await fixture.reader.executionSources(selected)
            #expect(evidence.map(\.source) == selected)
            #expect(evidence.map(\.originalUser.userMessageID) == [fixture.sessionB.messageID,
                                                                     fixture.sessionASecond.messageID,
                                                                     fixture.sessionAFirst.messageID])
            #expect(evidence[0].originalUser.originalExecutionID == fixture.sharedExecutionID)
            #expect(evidence[2].originalUser.originalExecutionID == fixture.sharedExecutionID)
            #expect(evidence.allSatisfy { $0.sessionAuthorizationEpoch == 0 })
            #expect(evidence[0].workspaceID == fixture.sessionB.workspaceID)
            let headA = try await fixture.library.head(sessionID: fixture.sessionAFirst.id)
            let headB = try await fixture.library.head(sessionID: fixture.sessionB.id)
            #expect(evidence[1].observedHead == headA)
            #expect(evidence[0].observedHead == headB)
        } catch { await fixture.close(); throw error }
        await fixture.close()
    }

    @Test func onlyCompletedReplayableExecutionsResolve() async throws {
        for kind in [SourceFixture.Kind.active, .failed, .completedWithoutReplay] {
            let fixture = try await SourceFixture.make(kind: kind)
            await expectCode(.unauthorized) { _ = try await fixture.reader.executionSources([fixture.source]) }
            await fixture.close()
        }
        let missing = try await SourceFixture.make(kind: .completed)
        let unknown = AgentSourceReference.sessionExecution(sessionID: missing.sessionID, executionID: ExecutionID())
        await expectCode(.unauthorized) { _ = try await missing.reader.executionSources([unknown]) }
        await missing.close()
    }

    @Test func completedRetryResolvesOriginalAdmissionReference() async throws {
        let fixture = try await SourceFixture.makeRetry()
        do {
            let evidence = try #require(try await fixture.reader.executionSources([fixture.source]).first)
            #expect(evidence.source == fixture.source)
            #expect(evidence.originalUser.originalExecutionID == fixture.originalExecutionID)
            #expect(evidence.originalUser.userMessageID == fixture.userMessageID)
            #expect(evidence.replay?.kind == .replay)
            #expect(evidence.workspaceID == fixture.workspaceID)
        } catch { await fixture.close(); throw error }
        await fixture.close()
    }

    @Test func invalidationDeniesSourceWhileVisibleAnswerRemains() async throws {
        let fixture = try await SourceFixture.make(kind: .completed)
        do {
            let before = try await fixture.reader.executionSources([fixture.source])
            #expect(before.count == 1)
            let state = await fixture.runtime.snapshot()
            let invalidation = await fixture.runtime.commit(id: UUID()) { _ in
                [.invalidated(.init(operationID: UUID(), executionIDs: [fixture.executionID],
                    retentionGroups: fixture.hiddenRetentionGroups,
                    authorizationEpoch: state.authorizationEpoch + 1, reason: .forgotten))]
            }
            try requireCommitted(invalidation)
            await expectCode(.unauthorized) { _ = try await fixture.reader.executionSources([fixture.source]) }
            let answer = try #require(state.executions[fixture.executionID]?.completion?.answer)
            #expect(!fixture.hiddenRetentionGroups.contains(answer.retentionGroup))
            #expect(try await fixture.library.read(answer) == Data("Visible answer".utf8))
        } catch {
            await fixture.close()
            throw error
        }
        await fixture.close()
    }

    @Test func realSourceAuthorizerAllowsCancelledPartialAndThinkingOnlySources() async throws {
        let domains = RuntimeRegistry<any AgentDomainSourceAuthority>()
        for kind in [SourceFixture.Kind.cancelledPartial, .interruptedThinking] {
            let fixture = try await SourceFixture.make(kind: kind)
            let authorizer = JournalAgentSourceAuthorizer(reader: fixture.reader,
                policy: AllowingContextPolicy(), domains: domains)
            let request = AgentContextRequest(sessionID: fixture.sessionID, executionID: ExecutionID(),
                workspaceID: fixture.workspaceID, userText: "Continue", authorizationEpoch: 0, destination: .local)
            do {
                try await authorizer.validate([fixture.source], for: request)
            } catch { await fixture.close(); throw error }
            await fixture.close()
        }
    }

    @Test func realSourceAuthorizerRejectsInvalidatedIncompleteSource() async throws {
        let fixture = try await SourceFixture.make(kind: .cancelledPartial)
        let domains = RuntimeRegistry<any AgentDomainSourceAuthority>()
        let authorizer = JournalAgentSourceAuthorizer(reader: fixture.reader,
            policy: AllowingContextPolicy(), domains: domains)
        let state = await fixture.runtime.snapshot()
        let invalidation = await fixture.runtime.commit(id: UUID()) { _ in
            [.invalidated(.init(operationID: UUID(), executionIDs: [fixture.executionID],
                retentionGroups: fixture.hiddenRetentionGroups,
                authorizationEpoch: state.authorizationEpoch + 1, reason: .forgotten))]
        }
        try requireCommitted(invalidation)
        let request = AgentContextRequest(sessionID: fixture.sessionID, executionID: ExecutionID(),
            workspaceID: fixture.workspaceID, userText: "Continue", authorizationEpoch: 0, destination: .local)
        await expectCode(.unauthorized) {
            try await authorizer.validate([fixture.source], for: request)
        }
        await fixture.close()
    }

    @Test func invalidSelectionsRejectWithInvalidInput() async throws {
        let fixture = try await SourceFixture.make(kind: .completed)
        let domain = AgentSourceReference.domain(namespace: "tests", id: UUID(), revision: 1)
        await expectCode(.invalidInput) { _ = try await fixture.reader.executionSources([domain]) }
        await expectCode(.invalidInput) { _ = try await fixture.reader.executionSources([fixture.source, fixture.source]) }
        let oversized = (0...8_192).map { _ in
            AgentSourceReference.sessionExecution(sessionID: fixture.sessionID, executionID: ExecutionID())
        }
        await expectCode(.invalidInput) { _ = try await fixture.reader.executionSources(oversized) }
        await fixture.close()
    }
}

private final class SharedSourceFixture: Sendable {
    struct Entry: Sendable {
        let id: ConversationID
        let executionID: ExecutionID
        let messageID: MessageID
        let source: AgentSourceReference
        let workspaceID: WorkspaceID
    }

    let directory: URL
    let library: FileSessionLibrary
    let runtimes: [SessionRuntime]
    let reader: JournalSessionReader
    let sessionAFirst: Entry
    let sessionASecond: Entry
    let sessionB: Entry
    let sharedExecutionID: ExecutionID

    static func make() async throws -> SharedSourceFixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mira-shared-execution-source-\(UUID().uuidString)")
        let library = try FileSessionLibrary(directory: directory)
        var runtimes: [SessionRuntime] = []
        do {
            let sharedExecutionID = ExecutionID()
            let sessionA = ConversationID(), sessionB = ConversationID()
            let workspaceA = WorkspaceID(), workspaceB = WorkspaceID()
            let runtimeA = try await SessionRuntime.open(id: sessionA, journal: library, payloads: library)
            runtimes.append(runtimeA)
            let aFirst = try await Self.complete(runtimeA, executionID: sharedExecutionID,
                messageID: MessageID(), workspaceID: workspaceA, text: "A first")
            let aSecond = try await Self.complete(runtimeA, executionID: ExecutionID(),
                messageID: MessageID(), workspaceID: workspaceA, text: "A second")
            let runtimeB = try await SessionRuntime.open(id: sessionB, journal: library, payloads: library)
            runtimes.append(runtimeB)
            let b = try await Self.complete(runtimeB, executionID: sharedExecutionID,
                messageID: MessageID(), workspaceID: workspaceB, text: "B shared")
            return .init(directory: directory, library: library, runtimes: runtimes,
                reader: .init(journal: library, payloads: library), sessionAFirst: aFirst,
                sessionASecond: aSecond, sessionB: b, sharedExecutionID: sharedExecutionID)
        } catch {
            for runtime in runtimes { await runtime.close() }
            try? await library.close(); try? FileManager.default.removeItem(at: directory); throw error
        }
    }

    private init(directory: URL, library: FileSessionLibrary, runtimes: [SessionRuntime], reader: JournalSessionReader,
                 sessionAFirst: Entry, sessionASecond: Entry, sessionB: Entry, sharedExecutionID: ExecutionID) {
        self.directory = directory; self.library = library; self.runtimes = runtimes; self.reader = reader
        self.sessionAFirst = sessionAFirst; self.sessionASecond = sessionASecond; self.sessionB = sessionB
        self.sharedExecutionID = sharedExecutionID
    }

    func close() async {
        for runtime in runtimes { await runtime.close() }
        try? await library.close(); try? FileManager.default.removeItem(at: directory)
    }

    private static func complete(_ runtime: SessionRuntime, executionID: ExecutionID, messageID: MessageID,
                                 workspaceID: WorkspaceID, text: String) async throws -> Entry {
        let isFirstExecution = await runtime.snapshot().header == nil
        let result = await runtime.commit(id: UUID()) { context in
            let body = try await context.stageBytes(Data(text.utf8), kind: .userText, retentionGroup: UUID())
            let plan = try await context.stage(AgentExecutionPlan(runtimeID: UUID(), catalogGeneration: 1,
                driverID: "mira.default", driverRevision: 1, instructions: "Local", limits: .init(),
                priority: .foreground, route: nil), kind: .executionPlan, retentionGroup: UUID())
            var facts: [SessionFact] = []
            if isFirstExecution {
                let title = try await context.stageBytes(Data("Session".utf8), kind: .title, retentionGroup: UUID())
                facts.append(.opened(.init(workspaceID: workspaceID, title: title)))
            }
            facts.append(.admitted(.init(executionID: executionID, userMessageID: messageID, userBody: body,
                plan: plan, hasModelRoute: false, authorizationEpoch: 0, timeZoneIdentifier: "UTC")))
            return facts
        }
        try requireCommitted(result)
        let settling = await runtime.commit(id: UUID()) { _ in [.phaseChanged(executionID: executionID, phase: .settling)] }
        try requireCommitted(settling)
        let finished = await runtime.commit(id: UUID()) { context in
            let answer = try await context.stageBytes(Data("Visible answer".utf8), kind: .visibleAnswer, retentionGroup: UUID())
            let replay = try await AgentReplayManifest.stage(.init(messages: [.init(role: .assistant, blocks: [.init(id: "text", content: .text("Historical"))])], sources: []), execution: context.state.executions[executionID]!, context: context)
            return [.finished(.init(executionID: executionID, status: .completed, assistantMessageID: MessageID(),
                answer: answer, replay: replay))]
        }
        try requireCommitted(finished)
        return .init(id: runtime.id, executionID: executionID, messageID: messageID,
            source: .sessionExecution(sessionID: runtime.id, executionID: executionID), workspaceID: workspaceID)
    }
}

private struct AllowingContextPolicy: AgentContextPolicy {
    func validate(_ request: AgentContextRequest) async throws {}
}

private final class SourceFixture: Sendable {
    enum Kind: String { case active, failed, completedWithoutReplay, completed, cancelledPartial, interruptedThinking }

    let directory: URL
    let library: FileSessionLibrary
    let runtime: SessionRuntime
    let reader: JournalSessionReader
    let sessionID: ConversationID
    let executionID: ExecutionID
    let originalExecutionID: ExecutionID
    let userMessageID: MessageID
    let source: AgentSourceReference
    let workspaceID: WorkspaceID
    let hiddenRetentionGroups: Set<UUID>

    static func make(kind: Kind, executionID: ExecutionID = ExecutionID()) async throws -> SourceFixture {
        try await make(directoryName: "mira-execution-source", kind: kind, executionID: executionID)
    }

    static func makeRetry() async throws -> SourceFixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mira-execution-source-retry-\(UUID().uuidString)")
        let library = try FileSessionLibrary(directory: directory)
        var runtime: SessionRuntime?
        do {
            let sessionID = ConversationID(), originalID = ExecutionID(), retryID = ExecutionID(), messageID = MessageID()
            let workspace = WorkspaceID()
            let opened = try await SessionRuntime.open(id: sessionID, journal: library, payloads: library)
            runtime = opened
            let original = try await admit(opened, executionID: originalID, userMessageID: messageID, workspaceID: workspace, text: "Original")
            _ = try await finish(opened, executionID: originalID, status: .failed, answer: nil, replay: nil)
            let retryCommit = await opened.commit(id: UUID()) { context in
                let retryPlan = try await context.stage(AgentExecutionPlan(runtimeID: UUID(), catalogGeneration: 1,
                    driverID: "mira.default", driverRevision: 1, instructions: "Retry", limits: .init(),
                    priority: .foreground, route: nil), kind: .executionPlan, retentionGroup: UUID())
                let facts: [SessionFact] = [.admitted(.init(executionID: retryID, userMessageID: messageID, retryOfExecutionID: originalID,
                    userBody: nil, plan: retryPlan, hasModelRoute: false, authorizationEpoch: 0, timeZoneIdentifier: "UTC"))]
                return facts
            }
            try requireCommitted(retryCommit)
            let retryPlan = try #require((await opened.snapshot()).executions[retryID]?.admission.plan)
            let replay = AgentReplayRecord(messages: [.init(role: .assistant, blocks: [.init(id: "text", content: .text("Retry answer"))])], sources: [])
            let refs = try await finish(opened, executionID: retryID, status: .completed, answer: "Retry answer", replay: replay)
            let retryReplay = try #require(refs.replay)
            let source = AgentSourceReference.sessionExecution(sessionID: sessionID, executionID: retryID)
            let hidden = Set([original.plan.retentionGroup, retryPlan.retentionGroup, retryReplay.retentionGroup])
            return SourceFixture(directory: directory, library: library, runtime: opened,
                reader: .init(journal: library, payloads: library), sessionID: sessionID,
                executionID: retryID, originalExecutionID: originalID, userMessageID: messageID,
                source: source, workspaceID: workspace, hiddenRetentionGroups: hidden)
        } catch {
            await runtime?.close(); try? await library.close(); try? FileManager.default.removeItem(at: directory); throw error
        }
    }

    private static func make(directoryName: String, kind: Kind, executionID: ExecutionID) async throws -> SourceFixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("\(directoryName)-\(UUID().uuidString)")
        let library = try FileSessionLibrary(directory: directory)
        var runtime: SessionRuntime?
        do {
            let sessionID = ConversationID(), messageID = MessageID(), workspace = WorkspaceID()
            let opened = try await SessionRuntime.open(id: sessionID, journal: library, payloads: library)
            runtime = opened
            let admission = try await admit(opened, executionID: executionID, userMessageID: messageID, workspaceID: workspace, text: "Original")
            var hidden = Set([admission.plan.retentionGroup])
            var refs = CompletionReferences(plan: admission.plan, replay: nil, answer: nil, thinking: nil)
            if kind != .active {
                let replay: AgentReplayRecord? = kind == .completed ? .init(messages: [.init(role: .assistant, blocks: [.init(id: "text", content: .text("Historical"))])], sources: []) : nil
                let partial = kind == .cancelledPartial || kind == .interruptedThinking
                refs = try await finish(opened, executionID: executionID,
                    status: kind == .failed ? .failed : (partial ? (kind == .cancelledPartial ? .cancelled : .interrupted) : .completed),
                    answer: partial && kind == .cancelledPartial ? "Partial answer" : (kind == .completed || kind == .completedWithoutReplay ? "Visible answer" : nil),
                    thinking: kind == .interruptedThinking ? "Partial thought" : nil, replay: replay)
                if let replay = refs.replay { hidden.insert(replay.retentionGroup) }
                if partial {
                    if let answer = refs.answer { hidden.insert(answer.retentionGroup) }
                    if let thinking = refs.thinking { hidden.insert(thinking.retentionGroup) }
                }
            }
            let source = AgentSourceReference.sessionExecution(sessionID: sessionID, executionID: executionID)
            return SourceFixture(directory: directory, library: library, runtime: opened,
                reader: .init(journal: library, payloads: library), sessionID: sessionID,
                executionID: executionID, originalExecutionID: executionID, userMessageID: messageID,
                source: source, workspaceID: workspace, hiddenRetentionGroups: hidden)
        } catch {
            await runtime?.close(); try? await library.close(); try? FileManager.default.removeItem(at: directory); throw error
        }
    }

    private init(directory: URL, library: FileSessionLibrary, runtime: SessionRuntime, reader: JournalSessionReader,
                 sessionID: ConversationID, executionID: ExecutionID, originalExecutionID: ExecutionID,
                 userMessageID: MessageID, source: AgentSourceReference, workspaceID: WorkspaceID,
                 hiddenRetentionGroups: Set<UUID>) {
        self.directory = directory; self.library = library; self.runtime = runtime; self.reader = reader
        self.sessionID = sessionID; self.executionID = executionID; self.originalExecutionID = originalExecutionID
        self.userMessageID = userMessageID; self.source = source; self.workspaceID = workspaceID
        self.hiddenRetentionGroups = hiddenRetentionGroups
    }

    func close() async { await runtime.close(); try? await library.close(); try? FileManager.default.removeItem(at: directory) }

    private struct CompletionReferences { let plan: SessionPayloadReference; let replay: SessionPayloadReference?; let answer: SessionPayloadReference?; let thinking: SessionPayloadReference? }
    private struct AdmissionReferences { let userBody: SessionPayloadReference; let plan: SessionPayloadReference }

    private static func admit(_ runtime: SessionRuntime, executionID: ExecutionID, userMessageID: MessageID,
                              workspaceID: WorkspaceID, text: String) async throws -> AdmissionReferences {
        let result = await runtime.commit(id: UUID()) { context in
            let title = try await context.stageBytes(Data("Session".utf8), kind: .title, retentionGroup: UUID())
            let user = try await context.stageBytes(Data(text.utf8), kind: .userText, retentionGroup: UUID())
            let plan = try await context.stage(AgentExecutionPlan(runtimeID: UUID(), catalogGeneration: 1,
                driverID: "mira.default", driverRevision: 1, instructions: "Local", limits: .init(),
                priority: .foreground, route: nil), kind: .executionPlan, retentionGroup: UUID())
            return [.opened(.init(workspaceID: workspaceID, title: title)),
                    .admitted(.init(executionID: executionID, userMessageID: userMessageID, userBody: user,
                        plan: plan, hasModelRoute: false, authorizationEpoch: 0, timeZoneIdentifier: "UTC"))]
        }
        try requireCommitted(result)
        return try #require((await runtime.snapshot()).executions[executionID].map { .init(userBody: $0.admission.userBody!, plan: $0.admission.plan) })
    }

    private static func finish(_ runtime: SessionRuntime, executionID: ExecutionID, status: ExecutionStatus,
                               answer: String?, thinking: String? = nil, replay: AgentReplayRecord?) async throws -> CompletionReferences {
        let settling = await runtime.commit(id: UUID()) { _ in [.phaseChanged(executionID: executionID, phase: .settling)] }
        try requireCommitted(settling)
        let result = await runtime.commit(id: UUID()) { context in
            let answerRef: SessionPayloadReference?
            if let answer { answerRef = try await context.stageBytes(Data(answer.utf8), kind: .visibleAnswer, retentionGroup: UUID()) }
            else { answerRef = nil }
            let replayRef: SessionPayloadReference?
                if let replay { replayRef = try await AgentReplayManifest.stage(replay, execution: context.state.executions[executionID]!, context: context) }
            else { replayRef = nil }
            let thinkingRef: SessionPayloadReference?
            if let thinking { thinkingRef = try await context.stageBytes(Data(thinking.utf8), kind: .visibleThinking, retentionGroup: UUID()) }
            else { thinkingRef = nil }
            return [.finished(.init(executionID: executionID, status: status,
                assistantMessageID: answer == nil && thinking == nil ? nil : MessageID(), answer: answerRef,
                visibleThinking: thinkingRef, replay: replayRef))]
        }
        try requireCommitted(result)
        let state = await runtime.snapshot(), completion = try #require(state.executions[executionID]?.completion)
        return .init(plan: state.executions[executionID]!.admission.plan, replay: completion.replay,
            answer: completion.answer, thinking: completion.visibleThinking)
    }
}

private func requireCommitted(_ result: SessionCommitResult) throws {
    switch result { case .committed: return; case .notCommitted(let error), .indeterminate(_, let error): throw error }
}

private func expectCode<T>(_ expected: MiraError.Code,
                           operation: () async throws -> T) async {
    do {
        _ = try await operation()
        Issue.record("Expected MiraError.\(expected) but the operation succeeded")
    } catch let error as MiraError {
        #expect(error.code == expected)
    } catch {
        Issue.record("Expected MiraError.\(expected), got \(error)")
    }
}
