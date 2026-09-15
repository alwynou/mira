import Foundation
import Testing
@testable import MiraCore
@testable import MiraData

@Suite("Agent execution recovery integration")
struct AgentExecutionRecoveryIntegrationTests {
    @Test func libraryRestorationSettlesPartialDraftLocally() async throws {
        let fixture = try await RecoveryFixture.make(includeAttempt: true)
        await fixture.runtime.close()
        let restoration = AgentLibraryRestoration(
            journal: fixture.library, payloads: fixture.library, receipts: fixture.business,
            authorizer: fixture.authorizer)
        _ = try await restoration.restore()
        let reopened = try await SessionRuntime.open(id: fixture.sessionID,
            journal: fixture.library, payloads: fixture.library)
        let state = await reopened.snapshot()
        #expect(state.executions[fixture.executionID]?.completion?.status == .interrupted)
        let answer = try #require(state.executions[fixture.executionID]?.completion?.answer)
        let thinking = try #require(state.executions[fixture.executionID]?.completion?.visibleThinking)
        #expect(try await fixture.library.read(answer) == Data("partial answer".utf8))
        #expect(try await fixture.library.read(thinking) == Data("partial thinking".utf8))
        #expect(await fixture.journalFactCount(.toolDispatched) == 0)
        #expect(await fixture.authorizer.localValidationCount > 0)
        await reopened.close()
        await restoration.close()
        await fixture.close()
    }

    @Test func libraryRestorationSuppressesRevokedDraftContent() async throws {
        let fixture = try await RecoveryFixture.make(includeAttempt: true)
        await fixture.authorizer.set(.unauthorized)
        await fixture.runtime.close()
        let restoration = AgentLibraryRestoration(
            journal: fixture.library, payloads: fixture.library, receipts: fixture.business,
            authorizer: fixture.authorizer)
        _ = try await restoration.restore()
        let reopened = try await SessionRuntime.open(id: fixture.sessionID,
            journal: fixture.library, payloads: fixture.library)
        let completion = try #require(await reopened.snapshot().executions[fixture.executionID]?.completion)
        #expect(completion.status == .interrupted)
        #expect(completion.answer == nil)
        #expect(completion.visibleThinking == nil)
        await reopened.close()
        await restoration.close()
        await fixture.close()
    }

    @Test func libraryRestorationLeavesSessionUnsettledOnUnavailableAuthority() async throws {
        let fixture = try await RecoveryFixture.make(includeAttempt: true)
        await fixture.authorizer.set(.storage)
        await fixture.runtime.close()
        let restoration = AgentLibraryRestoration(
            journal: fixture.library, payloads: fixture.library, receipts: fixture.business,
            authorizer: fixture.authorizer)
        do {
            _ = try await restoration.restore()
            Issue.record("Unavailable source authority was treated as a revocation")
        } catch let error as MiraError {
            #expect(error.code == .storage)
        }
        let pending = try await SessionRuntime.open(id: fixture.sessionID,
            journal: fixture.library, payloads: fixture.library)
        #expect(await pending.snapshot().executions[fixture.executionID]?.completion == nil)
        await pending.close()
        await fixture.authorizer.set(.allow)
        _ = try await restoration.restore()
        await restoration.close()
        await fixture.close()
    }

    @Test func queuedExecutionIsInterruptedByRecoveryWithoutDispatch() async throws {
        let fixture = try await RecoveryFixture.make(includeAttempt: false)
        let recovery = fixture.recovery()
        let result = await recovery.settle()
        guard case .committed = result else {
            Issue.record("Queued recovery did not commit interruption: \(result)")
            await fixture.close()
            return
        }
        let state = await fixture.runtime.snapshot()
        guard let execution = state.executions[fixture.executionID] else {
            Issue.record("Queued recovery lost the execution state.")
            await fixture.close()
            return
        }
        #expect(execution.completion?.status == .interrupted)
        #expect(execution.attemptIDs.isEmpty)
        #expect(await fixture.business.fenceCount == 1)
        #expect(await fixture.journalFactCount(.toolDispatched) == 0)
        await fixture.close()
    }

    @Test func closedRuntimeStopsRecoveryWithoutClaimingCompletion() async throws {
        let fixture = try await RecoveryFixture.make(includeAttempt: false)
        await fixture.runtime.close()
        let result = await fixture.recovery().settle()
        guard case .notCommitted(let error) = result else {
            Issue.record("Closed recovery returned an unexpected result: \(result)")
            await fixture.close()
            return
        }
        #expect(error.code == .interrupted)
        await fixture.close()
    }

