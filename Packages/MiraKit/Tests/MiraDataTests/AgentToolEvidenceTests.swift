import Foundation
import Testing

@testable import MiraCore
@testable import MiraData

private let evidenceSchemas: [String: Set<Int>] = ["tests.evidence": [1]]

@Suite("Agent tool evidence", .timeLimit(.minutes(1)))
struct AgentToolEvidenceTests {
    @Test func retryReadUsesOriginalEvidenceAndRetryRoute() async throws {
        let fixture = try await ToolEvidenceFixture.make(mode: .read)
        try await withFixture(fixture) { fixture in
            let resolutions = try await fixture.executor.execute(attemptID: fixture.attemptID,
                                                                  executionID: fixture.retryExecutionID)
            #expect(resolutions.first?.status == .succeeded)
            let context = try #require(await fixture.readProbe.context)
            #expect(context.executionID == fixture.retryExecutionID)
            #expect(context.evidence.reference.originalExecutionID == fixture.originalExecutionID)
            #expect(context.evidence.reference.userMessageID == fixture.userMessageID)
            #expect(context.evidence.text == fixture.userText)
            #expect(context.evidence.admittedAt == fixture.originalAdmissionDate)
            #expect(fixture.retryAdmissionDate > fixture.originalAdmissionDate)
            #expect(context.evidence.timeZoneIdentifier == "Asia/Shanghai")
            let journalEvidence = try await JournalSessionReader(journal: fixture.library, payloads: fixture.library, extensionSchemas: evidenceSchemas)
                .userEvidence(sessionID: fixture.runtime.id, executionID: fixture.retryExecutionID)
            #expect(context.evidence.reference == journalEvidence.reference)
            #expect(context.evidence.workspaceID == journalEvidence.workspaceID)
            #expect(context.evidence.sessionAuthorizationEpoch == journalEvidence.sessionAuthorizationEpoch)
            #expect(context.route == fixture.retryRoute)
            #expect(context.route != fixture.originalRoute)
        }
    }

    @Test func resolverReconstructsEvidenceForDispatchedLocalWrite() async throws {
        let fixture = try await ToolEvidenceFixture.make(mode: .localWrite)
        try await withFixture(fixture) { fixture in
            let proof = try #require(await fixture.proof())
            let resolved = try await fixture.resolver.resolve(proof, requireEligible: true)
            #expect(resolved.context.executionID == fixture.retryExecutionID)
            #expect(resolved.context.invocationID == fixture.invocationID)
            #expect(resolved.context.evidence.reference.originalExecutionID == fixture.originalExecutionID)
            #expect(resolved.context.evidence.text == fixture.userText)
            #expect(resolved.context.evidence.admittedAt == fixture.originalAdmissionDate)
            #expect(resolved.context.evidence.timeZoneIdentifier == "Asia/Shanghai")
            let journalEvidence = try await JournalSessionReader(journal: fixture.library, payloads: fixture.library, extensionSchemas: evidenceSchemas)
                .userEvidence(sessionID: fixture.runtime.id, executionID: fixture.retryExecutionID)
            #expect(resolved.context.evidence.reference == journalEvidence.reference)
            #expect(resolved.context.evidence.reference.admissionEventID == journalEvidence.reference.admissionEventID)
            #expect(resolved.context.evidence.reference.admissionSequence == journalEvidence.reference.admissionSequence)
            #expect(resolved.context.route == fixture.retryRoute)
        }
    }

    @Test func forgedContextEvidenceIsRejectedBeforeBusinessCommit() async throws {
        for tamper in [ToolEvidenceFixture.Tamper.userText, .instructions, .destination] {
            do {
                let fixture = try await ToolEvidenceFixture.make(mode: .localWrite, tamper: tamper)
                try await withFixture(fixture) { fixture in
                    let proof = try #require(await fixture.proof())
                    do {
                        _ = try await fixture.resolver.resolve(proof, requireEligible: true)
                        _ = await fixture.business.commit(proof)
                        Issue.record("A forged tool context reached the business commit boundary")
                    } catch is MiraError {
                        // The resolver is the required journal gate before a business adapter runs.
                    } catch {
                        Issue.record("Unexpected forged-context error: \(error)")
                    }
                    #expect(await fixture.business.commitCount == 0)
                }
            } catch {
                // A forged user text has no canonical message source, so the journal
                // writer rejects it before a business proof can be published.
                if case .userText = tamper {
                    guard let miraError = error as? MiraError, miraError.code == .storage else { throw error }
                    continue
                }
                throw error
            }
        }
    }

