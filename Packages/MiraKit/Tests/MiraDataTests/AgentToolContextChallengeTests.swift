import Foundation
import GRDB
import MiraCore
import MiraData
import Testing

@Suite("Public tool and context extension challenge", .timeLimit(.minutes(1)))
struct AgentToolContextChallengeTests {
    @Test func approvedExtensionCommitsOneReceiptAndSurvivesProjectionRebuild() async throws {
        try await withToolContextChallenge(uncertainCommit: true) { f in
            let command = f.command()
            try challengeCommitted(await f.application.submit(command))
            let approval = try await f.waitForApproval()
            #expect(approval.executionID == command.executionID)
            #expect(try await f.counter() == 0)
            try await f.resolve(approval, decision: .approved)
            try challengeCommitted(
                await f.application.waitForExecution(id: command.executionID, sessionID: command.sessionID))
            let state = try await f.application.sessionSnapshot(id: command.sessionID)
            let invocation = try #require(state.invocations.values.first)
            #expect(invocation.resolution?.status == .succeeded)
            let receipt = try #require(invocation.resolution?.businessReceipt)
            #expect(receipt.invocationID == invocation.invocation.id)
            #expect(try await f.counter() == 3)
            #expect(await f.data.model.inputs.count == 2)
            let input = try #require(await f.data.model.inputs.first)
            #expect(input.instructions == "Use the registered counter extension.")
            #expect(input.messages.contains { $0.role == .context && $0.text.contains("Extension-owned source") })
            #expect(input.tools.map(\.name) == [CounterExtensionTool.name])
            let request = try #require(state.attempts.values.min(by: { $0.sequence < $1.sequence })?.attempt.request)
            let build = try SessionCodec.decode(AgentRequestRecord.self, from: await f.data.library.read(request))
            #expect(
                build.evidence.contains { $0.contributorID == CounterSource.id && $0.sources == [f.source.reference] })
            #expect(build.sources.contains(f.source.reference))
            #expect(try await f.business.unpublished(after: nil, limit: 10).isEmpty)

            try challengeCommitted(await f.application.submit(command))
            #expect(try await f.counter() == 3)
            #expect(await f.data.model.inputs.count == 2)
            #expect(try await f.application.sessionSnapshot(id: command.sessionID) == state)
            let projection = try SQLiteSessionProjection(
                path: f.data.directory.appendingPathComponent("extension-query.sqlite").path)
            let coordinator = try SessionProjectionCoordinator(journal: f.data.library, projection: projection)
            do {
                _ = try await coordinator.rebuild(sessionID: command.sessionID)
                _ = try await coordinator.rebuild(sessionID: command.sessionID)
                #expect(try await f.counter() == 3)
                #expect(await f.data.model.inputs.count == 2)
                await coordinator.close()
                try await projection.close()
            } catch {
                await coordinator.close()
                try? await projection.close()
                throw error
            }
            #expect(await f.application.shutdown().isSettled)
            let snapshot = try await JournalSessionReader(journal: f.data.library, payloads: f.data.library).snapshot(
                sessionID: command.sessionID)
            #expect(snapshot.state == state)
        }
    }

    @Test func userDenialPreventsTheNewBusinessHandler() async throws {
        try await withToolContextChallenge { f in
            let command = f.command()
            try challengeCommitted(await f.application.submit(command))
            let approval = try await f.waitForApproval()
            try await f.resolve(approval, decision: .denied)
            try challengeCommitted(
                await f.application.waitForExecution(id: command.executionID, sessionID: command.sessionID))
            let state = try await f.application.sessionSnapshot(id: command.sessionID)
            #expect(state.invocations.values.first?.resolution?.status == .denied)
            #expect(state.invocations.values.first?.resolution?.businessReceipt == nil)
            #expect(try await f.counter() == 0)
        }
    }

    @Test func moduleRevocationAfterApprovalRequestCannotBeOverriddenByApproval() async throws {
        try await withToolContextChallenge { f in
            let command = f.command()
            try challengeCommitted(await f.application.submit(command))
            let approval = try await f.waitForApproval()
            await f.policy.revoke()
            try await f.resolve(approval, decision: .approved)
            try challengeCommitted(
                await f.application.waitForExecution(id: command.executionID, sessionID: command.sessionID))
            let invocation = try #require(
                try await f.application.sessionSnapshot(id: command.sessionID).invocations.values.first)
            #expect(invocation.resolution?.status != .succeeded)
            #expect(invocation.resolution?.businessReceipt == nil)
            #expect(try await f.counter() == 0)
        }
    }

    @Test func invalidExtensionOutputRollsBackItsDomainWriteAndReceipt() async throws {
        try await withToolContextChallenge(invalidOutput: true) { f in
            let command = f.command()
            try challengeCommitted(await f.application.submit(command))
            let approval = try await f.waitForApproval()
            try await f.resolve(approval, decision: .approved)
            try challengeCommitted(
                await f.application.waitForExecution(id: command.executionID, sessionID: command.sessionID))
            let invocation = try #require(
                try await f.application.sessionSnapshot(id: command.sessionID).invocations.values.first)
            #expect(invocation.resolution?.status == .failed)
            #expect(invocation.resolution?.businessReceipt == nil)
            #expect(try await f.counter() == 0)
            #expect(try await f.business.unpublished(after: nil, limit: 10).isEmpty)
        }
    }

    @Test func invalidExtensionInputNeverRequestsApprovalOrCommitsBusinessWork() async throws {
        try await withToolContextChallenge(arguments: "{\"amount\":6}") { f in
            let command = f.command()
            try challengeCommitted(await f.application.submit(command))
            try challengeCommitted(
                await f.application.waitForExecution(id: command.executionID, sessionID: command.sessionID))
            let invocation = try #require(
                try await f.application.sessionSnapshot(id: command.sessionID).invocations.values.first)
            #expect(invocation.resolution?.status == .invalidArguments)
            #expect(invocation.resolution?.businessReceipt == nil)
            #expect(await f.requests.value == nil)
            #expect(try await f.counter() == 0)
            #expect(try await f.business.unpublished(after: nil, limit: 10).isEmpty)
        }
    }

    @Test func optionalSourceRevocationIsOmittedAndDoesNotBecomeTrustedInstructions() async throws {
        try await withToolContextChallenge { f in
            await f.source.revoke()
            let command = f.command()
            try challengeCommitted(await f.application.submit(command))
            let approval = try await f.waitForApproval()
            try await f.resolve(approval, decision: .denied)
            try challengeCommitted(
                await f.application.waitForExecution(id: command.executionID, sessionID: command.sessionID))
            let state = try await f.application.sessionSnapshot(id: command.sessionID)
            let request = try #require(state.attempts.values.min(by: { $0.sequence < $1.sequence })?.attempt.request)
            let build = try SessionCodec.decode(AgentRequestRecord.self, from: await f.data.library.read(request))
            #expect(build.evidence.isEmpty)
            #expect(build.omissions.contains { $0.contributorID == CounterSource.id && $0.reason == .unauthorized })
            #expect(
                await f.data.model.inputs.allSatisfy { input in
                    input.messages.allSatisfy { $0.role != .context } && !input.instructions.contains("Extension-owned")
                })
            #expect(try await f.counter() == 0)
        }
    }
}

