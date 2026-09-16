import Foundation
import Testing
import GRDB
@testable import MiraCore
@testable import MiraData

@Suite("Agent tool executor integration")
struct AgentToolExecutorIntegrationTests {
    @Test(arguments: [1, 2, 3])
    func inheritedSourceRevocationPreventsLocalWrite(check: Int) async throws {
        let authorizer = RevokingToolSourceAuthorizer(rejectOnCheck: check)
        let fixture = try await ToolExecutorFixture.make(kind: .localWrite, inheritedSources: true,
                                                        authorizer: authorizer)
        try await withToolExecutorFixture(fixture) { f in
            let resolutions = try await f.executor.execute(attemptID: f.attemptID, executionID: f.executionID)
            #expect(resolutions.first?.status == .denied)
            #expect(resolutions.first?.businessReceipt == nil)
            #expect(try f.count() == 0)
            #expect(await authorizer.checks == check)
            #expect(await authorizer.observedSources.allSatisfy { $0.contains(f.source) })
        }
    }

    @Test func localWriteCommitsReceiptOnceAndPersistsInheritedSources() async throws {
        let fixture = try await ToolExecutorFixture.make(kind: .localWrite, inheritedSources: true)
        try await withToolExecutorFixture(fixture) { fixture in
            let resolutions = try await fixture.executor.execute(attemptID: fixture.attemptID, executionID: fixture.executionID)
            let resolution = try #require(resolutions.first)
            #expect(resolution.status == .succeeded)
            #expect(resolution.businessReceipt != nil)
            #expect(try fixture.count() == 1)
            #expect(try await fixture.business.unpublished(after: nil, limit: 10).isEmpty)

            let state = await fixture.runtime.snapshot()
            let intent = try #require(state.invocations[fixture.invocationID]?.intent)
            let proposal = try SessionCodec.decode(AgentToolProposal.self, from: await fixture.library.read(intent.intent.proposal))
            #expect(proposal.sources.contains(fixture.source))
            #expect(proposal.inheritedSources == [fixture.source])
            #expect(proposal.plan.sources.isEmpty)

            await #expect(throws: MiraError.self) {
                _ = try await fixture.executor.execute(attemptID: fixture.attemptID, executionID: fixture.executionID)
            }
            #expect(try fixture.count() == 1)
        }
    }

    @Test func invalidArgumentsAndUnknownToolsNeverInvokeBodies() async throws {
        let invalid = try await ToolExecutorFixture.make(kind: .localWrite, callArguments: "[]")
        try await withToolExecutorFixture(invalid) { fixture in
            let resolutions = try await fixture.executor.execute(attemptID: fixture.attemptID, executionID: fixture.executionID)
            #expect(resolutions.first?.status == .invalidArguments)
            #expect(await fixture.probe.prepareCount == 0)
            #expect(try fixture.count() == 0)
        }

        let unknown = try await ToolExecutorFixture.make(kind: .unknown)
        try await withToolExecutorFixture(unknown) { fixture in
            let resolutions = try await fixture.executor.execute(attemptID: fixture.attemptID, executionID: fixture.executionID)
            #expect(resolutions.first?.status == .notFound)
            #expect(await fixture.probe.prepareCount == 0)
            #expect(try fixture.count() == 0)
        }
    }

    @Test func unavailableApprovalDeniesPreparedIntentWithoutDispatch() async throws {
        let fixture = try await ToolExecutorFixture.make(kind: .localWrite, policy: .requireApproval)
        try await withToolExecutorFixture(fixture) { fixture in
            let resolutions = try await fixture.executor.execute(attemptID: fixture.attemptID, executionID: fixture.executionID)
            #expect(resolutions.first?.status == .denied)
            let state = await fixture.runtime.snapshot()
            #expect(state.invocations[fixture.invocationID]?.intent != nil)
            #expect(state.invocations[fixture.invocationID]?.dispatchedAt == nil)
            #expect(try fixture.count() == 0)
        }
    }

    @Test func approvalFollowedByBusinessEpochRevocationDeniesBeforeHandler() async throws {
        let fixture = try await ToolExecutorFixture.make(kind: .localWrite, policy: .requireApproval)
        try await withToolExecutorFixture(fixture) { fixture in
            let approvalStream = await fixture.approvals.snapshots()
            let execution = Task {
                try await fixture.executor.execute(attemptID: fixture.attemptID, executionID: fixture.executionID)
            }
            var request: RuntimeApprovalRequest?
            for await requests in approvalStream {
                if let first = requests.first { request = first; break }
            }
            let requestValue = try #require(request)
            try await fixture.performResultMaintenance()
            try await fixture.approvals.resolve(id: requestValue.id, proposalHash: requestValue.proposalHash,
                authorizationEpoch: requestValue.authorizationEpoch, decision: .approved)
            let resolutions = try await execution.value
            #expect(resolutions.first?.status == .denied)
            #expect(try fixture.count() == 0)
            #expect(await fixture.runtime.snapshot().invocations[fixture.invocationID]?.dispatchedAt == nil)
        }
    }

    @Test func externalFailurePublishesUnknownEffectWithoutSuccess() async throws {
        let fixture = try await ToolExecutorFixture.make(kind: .externalWrite)
        try await withToolExecutorFixture(fixture) { fixture in
            let resolutions = try await fixture.executor.execute(attemptID: fixture.attemptID, executionID: fixture.executionID)
            let resolution = try #require(resolutions.first)
            #expect(resolution.status == .failed)
            #expect(resolution.effectIsKnown == false)
            #expect(resolution.businessReceipt == nil)
            #expect(await fixture.probe.executeCount == 1)
        }
    }

    @Test func parallelReadsRespectLimitBarrierAndModelOrder() async throws {
        let fixture = try await ParallelToolFixture.make()
        try await withParallelFixture(fixture) { fixture in
            let task = Task { try await fixture.executor.execute(attemptID: fixture.attemptID, executionID: fixture.executionID) }
            await fixture.gate.waitUntilEntered(["tests.a", "tests.b"])
            #expect(await fixture.gate.maximumActive == 2)
            #expect(await fixture.gate.entered("tests.ordered") == false)
            await fixture.gate.release("tests.b")
            await fixture.gate.release("tests.a")
            await fixture.gate.waitUntilEntered(["tests.ordered"])
            await fixture.gate.release("tests.ordered")
            let resolutions = try await task.value
            #expect(resolutions.map(\.invocationID) == fixture.invocationIDs)
            #expect(resolutions.allSatisfy { $0.status == .succeeded })
            #expect(await fixture.gate.maximumActive == 2)
        }
    }

    @Test func epochRevocationDuringReadSuppressesItsResult() async throws {
        let fixture = try await ParallelToolFixture.make()
        try await withParallelFixture(fixture) { fixture in
            let task = Task { try await fixture.executor.execute(attemptID: fixture.attemptID, executionID: fixture.executionID) }
            await fixture.gate.waitUntilEntered(["tests.a", "tests.b"])
            try await fixture.performResultMaintenance()
            await fixture.gate.release("tests.a")
            await fixture.gate.release("tests.b")
            // An out-of-band authority change cannot grant a fresh epoch to this old execution lease.
            await fixture.gate.release("tests.ordered")
            let resolutions = try await task.value
            #expect(resolutions.prefix(2).allSatisfy { $0.status == .interrupted && $0.result == nil && $0.effectIsKnown })
            #expect(resolutions.last?.status == .denied)
        }
    }

    @Test func maintenanceCancelsAndDrainsAdmittedToolsBeforeAnyLaterInvocation() async throws {
        let fixture = try await ParallelToolFixture.make()
        try await withParallelFixture(fixture) { fixture in
            let task = Task { try await fixture.executor.execute(attemptID: fixture.attemptID, executionID: fixture.executionID) }
            do {
                await fixture.gate.waitUntilEntered(["tests.a", "tests.b"])
                let access = fixture.libraryAccessFixture.access
                let initial = await access.snapshot()
                #expect(initial.activeResources == 2)
                let operation = try await access.begin(.init(id: UUID(), namespace: "test.purge", revision: 1,
                    scope: .library, requestedAt: Date()), expected: initial.authorization)
                let deadline = ContinuousClock.now + .seconds(5)
                while await fixture.gate.cancelledCount != 2 {
                    guard ContinuousClock.now < deadline else { throw MiraError(.timeout, "Tool cancellation did not arrive.") }
                    try await Task.sleep(for: .milliseconds(1))
                }
                #expect((await access.snapshot()).activeResources == 2)
                #expect(await fixture.gate.active == 2)
                #expect(await fixture.gate.entered("tests.ordered") == false)
                do {
                    _ = try await access.complete(operation, at: Date())
                    Issue.record("Maintenance completed with non-cooperative tool bodies still owned.")
                } catch let error as MiraError { #expect(error.code == .busy) }
                await fixture.gate.release("tests.a"); await fixture.gate.release("tests.b")
                do { _ = try await task.value; Issue.record("Revoked execution completed its later tools.") }
                catch let error as MiraError { #expect(error.code == .unauthorized) }
                #expect((await access.snapshot()).activeResources == 0)
                #expect(await fixture.gate.active == 0)
                #expect(await fixture.gate.entered("tests.ordered") == false)
                let state = await fixture.runtime.snapshot()
                #expect(fixture.invocationIDs.allSatisfy { state.invocations[$0]?.resolution?.result == nil })
                #expect(state.invocations[fixture.invocationIDs.last!]?.resolution?.status == .cancelledBeforeDispatch)
            } catch {
                task.cancel()
                for name in ["tests.a", "tests.b", "tests.ordered"] { await fixture.gate.release(name) }
                _ = await task.result
                throw error
            }
        }
    }

    @Test func timeoutDrainsExternalBodyAndPreservesUnknownEffect() async throws {
        let fixture = try await CancellationToolFixture.make(timeoutAfterEntry: true)
        try await withCancellationFixture(fixture) { fixture in
            let resolutions = try await fixture.executor.execute(attemptID: fixture.attemptID, executionID: fixture.executionID)
            #expect(await fixture.gate.didDrain)
            #expect(resolutions.first?.status == .timedOut)
            #expect(resolutions.first?.effectIsKnown == false)
            #expect(resolutions.first?.result == nil)
        }
    }

    @Test func cancellationDrainsExternalBodyAndSettlesUnknownEffect() async throws {
        let fixture = try await CancellationToolFixture.make()
        try await withCancellationFixture(fixture) { fixture in
            let task = Task { try await fixture.executor.execute(attemptID: fixture.attemptID, executionID: fixture.executionID) }
            await fixture.gate.waitUntilEntered()
            task.cancel()
            do {
                _ = try await task.value
                Issue.record("Cancelled tool execution unexpectedly returned success")
            } catch is CancellationError {
                // Expected after the executor writes interrupted settlement.
            } catch {
                // The executor may wrap the cancellation after durable interruption settlement.
            }
            #expect(await fixture.gate.didDrain)
            let state = await fixture.runtime.snapshot()
            #expect(state.invocations[fixture.invocationID]?.resolution?.status == .interrupted)
            #expect(state.invocations[fixture.invocationID]?.resolution?.effectIsKnown == false)
        }
    }

    @Test func indeterminateLocalCommitRecoversReceiptAndAcknowledgesOnce() async throws {
        let fixture = try await ToolExecutorFixture.make(kind: .localWrite, afterCommitHook: { throw HookFailure.failed })
        try await withToolExecutorFixture(fixture) { fixture in
            let resolutions = try await fixture.executor.execute(attemptID: fixture.attemptID, executionID: fixture.executionID)
            #expect(resolutions.first?.status == .succeeded)
            #expect(resolutions.first?.businessReceipt != nil)
            #expect(try fixture.count() == 1)
            #expect(try await fixture.business.unpublished(after: nil, limit: 10).isEmpty)
        }
    }
}

private enum HookFailure: Error { case failed }

extension AgentToolExecutorIntegrationTests {
    @Test func hostDenialCannotBeOverriddenByModulePolicy() async throws {
        let module = ModulePolicyProbe(decision: .allow)
        let fixture = try await ToolExecutorFixture.make(kind: .localWrite, policy: .deny, modulePolicy: .constrained(module))
        try await withToolExecutorFixture(fixture) { f in
            let result = try await f.executor.execute(attemptID: f.attemptID, executionID: f.executionID)
            #expect(result.first?.status == .denied)
            #expect(await module.evaluations == 0)
            #expect(await f.runtime.snapshot().invocations[f.invocationID]?.dispatchedAt == nil)
            #expect(try f.count() == 0)
        }
    }

    @Test(arguments: [FixturePolicyDecision.allow, .requireApproval])
    fileprivate func moduleDenialPreventsApprovalAndDispatch(host: FixturePolicyDecision) async throws {
        let module = ModulePolicyProbe(decision: .deny)
        let fixture = try await ToolExecutorFixture.make(kind: .localWrite, policy: host, modulePolicy: .constrained(module))
        try await withToolExecutorFixture(fixture) { f in
            let result = try await f.executor.execute(attemptID: f.attemptID, executionID: f.executionID)
            #expect(result.first?.status == .denied)
            let state = await f.runtime.snapshot()
            #expect(state.invocations[f.invocationID]?.approval == nil)
            #expect(state.invocations[f.invocationID]?.dispatchedAt == nil)
            #expect(await module.evaluations == 1)
            #expect(try f.count() == 0)
        }
    }

    @Test(arguments: [false, true])
    func moduleApprovalIsCombinedAndRevalidated(revokeBeforeApproval: Bool) async throws {
        let module = ModulePolicyProbe(decision: .requireApproval)
        let fixture = try await ToolExecutorFixture.make(kind: .localWrite, policy: .requireApproval, modulePolicy: .constrained(module))
        try await withToolExecutorFixture(fixture) { f in
            let stream = await f.approvals.snapshots()
            let run = Task { try await f.executor.execute(attemptID: f.attemptID, executionID: f.executionID) }
            do {
                var request: RuntimeApprovalRequest?
                for await pending in stream { if let value = pending.first { request = value; break } }
                let approval = try #require(request)
                #expect(approval.prompt == "Approve synthetic tool\n\nApprove module restriction")
                let state = await f.runtime.snapshot()
                #expect(state.invocations[f.invocationID]?.intent?.intent.proposal.digest == approval.proposalHash)
                if revokeBeforeApproval { await module.revoke() }
                try await f.approvals.resolve(id: approval.id, proposalHash: approval.proposalHash,
                    authorizationEpoch: approval.authorizationEpoch, decision: .approved)
                let result = try await run.value
                #expect(result.first?.status == (revokeBeforeApproval ? .denied : .succeeded))
                #expect(try f.count() == (revokeBeforeApproval ? 0 : 1))
                #expect(await module.validations == (revokeBeforeApproval ? 1 : 2))
            } catch { await f.approvals.cancel(executionID: f.executionID); run.cancel(); _ = await run.result; throw error }
        }
    }

    @Test func moduleApprovalRequiresAnAvailableObserver() async throws {
        let fixture = try await ToolExecutorFixture.make(kind: .localWrite,
            modulePolicy: .constrained(ModulePolicyProbe(decision: .requireApproval)))
        try await withToolExecutorFixture(fixture) { f in
            let result = try await f.executor.execute(attemptID: f.attemptID, executionID: f.executionID)
            #expect(result.first?.status == .denied)
            #expect(await f.runtime.snapshot().invocations[f.invocationID]?.dispatchedAt == nil)
            #expect(try f.count() == 0)
        }
    }

    @Test func moduleRevocationDuringReadSuppressesResultsAndLaterTools() async throws {
        let module = ModulePolicyProbe(decision: .allow)
        let fixture = try await ParallelToolFixture.make(modulePolicy: .constrained(module))
        try await withParallelFixture(fixture) { f in
            let run = Task { try await f.executor.execute(attemptID: f.attemptID, executionID: f.executionID) }
            do {
                await f.gate.waitUntilEntered(["tests.a", "tests.b"])
                await module.revoke()
                await f.gate.release("tests.a"); await f.gate.release("tests.b")
                let result = try await run.value
                #expect(result.prefix(2).allSatisfy { $0.status == .interrupted && $0.result == nil && $0.effectIsKnown })
                #expect(result.last?.status == .denied)
                #expect(await f.gate.entered("tests.ordered") == false)
            } catch {
                run.cancel()
                for name in ["tests.a", "tests.b", "tests.ordered"] { await f.gate.release(name) }
                _ = await run.result; throw error
            }
        }
    }
}

private actor ModulePolicyProbe: AgentToolPolicy {
    private let decision: FixturePolicyDecision
    private var revoked = false
    private(set) var evaluations = 0
    private(set) var validations = 0
    init(decision: FixturePolicyDecision) { self.decision = decision }
    func revoke() { revoked = true }
    func evaluate(_ proposal: AgentToolProposal, context: AgentToolContext) async throws -> AgentToolPolicyDecision {
        evaluations += 1
        if revoked { return .deny }
        switch decision {
        case .allow: return .allow
        case .deny: return .deny
        case .requireApproval: return .requireApproval(prompt: "Approve module restriction", expiresAt: Date().addingTimeInterval(30))
        }
    }
    func validate(_ proposal: AgentToolProposal, context: AgentToolContext) async throws {
        validations += 1
        if revoked { throw MiraError(.unauthorized, "Synthetic module restriction was revoked.") }
    }
}

private actor ToolProbe {
    private(set) var prepareCount = 0
    private(set) var executeCount = 0
    func prepared() { prepareCount += 1 }
    func executed() { executeCount += 1 }
}

private enum ToolFixtureKind: Sendable { case localWrite, externalWrite, unknown }

private enum FixturePolicyDecision: Sendable { case allow, deny, requireApproval }

private struct FixturePolicy: AgentToolPolicy {
    let decision: FixturePolicyDecision
    func evaluate(_ proposal: AgentToolProposal, context: AgentToolContext) async throws -> AgentToolPolicyDecision {
        switch decision {
        case .allow: return .allow
        case .deny: return .deny
        case .requireApproval: return .requireApproval(prompt: "Approve synthetic tool", expiresAt: Date().addingTimeInterval(30))
        }
    }
    func validate(_ proposal: AgentToolProposal, context: AgentToolContext) async throws {}
}

private struct FixtureLocalWrite: AgentLocalWriteTool {
    let policy: AgentToolPolicyRequirement
    let descriptor: AgentToolDescriptor
    let probe: ToolProbe
    let businessNamespace = "tests"
    func prepare(_ arguments: JSONValue, context: AgentToolContext) async throws -> AgentToolPlan {
        await probe.prepared()
        return .init(input: arguments, sources: [], targets: [])
    }
}

private struct FixtureExternalWrite: AgentExternalWriteTool {
    let policy: AgentToolPolicyRequirement = .hostOnly
    let descriptor: AgentToolDescriptor
    let probe: ToolProbe
    func prepare(_ arguments: JSONValue, context: AgentToolContext) async throws -> AgentToolPlan {
        await probe.prepared()
        return .init(input: arguments, sources: [], targets: [])
    }
    func execute(_ plan: AgentToolPlan, context: AgentToolContext) async throws -> JSONValue {
        await probe.executed()
        throw MiraError(.storage, "Synthetic external write failed.")
    }
}

private struct FixtureHandler: SQLiteBusinessCommandHandler {
    let namespace = "tests"
    func businessKey(for effect: AgentResolvedEffect) throws -> String { "executor-counter" }
    func apply(effect: AgentResolvedEffect, in db: Database) throws -> JSONValue {
        try db.execute(sql: "CREATE TABLE IF NOT EXISTS synthetic_counter (id INTEGER PRIMARY KEY CHECK(id = 1), count INTEGER NOT NULL)")
        try db.execute(sql: "INSERT OR IGNORE INTO synthetic_counter(id, count) VALUES (1, 0)")
        try db.execute(sql: "UPDATE synthetic_counter SET count = count + 1 WHERE id = 1")
        return .object(["ok": .bool(true)])
    }
}

private struct FixtureValidator: SQLiteBusinessAuthorizationValidator {
    func validate(effect: AgentResolvedEffect, isReplay: Bool, in db: Database) throws {}
}

private final class ToolExecutorFixture: Sendable {
    let directory: URL
    let databasePath: String
    let library: FileSessionLibrary
    let database: DatabaseQueue
    let business: SQLiteBusinessEffects
    let authority: SQLiteLibraryAuthority
    let runtime: SessionRuntime
    let executor: AgentToolExecutor
    let approvals: RuntimeApprovalService
    let probe: ToolProbe
    let source: AgentSourceReference
    let sessionID: ConversationID
    let executionID: ExecutionID
    let attemptID: UUID
    let invocationID: UUID
    let invocationName: String
    let libraryAccessFixture: LibraryAccessFixture

    static func make(kind: ToolFixtureKind, policy: FixturePolicyDecision = .allow,
                     modulePolicy: AgentToolPolicyRequirement = .hostOnly,
                     callArguments: String = "{}", inheritedSources: Bool = false,
                     authorizer: any AgentSourceAuthorizer = ToolFixtureSourceAuthorizer(),
                     afterCommitHook: (@Sendable () throws -> Void)? = nil) async throws -> ToolExecutorFixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mira-tool-executor-\(UUID().uuidString)")
        let library = try FileSessionLibrary(directory: directory)
        let databasePath = directory.appendingPathComponent("business.sqlite").path
        let resolver = JournalAgentEffectResolver(journal: library, payloads: library)
        let database = try toolBusinessDatabase(path: databasePath)
        let authority = try SQLiteLibraryAuthority(database: database)
        var business: SQLiteBusinessEffects?
        var runtime: SessionRuntime?
        var cleanupAccessFixture: LibraryAccessFixture?
        do {
            let madeBusiness = try SQLiteBusinessEffects(database: database, libraryID: authority.libraryID, resolver: resolver,
                handlers: [FixtureHandler()], validator: FixtureValidator(), afterCommitHook: afterCommitHook)
            business = madeBusiness
            let openedRuntime = try await SessionRuntime.open(id: ConversationID(), journal: library, payloads: library)
            runtime = openedRuntime
            let probe = ToolProbe()
            let source = AgentSourceReference.domain(namespace: "fixture", id: UUID(), revision: 1)
            let descriptor = Self.descriptor(name: kind == .unknown ? "tests.read" : "tests.\(kind == .externalWrite ? "external" : "write")")
            let tool: AgentTool
            let name: String
            let effect: SessionEffectKind
            switch kind {
            case .localWrite:
                tool = .localWrite(FixtureLocalWrite(policy: modulePolicy, descriptor: descriptor, probe: probe)); name = descriptor.definition.name; effect = .localWrite
            case .externalWrite:
                tool = .externalWrite(FixtureExternalWrite(descriptor: descriptor, probe: probe)); name = descriptor.definition.name; effect = .externalWrite
            case .unknown:
                tool = .read(FixtureExternalRead(descriptor: descriptor, probe: probe)); name = "missing.tool"; effect = .read
            }
            let catalog = try AgentToolCatalog(kind == .unknown ? [] : [tool])
            let approvals = RuntimeApprovalService()
            let accessFixture = try await LibraryAccessFixture.make(authority: authority)
            cleanupAccessFixture = accessFixture
            let libraryLease = try await accessFixture.acquire()
            let executor = try AgentToolExecutor(runtime: openedRuntime, payloads: library, libraryLease: libraryLease, catalog: catalog,
                policy: FixturePolicy(decision: policy), authority: madeBusiness, business: madeBusiness,
                authorizer: authorizer, approvals: approvals, maximumParallelTools: 2)
            let fixture = ToolExecutorFixture(directory: directory, databasePath: databasePath, library: library, database: database,
                business: madeBusiness, authority: authority, runtime: openedRuntime, executor: executor, approvals: approvals, probe: probe, source: source,
                sessionID: openedRuntime.id, executionID: ExecutionID(), attemptID: UUID(), invocationID: UUID(),
                invocationName: name, libraryAccessFixture: accessFixture)
            try await fixture.seed(catalog: catalog, effect: effect, callArguments: callArguments, inheritedSources: inheritedSources)
            return fixture
        } catch {
            await cleanupAccessFixture?.close()
            await runtime?.close()
            if let business { try? await business.close() }
            await authority.close(); try? await library.close(); try? database.close()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private init(directory: URL, databasePath: String, library: FileSessionLibrary, database: DatabaseQueue, business: SQLiteBusinessEffects,
                 authority: SQLiteLibraryAuthority,
                 runtime: SessionRuntime, executor: AgentToolExecutor, approvals: RuntimeApprovalService, probe: ToolProbe,
                 source: AgentSourceReference, sessionID: ConversationID, executionID: ExecutionID, attemptID: UUID,
                 invocationID: UUID, invocationName: String, libraryAccessFixture: LibraryAccessFixture) {
        self.directory = directory; self.databasePath = databasePath; self.library = library; self.database = database; self.business = business
        self.authority = authority; self.runtime = runtime; self.executor = executor; self.approvals = approvals; self.probe = probe; self.source = source
        self.sessionID = sessionID; self.executionID = executionID; self.attemptID = attemptID; self.invocationID = invocationID
        self.invocationName = invocationName; self.libraryAccessFixture = libraryAccessFixture
    }

    private func seed(catalog: AgentToolCatalog, effect: SessionEffectKind, callArguments: String,
                      inheritedSources: Bool) async throws {
        let route = AgentModelRoute(id: RouteID(), revision: 1, connectionID: ConnectionID(), connectionRevision: 1,
            modelDescriptorID: ModelDescriptorID(), modelRevision: 1, modelAuthorizationRevision: 1, adapter: .init(id: "synthetic.model", revision: 1),
            invocationID: "test-invocation", invocationRevision: 1, endpointID: "test-endpoint", metadataEvidence: [], modelID: "fixture", credential: nil, contextWindow: 4_096, maximumOutputTokens: 512,
            capabilities: .init(streamsText: true, callsTools: true, producesThinking: true), configuration: .object([:]))
        let userID = MessageID()
        let admission = await runtime.commit(id: UUID()) { context in
            let title = try await context.stageBytes(Data("Synthetic".utf8), kind: .title, retentionGroup: UUID())
            let user = try await context.stageBytes(Data("Question".utf8), kind: .userText, retentionGroup: UUID())
            let routeRef = try await context.stage(AgentExecutionPlan(runtimeID: UUID(), catalogGeneration: 0, driverID: "mira.default", driverRevision: 1, instructions: "Answer.", limits: .init(), priority: .foreground, route: route), kind: .executionPlan, retentionGroup: UUID())
            return [.opened(.init(workspaceID: nil, title: title)), .admitted(.init(executionID: executionID,
                userMessageID: userID, userBody: user, plan: routeRef, hasModelRoute: true, authorizationEpoch: 0, timeZoneIdentifier: "UTC"))]
        }
        try requireCommitted(admission)
        let request = AgentContextRequest(sessionID: sessionID, executionID: executionID, workspaceID: nil,
            userText: "Question", authorizationEpoch: 0, destination: .model(route))
        let sources = inheritedSources ? [source] : []
        let input = AgentModelInput(stepID: attemptID, executionID: executionID, instructions: "Answer.",
            messages: [.init(role: .user, blocks: [.init(id: "text", content: .text("Question"))])], tools: catalog.definitions)
        let prepared = AgentPreparedModelRequest(adapter: route.adapter, input: input, wirePayload: .object([:]), estimatedInputTokens: 1)
        let build = AgentContextBuild(request: request, prepared: prepared, inheritedSources: sources, evidence: [], omissions: [])
        let started = await runtime.commit(id: UUID()) { context in
            let requestRef = try await context.stage(build, kind: .request, retentionGroup: UUID())
            return [.phaseChanged(executionID: executionID, phase: .preparing),
                    .attemptStarted(.init(id: attemptID, executionID: executionID, stepID: attemptID, stepIndex: 1,
                        attemptIndex: 1, request: requestRef))]
        }
        try requireCommitted(started)
        let finished = await runtime.commit(id: UUID()) { context in
            let output = try await context.stageBytes(Data("model output".utf8), kind: .modelOutput, retentionGroup: UUID())
            let call = CanonicalToolCall(id: "call-1", name: invocationName, arguments: callArguments)
            let callRef = try await context.stage(call, kind: .toolCall, retentionGroup: UUID())
            return [.attemptResolved(.init(attemptID: attemptID, status: .completed, output: output)),
                    .toolProposed(.init(id: invocationID, attemptID: attemptID, modelOrder: 0,
                        toolName: invocationName, effect: effect, call: callRef)),
                    .phaseChanged(executionID: executionID, phase: .waitingForTools)]
        }
        try requireCommitted(finished)
    }

    private static func descriptor(name: String) -> AgentToolDescriptor {
        let input: JSONValue = .object(["type": .string("object"), "properties": .object([:]), "additionalProperties": .bool(false)])
        let output: JSONValue = .object(["type": .string("object"),
            "properties": .object(["ok": .object(["type": .string("boolean")])]),
            "required": .array([.string("ok")]), "additionalProperties": .bool(false)])
        return .init(definition: .init(name: name, description: "Synthetic tool", inputSchema: input), revision: 1,
            outputSchema: output, executionMode: .exclusive, timeoutMilliseconds: 1_000, maximumResultBytes: 1_024)
    }

    func count() throws -> Int {
        return try database.read { db in
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'synthetic_counter')") == true else { return 0 }
            return try Int.fetchOne(db, sql: "SELECT count FROM synthetic_counter WHERE id = 1") ?? 0
        }
    }

    func performResultMaintenance(receiptIDs: Set<UUID> = []) async throws {
        let previous = try await authority.authorization()
        let request = AgentLibraryMaintenanceRequest(id: UUID(), namespace: "tests.invalidate", revision: 1,
            scope: .library, requestedAt: Date())
        let operation = try await authority.begin(request, expected: previous)
        try await business.purgeResults(receiptIDs: receiptIDs, maintenance: operation)
        _ = try await authority.complete(operation, at: Date())
    }

    func shutdown() async {
        await approvals.shutdown()
        await runtime.close()
        await libraryAccessFixture.close()
        try? await library.close()
        try? await business.close(); await authority.close(); try? database.close()
        try? FileManager.default.removeItem(at: directory)
    }
}

private struct FixtureExternalRead: AgentReadTool {
    let policy: AgentToolPolicyRequirement = .hostOnly
    let descriptor: AgentToolDescriptor
    let probe: ToolProbe
    func prepare(_ arguments: JSONValue, context: AgentToolContext) async throws -> AgentToolPlan {
        await probe.prepared(); return .init(input: arguments, sources: [], targets: [])
    }
    func execute(_ plan: AgentToolPlan, context: AgentToolContext) async throws -> JSONValue {
        await probe.executed(); return .object(["ok": .bool(true)])
    }
}

private actor ReadGate {
    private var enteredIDs: Set<String> = []
    private var releases: [String: CheckedContinuation<Void, Never>] = [:]
    private var releasedIDs: Set<String> = []
    private(set) var active = 0
    private(set) var maximumActive = 0
    private var cancelledIDs: Set<String> = []
    var cancelledCount: Int { cancelledIDs.count }

    func enter(_ id: String) {
        enteredIDs.insert(id); active += 1; maximumActive = max(maximumActive, active)
    }

    func hold(_ id: String) async {
        if releasedIDs.remove(id) != nil { active -= 1; return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { releases[id] = $0 }
        } onCancel: { Task { await self.observeCancellation(id) } }
        active -= 1
    }

    private func observeCancellation(_ id: String) { cancelledIDs.insert(id) }

    func release(_ id: String) {
        if let continuation = releases.removeValue(forKey: id) { continuation.resume() }
        else { releasedIDs.insert(id) }
    }

    func entered(_ id: String) -> Bool { enteredIDs.contains(id) }

    func waitUntilEntered(_ ids: [String]) async {
        while !ids.allSatisfy({ enteredIDs.contains($0) }) { await Task.yield() }
    }
}

private struct GateReadTool: AgentReadTool {
    let policy: AgentToolPolicyRequirement
    let descriptor: AgentToolDescriptor
    let gate: ReadGate
    let id: String
    func prepare(_ arguments: JSONValue, context: AgentToolContext) async throws -> AgentToolPlan {
        .init(input: arguments, sources: [], targets: [])
    }
    func execute(_ plan: AgentToolPlan, context: AgentToolContext) async throws -> JSONValue {
        await gate.enter(id)
        await gate.hold(id)
        return .object(["ok": .bool(true)])
    }
}

private final class ParallelToolFixture: Sendable {
    let directory: URL
    let library: FileSessionLibrary
    let database: DatabaseQueue
    let business: SQLiteBusinessEffects
    let authority: SQLiteLibraryAuthority
    let runtime: SessionRuntime
    let executor: AgentToolExecutor
    let gate: ReadGate
    let libraryAccessFixture: LibraryAccessFixture
    let sessionID: ConversationID
    let executionID: ExecutionID
    let attemptID: UUID
    let invocationIDs: [UUID]

    static func make(modulePolicy: AgentToolPolicyRequirement = .hostOnly) async throws -> ParallelToolFixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mira-tool-parallel-\(UUID().uuidString)")
        let library = try FileSessionLibrary(directory: directory)
        let databasePath = directory.appendingPathComponent("business.sqlite").path
        let resolver = JournalAgentEffectResolver(journal: library, payloads: library)
        let database = try toolBusinessDatabase(path: databasePath)
        let authority = try SQLiteLibraryAuthority(database: database)
        var business: SQLiteBusinessEffects?
        var runtime: SessionRuntime?
        var cleanupAccessFixture: LibraryAccessFixture?
        do {
            let madeBusiness = try SQLiteBusinessEffects(database: database, libraryID: authority.libraryID, resolver: resolver,
                handlers: [FixtureHandler()], validator: FixtureValidator())
            business = madeBusiness
            let sessionID = ConversationID()
            let openedRuntime = try await SessionRuntime.open(id: sessionID, journal: library, payloads: library)
            runtime = openedRuntime
            let gate = ReadGate()
            let names = ["tests.a", "tests.b", "tests.ordered"]
            let modes: [ToolExecutionMode] = [.parallelSafe, .parallelSafe, .exclusive]
            let tools = names.enumerated().map { offset, name in
                AgentTool.read(GateReadTool(policy: modulePolicy, descriptor: executorDescriptor(name: name, mode: modes[offset]), gate: gate, id: name))
            }
            let catalog = try AgentToolCatalog(tools)
            let approvals = RuntimeApprovalService()
            let accessFixture = try await LibraryAccessFixture.make(authority: authority)
            cleanupAccessFixture = accessFixture
            let libraryLease = try await accessFixture.acquire()
            let executor = try AgentToolExecutor(runtime: openedRuntime, payloads: library, libraryLease: libraryLease, catalog: catalog,
                policy: FixturePolicy(decision: .allow), authority: madeBusiness, business: madeBusiness,
                authorizer: ToolFixtureSourceAuthorizer(), approvals: approvals, maximumParallelTools: 2)
            let fixture = ParallelToolFixture(directory: directory, library: library, database: database, business: madeBusiness, authority: authority, runtime: openedRuntime,
                executor: executor, gate: gate, libraryAccessFixture: accessFixture, sessionID: sessionID, executionID: ExecutionID(), attemptID: UUID(),
                invocationIDs: [UUID(), UUID(), UUID()])
            try await fixture.seed(catalog: catalog, names: names)
            return fixture
        } catch {
            await cleanupAccessFixture?.close()
            await runtime?.close()
            if let business { try? await business.close() }
            await authority.close(); try? await library.close(); try? database.close()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private init(directory: URL, library: FileSessionLibrary, database: DatabaseQueue, business: SQLiteBusinessEffects, authority: SQLiteLibraryAuthority, runtime: SessionRuntime,
                 executor: AgentToolExecutor, gate: ReadGate, libraryAccessFixture: LibraryAccessFixture, sessionID: ConversationID, executionID: ExecutionID,
                 attemptID: UUID, invocationIDs: [UUID]) {
        self.directory = directory; self.library = library; self.database = database; self.business = business; self.authority = authority; self.runtime = runtime
        self.executor = executor; self.gate = gate; self.libraryAccessFixture = libraryAccessFixture; self.sessionID = sessionID; self.executionID = executionID
        self.attemptID = attemptID; self.invocationIDs = invocationIDs
    }

    func performResultMaintenance(receiptIDs: Set<UUID> = []) async throws {
        let previous = try await authority.authorization()
        let request = AgentLibraryMaintenanceRequest(id: UUID(), namespace: "tests.invalidate", revision: 1,
            scope: .library, requestedAt: Date())
        let operation = try await authority.begin(request, expected: previous)
        try await business.purgeResults(receiptIDs: receiptIDs, maintenance: operation)
        _ = try await authority.complete(operation, at: Date())
    }

    private func seed(catalog: AgentToolCatalog, names: [String]) async throws {
        let route = syntheticRoute()
        let admission = await runtime.commit(id: UUID()) { context in
            let title = try await context.stageBytes(Data("Synthetic".utf8), kind: .title, retentionGroup: UUID())
            let user = try await context.stageBytes(Data("Question".utf8), kind: .userText, retentionGroup: UUID())
            let routeRef = try await context.stage(AgentExecutionPlan(runtimeID: UUID(), catalogGeneration: 0, driverID: "mira.default", driverRevision: 1, instructions: "Answer.", limits: .init(), priority: .foreground, route: route), kind: .executionPlan, retentionGroup: UUID())
            return [.opened(.init(workspaceID: nil, title: title)), .admitted(.init(executionID: executionID,
                userMessageID: MessageID(), userBody: user, plan: routeRef, hasModelRoute: true, authorizationEpoch: 0, timeZoneIdentifier: "UTC"))]
        }
        try requireCommitted(admission)
        let input = AgentModelInput(stepID: attemptID, executionID: executionID, instructions: "Answer.",
            messages: [.init(role: .user, blocks: [.init(id: "text", content: .text("Question"))])], tools: catalog.definitions)
        let request = AgentContextRequest(sessionID: sessionID, executionID: executionID, workspaceID: nil,
            userText: "Question", authorizationEpoch: 0, destination: .model(route))
        let build = AgentContextBuild(request: request,
            prepared: .init(adapter: route.adapter, input: input, wirePayload: .object([:]), estimatedInputTokens: 1),
            inheritedSources: [], evidence: [], omissions: [])
        let started = await runtime.commit(id: UUID()) { context in
            let requestRef = try await context.stage(build, kind: .request, retentionGroup: UUID())
            return [.phaseChanged(executionID: executionID, phase: .preparing),
                    .attemptStarted(.init(id: attemptID, executionID: executionID, stepID: attemptID, stepIndex: 1,
                        attemptIndex: 1, request: requestRef))]
        }
        try requireCommitted(started)
        let finished = await runtime.commit(id: UUID()) { context in
            let output = try await context.stageBytes(Data("output".utf8), kind: .modelOutput, retentionGroup: UUID())
            var facts: [SessionFact] = [.attemptResolved(.init(attemptID: attemptID, status: .completed, output: output))]
            for (order, name) in names.enumerated() {
                let call = try await context.stage(CanonicalToolCall(id: "call-\(order)", name: name, arguments: "{}"),
                    kind: .toolCall, retentionGroup: UUID())
                facts.append(.toolProposed(.init(id: invocationIDs[order], attemptID: attemptID, modelOrder: order,
                    toolName: name, effect: .read, call: call)))
            }
            facts.append(.phaseChanged(executionID: executionID, phase: .waitingForTools))
            return facts
        }
        try requireCommitted(finished)
    }

    func shutdown() async {
        await runtime.close(); await libraryAccessFixture.close(); try? await library.close(); try? await business.close(); await authority.close(); try? database.close()
        try? FileManager.default.removeItem(at: directory)
    }
}

private actor CancellationGate {
    private var enteredValue = false
    private var drainedValue = false
    private var continuation: CheckedContinuation<Void, Error>?
    var didDrain: Bool { drainedValue }
    func enter() { enteredValue = true }
    func waitUntilEntered() async { while !enteredValue { await Task.yield() } }
    func wait() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (value: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled || drainedValue { drainedValue = true; value.resume(throwing: CancellationError()) }
                else { continuation = value }
            }
        } onCancel: {
            Task { await self.cancel() }
        }
    }
    func cancel() {
        continuation?.resume(throwing: CancellationError()); continuation = nil; drainedValue = true
    }
}