    @Test func forgedInstructionsNeverReachesReadTool() async throws {
        for tamper in [ToolEvidenceFixture.Tamper.instructions, .destination] {
            let fixture = try await ToolEvidenceFixture.make(mode: .read, tamper: tamper)
            try await withFixture(fixture) { fixture in
                do {
                    _ = try await fixture.executor.execute(attemptID: fixture.attemptID,
                                                           executionID: fixture.retryExecutionID)
                    Issue.record("A forged prepared request reached the read tool")
                } catch is MiraError {
                    // Context validation precedes preparation and execution.
                } catch {
                    Issue.record("Unexpected forged read request error: \(error)")
                }
                #expect(await fixture.readProbe.prepareCount == 0)
                #expect(await fixture.readProbe.executeCount == 0)
            }
        }
    }
}

private struct AllowToolPolicy: AgentToolPolicy {
    func evaluate(_ proposal: AgentToolProposal, context: AgentToolContext) async throws -> AgentToolPolicyDecision { .allow }
    func validate(_ proposal: AgentToolProposal, context: AgentToolContext) async throws {}
}

private struct AllowEffectAuthority: AgentEffectAuthority {
    let value: AgentLibraryAuthorization
    func authorization(for proposal: AgentToolProposal, context: AgentToolContext) async throws -> AgentLibraryAuthorization { value }
    func validate(_ authorization: AgentLibraryAuthorization, proposal: AgentToolProposal,
                  context: AgentToolContext) async throws {}
}

private actor EvidenceBusiness: AgentBusinessEffects {
    private(set) var commitCount = 0
    func fenceExecution(sessionID: ConversationID, executionID: ExecutionID) async throws {}
    func commit(_ proof: AgentEffectProof) async -> AgentBusinessCommitOutcome {
        commitCount += 1
        return .notCommitted(.init(.unsupported, "The evidence test does not execute business SQL."))
    }
    func receipt(for proof: AgentEffectProof) async -> AgentBusinessReceiptLookup { .absent }
    func unpublished(after receiptID: UUID?, limit: Int) async throws -> [AgentReceiptPublication] { [] }
    func acknowledge(_ receipt: AgentBusinessReceiptReference, at cursor: SessionCursor) async throws {}
}

private actor EvidenceReadProbe {
    private(set) var context: AgentToolContext?
    private(set) var prepareCount = 0
    private(set) var executeCount = 0
    func prepared() { prepareCount += 1 }
    func record(_ context: AgentToolContext) { executeCount += 1; self.context = context }
}

private struct EvidenceReadTool: AgentReadTool {
    let policy: AgentToolPolicyRequirement = .hostOnly
    let descriptor: AgentToolDescriptor
    let probe: EvidenceReadProbe
    func prepare(_ arguments: JSONValue, context: AgentToolContext) async throws -> AgentToolPlan {
        await probe.prepared()
        return .init(input: arguments, sources: [], targets: [])
    }
    func execute(_ plan: AgentToolPlan, context: AgentToolContext) async throws -> JSONValue {
        await probe.record(context)
        return .object(["ok": .bool(true)])
    }
}

private enum FixtureMode { case read, localWrite }

private final class DateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ date: Date) { self.date = date }
    func get() -> Date { lock.lock(); defer { lock.unlock() }; return date }
    func set(_ date: Date) { lock.lock(); self.date = date; lock.unlock() }
}

private final class ToolEvidenceFixture: Sendable {
    enum Tamper { case none, userText, instructions, destination }

    let directory: URL
    let library: FileSessionLibrary
    let runtime: SessionRuntime
    let executor: AgentToolExecutor
    let approvals: RuntimeApprovalService
    let resolver: JournalAgentEffectResolver
    let business: EvidenceBusiness
    let readProbe: EvidenceReadProbe
    let originalExecutionID: ExecutionID
    let retryExecutionID: ExecutionID
    let userMessageID: MessageID
    let userBody: SessionContent
    let attemptID: UUID
    let stepID: UUID
    let invocationID: UUID
    let userText: String
    let originalAdmissionDate: Date
    let retryAdmissionDate: Date
    let originalRoute: AgentModelRoute
    let retryRoute: AgentModelRoute
    let libraryAccessFixture: LibraryAccessFixture