private struct ToolContextChallengeFixture {
    let data: TaskWorkflowFixture
    let application: AgentApplicationRuntime
    let business: SQLiteBusinessEffects
    let approvals: RuntimeApprovalService
    let requests: ChallengeApprovalProbe
    let policy: CounterExtensionPolicy
    let source: CounterSource
    func command() -> AgentSubmitCommand {
        .init(
            id: UUID(), sessionID: .init(), executionID: .init(),
            input: .message(id: .init(), text: "Increment the counter by three.", timeZoneIdentifier: "UTC"),
            options: .init(instructions: "Use the registered counter extension.", route: data.route),
            opening: .init(title: "Extension challenge", workspaceID: nil))
    }
    func waitForApproval() async throws -> RuntimeApprovalRequest {
        try await taskEventually { await requests.value != nil }
        return try #require(await requests.value)
    }
    func resolve(_ request: RuntimeApprovalRequest, decision: RuntimeApprovalDecision) async throws {
        try await approvals.resolve(
            id: request.id, proposalHash: request.proposalHash,
            authorizationEpoch: request.authorizationEpoch, decision: decision)
    }
    func counter() async throws -> Int {
        try await data.database.read { db in
            try Int.fetchOne(db, sql: "SELECT value FROM challenge_counter WHERE id = 1") ?? -1
        }
    }
}

private func withToolContextChallenge(
    uncertainCommit: Bool = false, invalidOutput: Bool = false,
    arguments: String = "{\"amount\":3}",
    _ body: (ToolContextChallengeFixture) async throws -> Void
) async throws {
    let outputs: [[AgentModelStreamEvent]] = [
        [
            .blockStarted(.init(id: "tool-0", content: .toolCall(.init(id: "counter-call", name: CounterExtensionTool.name, arguments: arguments)))),
            .blockFinished(id: "tool-0"), .finished(.toolCalls),
        ],
        [.blockStarted(.init(id: "text", content: .text("Extension result recorded."))), .blockFinished(id: "text"), .finished(.stop)],
    ]
    try await withTaskWorkflow(outputs: outputs) { f in
        try await runToolContextChallenge(data: f, uncertainCommit: uncertainCommit, invalidOutput: invalidOutput, body)
    }
}