    @Test func partialAttemptRecoversAndReopensFromRealJournal() async throws {
        let fixture = try await RecoveryFixture.make(includeAttempt: true)
        let result = await fixture.recovery().settle()
        guard case .committed = result else {
            Issue.record("Partial recovery did not commit interruption: \(result)")
            await fixture.close()
            return
        }
        let original = await fixture.runtime.snapshot()
        guard let execution = original.executions[fixture.executionID],
              let completion = execution.completion,
              completion.status == .interrupted,
              let answer = completion.answer,
              let thinking = completion.visibleThinking else {
            Issue.record("Recovery did not persist the interrupted draft contents.")
            await fixture.close()
            return
        }
        #expect(try await fixture.library.read(answer) == Data("partial answer".utf8))
        #expect(try await fixture.library.read(thinking) == Data("partial thinking".utf8))
        #expect(await fixture.journalFactCount(.attemptResolved) == 1)

        let directory = fixture.directory
        let sessionID = fixture.sessionID
        do {
            await fixture.runtime.close()
            try await fixture.library.close()
            let reopenedLibrary = try FileSessionLibrary(directory: directory)
            let reopened = try await SessionRuntime.open(id: sessionID, journal: reopenedLibrary, payloads: reopenedLibrary)
            let reopenedState = await reopened.snapshot()
            #expect(reopenedState == original)
            await reopened.close()
            try await reopenedLibrary.close()
            try? FileManager.default.removeItem(at: directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    @Test func unauthorizedRecoverySuppressesPartialVisibleContent() async throws {
        let fixture = try await RecoveryFixture.make(includeAttempt: true)
        await fixture.authorizer.set(.unauthorized)
        let result = await fixture.recovery().settle()
        guard case .committed = result else {
            Issue.record("Unauthorized recovery did not settle the execution: \(result)")
            await fixture.close()
            return
        }
        let state = await fixture.runtime.snapshot()
        let completion = try #require(state.executions[fixture.executionID]?.completion)
        #expect(completion.status == .interrupted)
        #expect(completion.answer == nil)
        #expect(completion.visibleThinking == nil)
        #expect(completion.replay == nil)
        let error = try #require(completion.error)
        #expect(try SessionCodec.decode(MiraError.self, from: await fixture.library.read(error)).code == .unauthorized)
        await fixture.close()
    }

    @Test func storageFailureRetainsSettlementUntilAuthorizationRecovers() async throws {
        let fixture = try await RecoveryFixture.make(includeAttempt: true)
        let recovery = fixture.recovery()
        await fixture.authorizer.set(.storage)
        let first = await recovery.settle()
        guard case .notCommitted(let error) = first else {
            Issue.record("Storage failure unexpectedly settled recovery: \(first)")
            await fixture.close()
            return
        }
        #expect(error.code == .storage)
        let pending = await fixture.runtime.snapshot()
        #expect(pending.executions[fixture.executionID]?.completion == nil)
        #expect(await fixture.journalFactCount(.finished) == 0)
        await fixture.authorizer.set(.allow)
        let second = await recovery.settle()
        guard case .committed = second else {
            Issue.record("Recovery did not retry the original settlement: \(second)")
            await fixture.close()
            return
        }
        #expect(await fixture.journalFactCount(.finished) == 1)
        #expect(await fixture.journalFactCount(.attemptStarted) == 1)
        #expect(await fixture.business.fenceCount == 1)
        await fixture.close()
    }

    @Test func uncertainTerminalSettlementRetriesOriginalCommandWithoutRedispatch() async throws {
        let fault = RecoveryFault()
        let fixture = try await RecoveryFixture.make(includeAttempt: true, fault: fault)
        fault.arm()
        let recovery = fixture.recovery()
        let first = await recovery.settle()
        guard case .indeterminate(let uncertainBatchID, _) = first else {
            Issue.record("Expected terminal settlement to remain indeterminate: \(first)")
            await fixture.close()
            return
        }
        let sequenceBeforeRetry = await fixture.runtime.snapshot().sequence
        let second = await recovery.settle()
        guard case .committed = second else {
            Issue.record("Recovery retry did not reconcile the original command: \(second)")
            await fixture.close()
            return
        }
        let state = await fixture.runtime.snapshot()
        #expect(state.sequence > sequenceBeforeRetry)
        #expect(state.executions[fixture.executionID]?.completion?.status == .interrupted)
        #expect(await fixture.journalFactCount(.finished) == 1)
        #expect(await fixture.journalFactCount(.toolDispatched) == 0)
        #expect(await fixture.business.fenceCount == 1)
        let batches = try await fixture.library.read(sessionID: fixture.sessionID, after: 0,
                                                     limit: SessionFormatLimits.maximumReadBatches)
        guard let terminalBatch = batches.first(where: { $0.id == uncertainBatchID }) else {
            Issue.record("The terminal retry did not retain its original batch identity.")
            await fixture.close()
            return
        }
        #expect(terminalBatch.events.contains { event in
            if case .finished = event.fact { return true }
            return false
        })
        await fixture.close()
    }
}

private final class RecoveryFault: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false
    private var used = false