    static func make(mode: FixtureMode, tamper: Tamper = .none) async throws -> ToolEvidenceFixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mira-agent-tool-evidence-\(UUID().uuidString)")
        let library = try FileSessionLibrary(directory: directory)
        var cleanupRuntime: SessionRuntime?
        var cleanupApprovals: RuntimeApprovalService?
        var cleanupAccessFixture: LibraryAccessFixture?
        do {
            let clock = DateBox(Date(timeIntervalSince1970: 1_800_000_000))
            let environment = RuntimeEnvironment(now: { clock.get() }, uuid: { UUID() })
            let sessionID = ConversationID()
            let originalExecutionID = ExecutionID()
            let retryExecutionID = ExecutionID()
            let userMessageID = MessageID()
            let originalRoute = Self.route(adapter: "synthetic.original")
            let retryRoute = Self.route(adapter: "synthetic.retry")
            let runtime = try await SessionRuntime.open(id: sessionID, journal: library, payloads: library,
                                                        environment: environment, extensionSchemas: evidenceSchemas)
            cleanupRuntime = runtime
            let userText = "Original admission text"
            let userBody = try await Self.admitOriginal(runtime: runtime, userText: userText,
                                                        executionID: originalExecutionID,
                                                        userMessageID: userMessageID, route: originalRoute)
            let extensionResult = await runtime.commit(id: UUID()) { command in
                let body = try await command.stageBytes(Data("extension".utf8), kind: .module)
                return [.extensionRecorded(namespace: "tests.evidence", schemaVersion: 1, required: true, body: body)]
            }
            try requireCommitted(extensionResult)
            let originalAdmissionDate = try #require((await runtime.snapshot()).executions[originalExecutionID]?.admittedAt)
            clock.set(originalAdmissionDate.addingTimeInterval(3_600))
            try await Self.admitRetry(runtime: runtime, executionID: originalExecutionID,
                                      retryExecutionID: retryExecutionID, userMessageID: userMessageID,
                                      route: retryRoute)
            let retryAdmissionDate = try #require((await runtime.snapshot()).executions[retryExecutionID]?.admittedAt)
            let descriptor = Self.descriptor(name: "tests.evidence", effect: mode == .read ? .read : .localWrite)
            let probe = EvidenceReadProbe()
            let catalog = try AgentToolCatalog(mode == .read
                ? [.read(EvidenceReadTool(descriptor: descriptor, probe: probe))]
                : [])
            let business = EvidenceBusiness()
            let resolver = JournalAgentEffectResolver(journal: library, payloads: library, extensionSchemas: evidenceSchemas)
            let approvals = RuntimeApprovalService()
            cleanupApprovals = approvals
            let accessFixture = try await LibraryAccessFixture.make()
            cleanupAccessFixture = accessFixture
            let libraryLease = try await accessFixture.acquire()
            let executor = try AgentToolExecutor(runtime: runtime, payloads: library, libraryLease: libraryLease, catalog: catalog,
                policy: AllowToolPolicy(), authorizer: ToolFixtureSourceAuthorizer(),
                authority: AllowEffectAuthority(value: libraryLease.authorization), business: business,
                approvals: approvals, maximumParallelTools: 1, environment: environment)
            let fixture = ToolEvidenceFixture(directory: directory, library: library, runtime: runtime,
                executor: executor, approvals: approvals, resolver: resolver, business: business, readProbe: probe,
                originalExecutionID: originalExecutionID, retryExecutionID: retryExecutionID,
                userMessageID: userMessageID, userBody: userBody, attemptID: UUID(), stepID: UUID(),
                invocationID: UUID(), userText: userText, originalAdmissionDate: originalAdmissionDate,
                retryAdmissionDate: retryAdmissionDate, originalRoute: originalRoute, retryRoute: retryRoute,
                libraryAccessFixture: accessFixture)
            try await fixture.seed(mode: mode, descriptor: descriptor, tamper: tamper)
            return fixture
        } catch {
            await cleanupApprovals?.shutdown()
            await cleanupAccessFixture?.close()
            await cleanupRuntime?.close()
            try? await library.close()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private init(directory: URL, library: FileSessionLibrary, runtime: SessionRuntime,
                 executor: AgentToolExecutor, approvals: RuntimeApprovalService,
                 resolver: JournalAgentEffectResolver, business: EvidenceBusiness,
                 readProbe: EvidenceReadProbe, originalExecutionID: ExecutionID, retryExecutionID: ExecutionID,
                 userMessageID: MessageID, userBody: SessionContent, attemptID: UUID, stepID: UUID,
                 invocationID: UUID, userText: String, originalAdmissionDate: Date,
                 retryAdmissionDate: Date, originalRoute: AgentModelRoute, retryRoute: AgentModelRoute,
                 libraryAccessFixture: LibraryAccessFixture) {
        self.directory = directory; self.library = library; self.runtime = runtime; self.executor = executor; self.approvals = approvals
        self.resolver = resolver; self.business = business; self.readProbe = readProbe
        self.originalExecutionID = originalExecutionID; self.retryExecutionID = retryExecutionID
        self.userMessageID = userMessageID; self.userBody = userBody; self.attemptID = attemptID
        self.stepID = stepID; self.invocationID = invocationID; self.userText = userText
        self.originalAdmissionDate = originalAdmissionDate; self.retryAdmissionDate = retryAdmissionDate
        self.originalRoute = originalRoute; self.retryRoute = retryRoute
        self.libraryAccessFixture = libraryAccessFixture
    }

    private func seed(mode: FixtureMode, descriptor: AgentToolDescriptor, tamper: Tamper) async throws {
        let requestText = tamper == .userText ? "forged text" : userText
        let instructions = tamper == .instructions ? "forged instructions" : "Retry"
        let input = AgentModelInput(stepID: stepID, executionID: retryExecutionID,
            instructions: instructions, messages: [.init(role: .user, blocks: [.init(id: "text", content: .text(userText))])],
            tools: [descriptor.definition])
        let prepared = AgentPreparedModelRequest(adapter: retryRoute.adapter, input: input,
                                                 wirePayload: .object([:]), estimatedInputTokens: 1)
        let request = AgentContextRequest(sessionID: runtime.id, executionID: retryExecutionID,
            workspaceID: Self.workspaceID, userText: requestText, authorizationEpoch: 0, destination: .model(tamper == .destination ? originalRoute : retryRoute))
        let build = AgentContextBuild(request: request, prepared: prepared,
                                       inheritedSources: [], evidence: [], omissions: [])
        let started = await runtime.commit(id: UUID()) { context in
            let reference = try await context.stage(AgentSessionRequest(build), kind: .request)
            return [.phaseChanged(executionID: retryExecutionID, phase: .preparing),
                    .attemptStarted(.init(id: attemptID, executionID: retryExecutionID, stepID: stepID,
                        stepIndex: 1, attemptIndex: 1, request: reference))]
        }
        try requireCommitted(started)
        let settled = await runtime.commit(id: UUID()) { context in
            let callValue = CanonicalToolCall(id: "evidence-call", name: descriptor.definition.name, arguments: "{}")
            let output = try await context.stage(AgentModelOutput(
                blocks: [.init(id: "call", content: .toolCall(callValue))],
                continuation: nil, usage: .init(), finishReason: .toolCalls
            ), kind: .modelOutput)
            let call = try await context.stage(callValue, kind: .toolCall)
            return [.attemptResolved(.init(attemptID: attemptID, status: .completed, output: output)),
                    .toolProposed(.init(id: invocationID, attemptID: attemptID, modelOrder: 0,
                        toolName: descriptor.definition.name, effect: mode == .read ? .read : .localWrite, call: call)),
                    .phaseChanged(executionID: retryExecutionID, phase: .waitingForTools)]
        }
        try requireCommitted(settled)
        guard mode == .localWrite else { return }
        let auth = AgentLibraryAuthorization(libraryID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!, epoch: 0)
        let proposal = AgentToolProposal(descriptor: descriptor, effect: .localWrite, businessNamespace: "tests",
            callDigest: try #require((await runtime.snapshot()).invocations[invocationID]?.invocation.call.digest),
            plan: .init(input: .object([:]), sources: [], targets: []))
        let intent = await runtime.commit(id: UUID()) { context in
            let reference = try await context.stage(proposal, kind: .effectIntent)
            return [.toolPrepared(.init(invocationID: invocationID, authorization: auth, proposal: reference)),
                    .toolDispatched(invocationID: invocationID, authorizationEpoch: 0)]
        }
        try requireCommitted(intent)
    }

    func proof() async throws -> AgentEffectProof? {
        let state = await runtime.snapshot()
        guard let invocation = state.invocations[invocationID], let intent = invocation.intent else { return nil }
        return .init(sessionID: runtime.id, executionID: retryExecutionID, invocationID: invocationID,
            intentBatchID: intent.batchID, intentSequence: intent.sequence,
            authorization: intent.intent.authorization, proposal: intent.intent.proposal)
    }

    func close() async {
        await approvals.shutdown()
        await runtime.close()
        await libraryAccessFixture.close()
        try? await library.close()
        try? FileManager.default.removeItem(at: directory)
    }

    private static let workspaceID = WorkspaceID()

    private static func admitOriginal(runtime: SessionRuntime, userText: String, executionID: ExecutionID,
                                      userMessageID: MessageID, route: AgentModelRoute) async throws -> SessionContent {
        let result = await runtime.commit(id: UUID()) { context in
            let title = try await context.stageBytes(Data("Evidence".utf8), kind: .title)
            let body = try await context.stageBytes(Data(userText.utf8), kind: .userText)
            let plan = try await context.stage(AgentExecutionPlan(runtimeID: UUID(), catalogGeneration: 1,
                driverID: "mira.default", driverRevision: 1, instructions: "Answer", limits: .init(),
                priority: .foreground, route: route), kind: .executionPlan)
            return [.opened(.init(workspaceID: Self.workspaceID, title: title)),
                    .admitted(.init(executionID: executionID, userMessageID: userMessageID, userBody: body,
                        plan: plan, hasModelRoute: true, authorizationEpoch: 0, timeZoneIdentifier: "Asia/Shanghai"))]
        }
        try requireCommitted(result)
        let cancelled = await runtime.commit(id: UUID()) { _ in
            [.phaseChanged(executionID: executionID, phase: .cancelling),
             .finished(.init(executionID: executionID, status: .interrupted))]
        }
        try requireCommitted(cancelled)
        return try #require((await runtime.snapshot()).executions[executionID]?.admission.userBody)
    }

    private static func admitRetry(runtime: SessionRuntime, executionID: ExecutionID, retryExecutionID: ExecutionID,
                                   userMessageID: MessageID, route: AgentModelRoute) async throws {
        let result = await runtime.commit(id: UUID()) { context in
            let plan = try await context.stage(AgentExecutionPlan(runtimeID: UUID(), catalogGeneration: 2,
                driverID: "mira.default", driverRevision: 1, instructions: "Retry", limits: .init(),
                priority: .foreground, route: route), kind: .executionPlan)
            return [.admitted(.init(executionID: retryExecutionID, userMessageID: userMessageID,
                retryOfExecutionID: executionID, userBody: nil, plan: plan, hasModelRoute: true,
                authorizationEpoch: 0, timeZoneIdentifier: "UTC"))]
        }
        try requireCommitted(result)
    }

    private static func route(adapter: String) -> AgentModelRoute {
        .init(id: RouteID(), revision: 1, connectionID: ConnectionID(), connectionRevision: 1,
            modelDescriptorID: ModelDescriptorID(), modelRevision: 1,
            modelAuthorizationRevision: 1, adapter: .init(id: adapter, revision: 1), invocationID: "test-invocation", invocationRevision: 1, endpointID: "test-endpoint", modelID: "fixture", credential: nil,
            contextWindow: 4_096, maximumOutputTokens: 512,
            capabilities: .init(streamsText: true, callsTools: true, producesThinking: true),
            configuration: .object([:]))
    }

    private static func descriptor(name: String, effect: SessionEffectKind) -> AgentToolDescriptor {
        let input: JSONValue = .object(["type": .string("object"), "properties": .object([:]),
            "additionalProperties": .bool(false)])
        let output: JSONValue = .object(["type": .string("object"), "properties": .object(["ok": .object(["type": .string("boolean")])]),
            "required": .array([.string("ok")]), "additionalProperties": .bool(false)])
        return .init(definition: .init(name: name, description: "Evidence tool", inputSchema: input), revision: 1,
            outputSchema: output, executionMode: .exclusive, timeoutMilliseconds: 1_000, maximumResultBytes: 1_024)
    }
}

private func withFixture<T>(_ fixture: ToolEvidenceFixture,
                            _ body: (ToolEvidenceFixture) async throws -> T) async throws -> T {
    do {
        let result = try await body(fixture)
        await fixture.close()
        return result
    } catch {
        await fixture.close()
        throw error
    }
}

private func requireCommitted(_ result: SessionCommitResult) throws {
    switch result {
    case .committed: return
    case .notCommitted(let error), .indeterminate(_, let error): throw error
    }
}