private func runToolContextChallenge(
    data f: TaskWorkflowFixture, uncertainCommit: Bool, invalidOutput: Bool,
    _ body: (ToolContextChallengeFixture) async throws -> Void
) async throws {
    #expect(await f.runtime.shutdown().isSettled)
    try await f.database.write { db in
        try db.execute(
            sql:
                "CREATE TABLE challenge_counter(id INTEGER PRIMARY KEY CHECK(id=1), value INTEGER NOT NULL); INSERT INTO challenge_counter VALUES(1,0)"
        )
    }
    let policy = CounterExtensionPolicy()
    let source = CounterSource()
    let registry = RuntimeRegistry<AgentCapability>()
    let module = CounterChallengeModule(
        registry: registry, domains: f.sourceAuthorities,
        model: f.model, policy: policy, source: source)
    let lostAcknowledgement: (@Sendable () throws -> Void)?
    if uncertainCommit {
        lostAcknowledgement = { @Sendable in throw MiraError(.storage, "Synthetic acknowledgement loss.") }
    } else {
        lostAcknowledgement = nil
    }
    let business = try SQLiteBusinessEffects(
        database: f.database, libraryID: f.authority.libraryID,
        resolver: JournalAgentEffectResolver(journal: f.library, payloads: f.library),
        handlers: [CounterExtensionHandler(invalidOutput: invalidOutput)], validator: CounterExtensionValidator(),
        afterCommitHook: lostAcknowledgement)
    let scheduler = RuntimeScheduler()
    let approvals = RuntimeApprovalService(environment: .init(now: { TaskWorkflowFixture.now }))
    let stream = await approvals.snapshots()
    let requests = ChallengeApprovalProbe()
    let observing = Task { for await values in stream { if let value = values.first { await requests.record(value) } } }
    var application: AgentApplicationRuntime?
    do {
        let app = try await AgentApplicationRuntime.open(
            journal: f.library, payloads: f.library, libraryAccess: f.access,
            registry: registry, modules: [module], policy: ChallengeHostPolicy(), authority: business,
            business: business,
            authorizer: f.authorizer, approvals: approvals, scheduler: scheduler,
            environment: .init(now: { TaskWorkflowFixture.now }))
        application = app
        try await body(
            .init(
                data: f, application: app, business: business, approvals: approvals,
                requests: requests, policy: policy, source: source))
        #expect(await app.shutdown().isSettled)
        await approvals.shutdown()
        observing.cancel()
        await observing.value
        try await business.close()
        let snapshot = try await registry.freeze()
        #expect(snapshot.entries.isEmpty)
        await snapshot.release()
        #expect(await source.closed)
    } catch {
        _ = await application?.shutdown()
        await approvals.shutdown()
        observing.cancel()
        await observing.value
        await scheduler.shutdown()
        try? await business.close()
        throw error
    }
}