    func arm() {
        lock.lock(); defer { lock.unlock() }
        armed = true
    }

    func inject(_ stage: SessionStorageFaultStage) throws {
        lock.lock(); defer { lock.unlock() }
        guard armed, !used, stage == .afterJournalSync else { return }
        used = true
        throw MiraError(.storage, "Synthetic terminal append uncertainty.")
    }
}

private actor RecoveryBusiness: AgentBusinessReceipts {
    private(set) var fenceCount = 0

    func fenceExecution(sessionID: ConversationID, executionID: ExecutionID) async throws { fenceCount += 1 }
    func receipt(for proof: AgentEffectProof) async -> AgentBusinessReceiptLookup { .absent }
    func unpublished(after receiptID: UUID?, limit: Int) async throws -> [AgentReceiptPublication] { [] }
    func acknowledge(_ receipt: AgentBusinessReceiptReference, at cursor: SessionCursor) async throws {}
}

private actor RecoveryAuthorizer: AgentSourceAuthorizer {
    enum Decision: Sendable { case allow, unauthorized, storage }
    private var decision: Decision = .allow
    private(set) var localValidationCount = 0

    func set(_ decision: Decision) { self.decision = decision }
    func validate(_ sources: [AgentSourceReference], for request: AgentContextRequest) async throws {
        if case .local = request.destination { localValidationCount += 1 }
        switch decision {
        case .allow: return
        case .unauthorized: throw MiraError(.unauthorized, "Synthetic source authorization was revoked.")
        case .storage: throw MiraError(.storage, "Synthetic source authorization storage failed.")
        }
    }
}

private final class RecoveryFixture: Sendable {
    let directory: URL
    let library: FileSessionLibrary
    let runtime: SessionRuntime
    let sessionID: ConversationID
    let executionID: ExecutionID
    let business: RecoveryBusiness
    let authorizer: RecoveryAuthorizer
    let fault: RecoveryFault?

    private init(directory: URL, library: FileSessionLibrary, runtime: SessionRuntime,
                 sessionID: ConversationID, executionID: ExecutionID,
                 business: RecoveryBusiness, authorizer: RecoveryAuthorizer, fault: RecoveryFault?) {
        self.directory = directory; self.library = library; self.runtime = runtime
        self.sessionID = sessionID; self.executionID = executionID
        self.business = business; self.authorizer = authorizer; self.fault = fault
    }