private struct BlockingExternalTool: AgentExternalWriteTool {
    let policy: AgentToolPolicyRequirement = .hostOnly
    let descriptor: AgentToolDescriptor
    let gate: CancellationGate
    func prepare(_ arguments: JSONValue, context: AgentToolContext) async throws -> AgentToolPlan {
        .init(input: arguments, sources: [], targets: [])
    }
    func execute(_ plan: AgentToolPlan, context: AgentToolContext) async throws -> JSONValue {
        await gate.enter(); try await gate.wait(); return .object(["ok": .bool(true)])
    }
}

private final class CancellationToolFixture: Sendable {
    let directory: URL
    let library: FileSessionLibrary
    let database: DatabaseQueue
    let business: SQLiteBusinessEffects
    let authority: SQLiteLibraryAuthority
    let runtime: SessionRuntime
    let executor: AgentToolExecutor
    let gate: CancellationGate
    let libraryAccessFixture: LibraryAccessFixture
    let attemptID: UUID
    let executionID: ExecutionID
    let invocationID: UUID

    static func make(timeoutAfterEntry: Bool = false) async throws -> CancellationToolFixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mira-tool-cancel-\(UUID().uuidString)")
        let library = try FileSessionLibrary(directory: directory)
        let path = directory.appendingPathComponent("business.sqlite").path
        let resolver = JournalAgentEffectResolver(journal: library, payloads: library)
        let database = try toolBusinessDatabase(path: path)
        let authority = try SQLiteLibraryAuthority(database: database)
        var business: SQLiteBusinessEffects?
        var runtime: SessionRuntime?
        var cleanupAccessFixture: LibraryAccessFixture?
        do {
            let madeBusiness = try SQLiteBusinessEffects(database: database, libraryID: authority.libraryID, resolver: resolver, handlers: [FixtureHandler()], validator: FixtureValidator())
            business = madeBusiness
            let openedRuntime = try await SessionRuntime.open(id: ConversationID(), journal: library, payloads: library)
            runtime = openedRuntime
            let gate = CancellationGate()
            let descriptor = executorDescriptor(name: "tests.external", mode: .exclusive)
            let catalog = try AgentToolCatalog([.externalWrite(BlockingExternalTool(descriptor: descriptor, gate: gate))])
            let approvals = RuntimeApprovalService()
            let environment = timeoutAfterEntry
                ? RuntimeEnvironment(sleep: { _ in await gate.waitUntilEntered() }) : RuntimeEnvironment()
            let accessFixture = try await LibraryAccessFixture.make(authority: authority)
            cleanupAccessFixture = accessFixture
            let libraryLease = try await accessFixture.acquire()
            let executor = try AgentToolExecutor(runtime: openedRuntime, payloads: library, libraryLease: libraryLease, catalog: catalog,
                policy: FixturePolicy(decision: .allow), authority: madeBusiness, business: madeBusiness,
                authorizer: ToolFixtureSourceAuthorizer(), approvals: approvals, maximumParallelTools: 1, environment: environment)
            let fixture = CancellationToolFixture(directory: directory, library: library, database: database, business: madeBusiness, authority: authority, runtime: openedRuntime,
                executor: executor, gate: gate, libraryAccessFixture: accessFixture, attemptID: UUID(), executionID: ExecutionID(), invocationID: UUID())
            try await fixture.seed(catalog: catalog, name: "tests.external")
            return fixture
        } catch {
            await cleanupAccessFixture?.close()
            await runtime?.close()
            if let business { try? await business.close() }
            await authority.close(); try? await library.close(); try? database.close()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private init(directory: URL, library: FileSessionLibrary, database: DatabaseQueue, business: SQLiteBusinessEffects, authority: SQLiteLibraryAuthority, runtime: SessionRuntime,
                 executor: AgentToolExecutor, gate: CancellationGate, libraryAccessFixture: LibraryAccessFixture, attemptID: UUID, executionID: ExecutionID, invocationID: UUID) {
        self.directory = directory; self.library = library; self.database = database; self.business = business; self.authority = authority; self.runtime = runtime
        self.executor = executor; self.gate = gate; self.libraryAccessFixture = libraryAccessFixture; self.attemptID = attemptID; self.executionID = executionID; self.invocationID = invocationID
    }

    private func seed(catalog: AgentToolCatalog, name: String) async throws {
        let route = syntheticRoute()
        let admission = await runtime.commit(id: UUID()) { context in
            let title = try await context.stageBytes(Data("Synthetic".utf8), kind: .title, retentionGroup: UUID())
            let user = try await context.stageBytes(Data("Question".utf8), kind: .userText, retentionGroup: UUID())
            let routeRef = try await context.stage(AgentExecutionPlan(runtimeID: UUID(), catalogGeneration: 0, driverID: "mira.default", driverRevision: 1, instructions: "Answer.", limits: .init(), priority: .foreground, route: route), kind: .executionPlan, retentionGroup: UUID())
            return [.opened(.init(workspaceID: nil, title: title)), .admitted(.init(executionID: executionID,
                userMessageID: MessageID(), userBody: user, plan: routeRef, hasModelRoute: true, authorizationEpoch: 0, timeZoneIdentifier: "UTC"))]
        }
        try requireCommitted(admission)
        let input = AgentModelInput(stepID: attemptID, executionID: executionID, instructions: "Answer.",
            messages: [.init(role: .user, blocks: [.init(id: "text", content: .text("Question"))])], tools: catalog.definitions)
        let build = AgentContextBuild(request: .init(sessionID: runtime.id, executionID: executionID, workspaceID: nil,
                userText: "Question", authorizationEpoch: 0, destination: .model(route)),
            prepared: .init(adapter: route.adapter, input: input, wirePayload: .object([:]), estimatedInputTokens: 1),
            inheritedSources: [], evidence: [], omissions: [])
        let started = await runtime.commit(id: UUID()) { context in
            let requestRef = try await context.stage(build, kind: .request, retentionGroup: UUID())
            return [.phaseChanged(executionID: executionID, phase: .preparing),
                    .attemptStarted(.init(id: attemptID, executionID: executionID, stepID: attemptID, stepIndex: 1,
                        attemptIndex: 1, request: requestRef))]
        }
        try requireCommitted(started)
        let finished = await runtime.commit(id: UUID()) { context in
            let output = try await context.stageBytes(Data("output".utf8), kind: .modelOutput, retentionGroup: UUID())
            let call = try await context.stage(CanonicalToolCall(id: "call-1", name: name, arguments: "{}"), kind: .toolCall, retentionGroup: UUID())
            return [.attemptResolved(.init(attemptID: attemptID, status: .completed, output: output)),
                    .toolProposed(.init(id: invocationID, attemptID: attemptID, modelOrder: 0,
                        toolName: name, effect: .externalWrite, call: call)),
                    .phaseChanged(executionID: executionID, phase: .waitingForTools)]
        }
        try requireCommitted(finished)
    }

    func shutdown() async {
        await runtime.close(); await libraryAccessFixture.close(); try? await library.close(); try? await business.close(); await authority.close(); try? database.close()
        try? FileManager.default.removeItem(at: directory)
    }
}

private func syntheticRoute() -> AgentModelRoute {
    .init(id: RouteID(), revision: 1, connectionID: ConnectionID(), connectionRevision: 1,
        modelDescriptorID: ModelDescriptorID(), modelRevision: 1, modelAuthorizationRevision: 1, adapter: .init(id: "synthetic.model", revision: 1),
        invocationID: "test-invocation", invocationRevision: 1, endpointID: "test-endpoint", metadataEvidence: [], modelID: "fixture", credential: nil, contextWindow: 4_096, maximumOutputTokens: 512,
        capabilities: .init(streamsText: true, callsTools: true, producesThinking: true), configuration: .object([:]))
}

private func executorDescriptor(name: String, mode: ToolExecutionMode) -> AgentToolDescriptor {
    let input: JSONValue = .object(["type": .string("object"), "properties": .object([:]), "additionalProperties": .bool(false)])
    let output: JSONValue = .object(["type": .string("object"),
        "properties": .object(["ok": .object(["type": .string("boolean")])]),
        "required": .array([.string("ok")]), "additionalProperties": .bool(false)])
    return .init(definition: .init(name: name, description: "Synthetic tool", inputSchema: input), revision: 1,
        outputSchema: output, executionMode: mode, timeoutMilliseconds: 1_000, maximumResultBytes: 1_024)
}

private func withParallelFixture<T>(_ fixture: ParallelToolFixture,
                                    _ body: (ParallelToolFixture) async throws -> T) async throws -> T {
    do { let result = try await body(fixture); await fixture.shutdown(); return result }
    catch { await fixture.shutdown(); throw error }
}

private func withCancellationFixture<T>(_ fixture: CancellationToolFixture,
                                        _ body: (CancellationToolFixture) async throws -> T) async throws -> T {
    do { let result = try await body(fixture); await fixture.shutdown(); return result }
    catch { await fixture.shutdown(); throw error }
}

private func withToolExecutorFixture<T>(_ fixture: ToolExecutorFixture,
                                        _ body: (ToolExecutorFixture) async throws -> T) async throws -> T {
    do {
        let result = try await body(fixture)
        await fixture.shutdown()
        return result
    } catch {
        await fixture.shutdown()
        throw error
    }
}

private func requireCommitted(_ result: SessionCommitResult) throws {
    guard case .committed = result else { throw MiraError(.storage, "Synthetic session setup did not commit.") }
}

private func toolBusinessDatabase(path: String) throws -> DatabaseQueue {
    var configuration = Configuration()
    configuration.foreignKeysEnabled = true
    configuration.prepareDatabase { try $0.execute(sql: "PRAGMA synchronous = FULL") }
    return try DatabaseQueue(path: path, configuration: configuration)
}

/// These executor fixtures use synthetic sources; production workflows use the journal authorizer.
struct ToolFixtureSourceAuthorizer: AgentSourceAuthorizer {
    func validate(_ sources: [AgentSourceReference], for request: AgentContextRequest) async throws {}
}

private actor RevokingToolSourceAuthorizer: AgentSourceAuthorizer {
    let rejectOnCheck: Int
    private(set) var checks = 0
    private(set) var observedSources: [[AgentSourceReference]] = []
    init(rejectOnCheck: Int) { self.rejectOnCheck = rejectOnCheck }
    func validate(_ sources: [AgentSourceReference], for request: AgentContextRequest) async throws {
        checks += 1
        observedSources.append(sources)
        if checks >= rejectOnCheck { throw MiraError(.unauthorized, "Synthetic inherited source revocation.") }
    }
}