private actor ChallengeApprovalProbe {
    private(set) var value: RuntimeApprovalRequest?
    func record(_ value: RuntimeApprovalRequest) { self.value = value }
}
private struct ChallengeHostPolicy: AgentToolPolicy {
    func evaluate(_ proposal: AgentToolProposal, context: AgentToolContext) async throws -> AgentToolPolicyDecision {
        .allow
    }
    func validate(_ proposal: AgentToolProposal, context: AgentToolContext) async throws {}
}
private actor CounterExtensionPolicy: AgentToolPolicy {
    private var allowed = true
    func revoke() { allowed = false }
    func evaluate(_ proposal: AgentToolProposal, context: AgentToolContext) async throws -> AgentToolPolicyDecision {
        guard allowed else { return .deny }
        return .requireApproval(
            prompt: "Approve the counter extension write?", expiresAt: TaskWorkflowFixture.now.addingTimeInterval(60))
    }
    func validate(_ proposal: AgentToolProposal, context: AgentToolContext) async throws {
        guard allowed else { throw MiraError(.unauthorized, "Synthetic extension policy was revoked.") }
    }
}
private struct CounterExtensionTool: AgentLocalWriteTool {
    static let name = "challenge.counter.increment"
    let businessNamespace = "challenge.counter"
    let gate: CounterExtensionPolicy
    var policy: AgentToolPolicyRequirement { .constrained(gate) }
    var descriptor: AgentToolDescriptor {
        .init(
            definition: .init(
                name: Self.name, description: "Increment the isolated challenge counter.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "amount": .object(["type": .string("integer"), "minimum": .number(1), "maximum": .number(5)])
                    ]),
                    "required": .array([.string("amount")]), "additionalProperties": .bool(false),
                ])),
            revision: 1,
            outputSchema: .object([
                "type": .string("object"), "properties": .object(["value": .object(["type": .string("integer")])]),
                "required": .array([.string("value")]), "additionalProperties": .bool(false),
            ]),
            executionMode: .exclusive, timeoutMilliseconds: 1_000, maximumResultBytes: 1_024)
    }
    func prepare(_ arguments: JSONValue, context: AgentToolContext) async throws -> AgentToolPlan {
        .init(input: arguments, sources: [], targets: [])
    }
}
private struct CounterExtensionHandler: SQLiteBusinessCommandHandler {
    let namespace = "challenge.counter"
    let invalidOutput: Bool
    func businessKey(for effect: AgentResolvedEffect) throws -> String { effect.context.invocationID.uuidString }
    func apply(effect: AgentResolvedEffect, in db: Database) throws -> JSONValue {
        guard case .number(let amount) = effect.proposal.plan.input["amount"] else {
            throw MiraError(.invalidInput, "Synthetic counter amount is absent.")
        }
        try db.execute(sql: "UPDATE challenge_counter SET value = value + ? WHERE id = 1", arguments: [Int(amount)])
        let value = try Int.fetchOne(db, sql: "SELECT value FROM challenge_counter WHERE id = 1") ?? 0
        return invalidOutput ? .object(["wrong": .number(Double(value))]) : .object(["value": .number(Double(value))])
    }
}
private struct CounterExtensionValidator: SQLiteBusinessAuthorizationValidator {
    func validate(effect: AgentResolvedEffect, isReplay: Bool, in db: Database) throws {
        guard effect.proposal.descriptor.definition.name == CounterExtensionTool.name,
            effect.proposal.businessNamespace == "challenge.counter", effect.proposal.effect == .localWrite
        else {
            throw MiraError(.unauthorized, "Synthetic counter authority rejected the command.")
        }
    }
}
private actor CounterSource: AgentContextContributor, AgentDomainSourceAuthority {
    static let id: String = "challenge.context"
    nonisolated var id: String { CounterSource.id }
    nonisolated let namespace = "challenge.context"
    nonisolated let isRequired = false
    nonisolated let reference = AgentSourceReference.domain(namespace: "challenge.context", id: UUID(), revision: 1)
    private var allowed = true
    private(set) var closed = false
    func revoke() { allowed = false }
    func close() { closed = true }
    func contribute(to request: AgentContextRequest) async throws -> [AgentContextItem] {
        guard !closed else { throw MiraError(.cancelled, "Synthetic context module is closed.") }
        return [
            .init(id: "counter.source", text: "Extension-owned source: keep the counter local.", sources: [reference])
        ]
    }
    func validate(_ sources: [AgentSourceReference], for request: AgentContextRequest) async throws {
        guard allowed, !closed, request.workspaceID == nil, sources.allSatisfy({ $0 == reference }) else {
            throw MiraError(.unauthorized, "Synthetic context source was revoked.")
        }
    }
}
private struct CounterChallengeModule: RuntimeModule {
    let id = "challenge.counter-module"
    let dependencies: Set<String> = []
    let registry: RuntimeRegistry<AgentCapability>
    let domains: RuntimeRegistry<any AgentDomainSourceAuthority>
    let model: TaskModelFixture
    let policy: CounterExtensionPolicy
    let source: CounterSource
    func activate(in scope: RuntimeScope) async throws {
        try await scope.registerCleanup { await source.close() }
        try await registry.register(id: "challenge.model", value: .model(model), scope: scope)
        try await registry.register(id: "challenge.driver", value: .driver(DefaultAgentDriver()), scope: scope)
        try await registry.register(
            id: "challenge.tool", value: .tool(.localWrite(CounterExtensionTool(gate: policy))), scope: scope)
        try await registry.register(id: "challenge.context", value: .context(source), scope: scope)
        try await domains.register(id: source.namespace, value: source, scope: scope)
    }
}
private func challengeCommitted(_ result: SessionCommitResult) throws {
    if case .committed = result { return }
    if case .notCommitted(let error) = result { throw error }
    throw MiraError(.storage, "Synthetic challenge did not commit.")
}