    static func make(includeAttempt: Bool, fault: RecoveryFault? = nil) async throws -> RecoveryFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mira-recovery-\(UUID().uuidString)")
        let library: FileSessionLibrary
        if let fault {
            library = try FileSessionLibrary(directory: directory, faultInjector: { stage in try fault.inject(stage) })
        } else {
            library = try FileSessionLibrary(directory: directory)
        }
        let sessionID = ConversationID(), executionID = ExecutionID()
        let runtime = try await SessionRuntime.open(id: sessionID, journal: library, payloads: library)
        let business = RecoveryBusiness()
        let authorizer = RecoveryAuthorizer()
        let fixture = RecoveryFixture(directory: directory, library: library, runtime: runtime,
            sessionID: sessionID, executionID: executionID, business: business, authorizer: authorizer, fault: fault)
        let admittedRoute = includeAttempt ? Self.route() : nil
        let committed = await runtime.commit(id: UUID()) { context in
            let title = try await context.stageBytes(Data("Recovery test".utf8), kind: .title, retentionGroup: UUID())
            let user = try await context.stageBytes(Data("Recover this".utf8), kind: .userText, retentionGroup: UUID())
            let plan = AgentExecutionPlan(runtimeID: UUID(), catalogGeneration: 1,
                driverID: "mira.default", driverRevision: 1, instructions: "Recover.", limits: .init(),
                priority: .foreground, route: admittedRoute)
            let planReference = try await context.stage(plan, kind: .executionPlan, retentionGroup: UUID())
            return [.opened(.init(workspaceID: nil, title: title)),
                    .admitted(.init(executionID: executionID, userMessageID: MessageID(),
                        userBody: user, plan: planReference, hasModelRoute: admittedRoute != nil,
                        authorizationEpoch: 0, timeZoneIdentifier: "UTC"))]
        }
        try requireCommitted(committed, stage: "admission")
        if includeAttempt {
            let attemptID = UUID()
            let stepID = UUID()
            let route = try #require(admittedRoute)
            let request = AgentContextRequest(sessionID: sessionID, executionID: executionID, workspaceID: nil,
                userText: "Recover this", authorizationEpoch: 0, destination: .model(route))
            let input = AgentModelInput(stepID: stepID, executionID: executionID, instructions: "Recover.",
                messages: [.init(role: .user, blocks: [.init(id: "text", content: .text("Recover this"))])], tools: [])
            let build = AgentContextBuild(request: request,
                prepared: .init(adapter: route.adapter, input: input, wirePayload: .object([:]), estimatedInputTokens: 1),
                inheritedSources: [], evidence: [], omissions: [])
            let started = await runtime.commit(id: UUID()) { context in
                let request = try await context.stage(build, kind: .request, retentionGroup: UUID())
                return [.phaseChanged(executionID: executionID, phase: .preparing),
                        .attemptStarted(.init(id: attemptID, executionID: executionID, stepID: stepID,
                            stepIndex: 1, attemptIndex: 1, request: request))]
            }
            try requireCommitted(started, stage: "attempt")
            let answer = Data("partial answer".utf8), thinking = Data("partial thinking".utf8)
            let checkpoint = await runtime.commit(id: UUID()) { context in
                let answerReference = try await context.stageBytes(answer, kind: .draft, retentionGroup: UUID())
                let thinkingReference = try await context.stageBytes(thinking, kind: .draft, retentionGroup: UUID())
                return [.draftCheckpoint(.init(executionID: executionID, attemptID: attemptID, part: .answer,
                            baseSequence: nil, prefixByteCount: 0, suffixByteCount: 0,
                            replacement: answerReference, resultByteCount: answer.count)),
                        .draftCheckpoint(.init(executionID: executionID, attemptID: attemptID, part: .thinking,
                            baseSequence: nil, prefixByteCount: 0, suffixByteCount: 0,
                            replacement: thinkingReference, resultByteCount: thinking.count))]
            }
            try requireCommitted(checkpoint, stage: "draft")
        }
        return fixture
    }

    private static func route() -> AgentModelRoute {
        .init(id: RouteID(), revision: 1, connectionID: ConnectionID(), connectionRevision: 1,
              modelDescriptorID: ModelDescriptorID(), modelRevision: 1,
              modelAuthorizationRevision: 1, adapter: .init(id: "synthetic.model", revision: 1), invocationID: "test-invocation", invocationRevision: 1, endpointID: "test-endpoint", metadataEvidence: [], modelID: "synthetic",
              credential: nil, contextWindow: 4_096, maximumOutputTokens: 128,
              capabilities: .init(streamsText: true, callsTools: false, producesThinking: false),
              configuration: .object([:]))
    }

    func recovery() -> AgentExecutionRecovery {
        .init(runtime: runtime, journal: library, payloads: library, executionID: executionID,
              business: business, authorizer: authorizer, environment: .init())
    }

    func journalFactCount(_ predicate: FactKind) async -> Int {
        let batches = (try? await library.read(sessionID: sessionID, after: 0,
                                                limit: SessionFormatLimits.maximumReadBatches)) ?? []
        return batches.flatMap(\.events).filter { predicate.matches($0.fact) }.count
    }

    func close() async {
        await runtime.close()
        try? await library.close()
        try? FileManager.default.removeItem(at: directory)
    }

    private static func requireCommitted(_ result: SessionCommitResult, stage: String) throws {
        guard case .committed = result else { throw MiraError(.storage, "Recovery fixture \(stage) setup did not commit: \(result)") }
    }
}

private enum FactKind {
    case toolDispatched, attemptResolved, finished, attemptStarted

    func matches(_ fact: SessionFact) -> Bool {
        switch (self, fact) {
        case (.toolDispatched, .toolDispatched): true
        case (.attemptResolved, .attemptResolved): true
        case (.finished, .finished): true
        case (.attemptStarted, .attemptStarted): true
        default: false
        }
    }
}
