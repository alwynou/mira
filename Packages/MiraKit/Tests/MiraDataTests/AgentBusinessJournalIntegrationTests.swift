import Foundation
import Testing
import GRDB
@testable import MiraCore
@testable import MiraData

@Suite("Agent business journal integration")
struct AgentBusinessJournalIntegrationTests {
    @Test func indeterminateCommitPublishesJournalReceiptAndReopensExactlyOnce() async throws {
        let fixture = try await BusinessJournalFixture.make(afterCommitHook: { throw HookFailure.failed })
        try await withFixture(fixture) { fixture in
            let proof = try await fixture.prepareIntent()
            let outcome = await fixture.business.commit(proof)
            guard case .indeterminate = outcome else {
                Issue.record("A post-commit failure did not surface indeterminate outcome: \(outcome)")
                return
            }
            guard case let .committed(receipt) = await fixture.business.receipt(for: proof) else {
                Issue.record("The durable receipt was not recoverable after uncertainty")
                return
            }
            #expect(receipt.result != nil)
            #expect(try fixture.count() == 1)

            let result = try #require(receipt.result)
            let resolved = await fixture.runtime.commit(id: UUID()) { context in
                let resultReference = try await context.stageBytes(result, kind: .toolResult, retentionGroup: UUID())
                return [.toolResolved(.init(invocationID: fixture.invocationID, status: .succeeded,
                    result: resultReference, businessReceipt: receipt.reference, resultWasPurged: false,
                    effectIsKnown: true))]
            }
            guard case .committed(let cursor) = resolved else {
                Issue.record("The durable tool resolution did not commit")
                return
            }
            try await fixture.business.acknowledge(receipt.reference, at: cursor)
            #expect(try await fixture.business.unpublished(after: nil, limit: 10).isEmpty)

            await fixture.runtime.close()
            try await fixture.library.close()
            try await fixture.business.close()
            await fixture.authority.close()
            try fixture.database.close()

            var reopenedLibrary: FileSessionLibrary?
            var reopenedDatabase: DatabaseQueue?
            var reopenedAuthority: SQLiteLibraryAuthority?
            var reopenedBusiness: SQLiteBusinessEffects?
            var reopenedRuntime: SessionRuntime?
            do {
                let openedLibrary = try FileSessionLibrary(directory: fixture.directory)
                reopenedLibrary = openedLibrary
                let reopenedResolver = JournalAgentEffectResolver(journal: openedLibrary, payloads: openedLibrary)
                let openedDatabase = try businessJournalDatabase(path: fixture.databasePath)
                reopenedDatabase = openedDatabase
                let openedAuthority = try SQLiteLibraryAuthority(database: openedDatabase)
                reopenedAuthority = openedAuthority
                let openedBusiness = try SQLiteBusinessEffects(database: openedDatabase, libraryID: openedAuthority.libraryID, resolver: reopenedResolver,
                    handlers: [fixture.handler], validator: FixtureValidator())
                reopenedBusiness = openedBusiness
                let openedRuntime = try await SessionRuntime.open(id: fixture.sessionID,
                    journal: openedLibrary, payloads: openedLibrary)
                reopenedRuntime = openedRuntime
                guard case let .committed(reopenedReceipt) = await openedBusiness.receipt(for: proof) else {
                    throw MiraError(.storage, "The receipt did not survive reopening.")
                }
                #expect(reopenedReceipt.reference == receipt.reference)
                #expect(try await openedBusiness.unpublished(after: nil, limit: 10).isEmpty)
                #expect(try fixture.count() == 1)
                #expect(await openedRuntime.snapshot().invocations[fixture.invocationID]?.resolution?.businessReceipt == receipt.reference)
                await openedRuntime.close()
                try await openedBusiness.close()
                await openedAuthority.close()
                try await openedLibrary.close()
                try openedDatabase.close()
            } catch {
                await reopenedRuntime?.close()
                if let reopenedBusiness { try? await reopenedBusiness.close() }
                if let reopenedAuthority { await reopenedAuthority.close() }
                if let reopenedLibrary { try? await reopenedLibrary.close() }
                if let reopenedDatabase { try? reopenedDatabase.close() }
                throw error
            }
        }
    }

    @Test func forgedOrUndispatchedIntentIsRejectedBeforeSQLiteMutation() async throws {
        let undispatched = try await BusinessJournalFixture.make()
        try await withFixture(undispatched) { fixture in
            let proof = try await fixture.prepareIntent(dispatch: false)
            guard case .notCommitted = await fixture.business.commit(proof) else {
                Issue.record("An undispatched intent reached the business handler")
                return
            }
            #expect(try fixture.count() == 0)
        }

        let forged = try await BusinessJournalFixture.make(proposalCallDigestMatches: false)
        try await withFixture(forged) { fixture in
            let proof = try await fixture.prepareIntent()
            guard case .notCommitted = await fixture.business.commit(proof) else {
                Issue.record("A proposal with a forged call digest reached the business handler")
                return
            }
            #expect(try fixture.count() == 0)
            guard case .absent = await fixture.business.receipt(for: proof) else {
                Issue.record("A rejected forged proof created a receipt")
                return
            }
        }
    }

    @Test func durableExecutionFenceBlocksValidProofWithoutReceipt() async throws {
        let fixture = try await BusinessJournalFixture.make()
        try await withFixture(fixture) { fixture in
            let proof = try await fixture.prepareIntent()
            try await fixture.business.fenceExecution(sessionID: fixture.sessionID, executionID: fixture.executionID)
            guard case .notCommitted = await fixture.business.commit(proof) else {
                Issue.record("A fenced execution reached the business handler")
                return
            }
            #expect(try fixture.count() == 0)
            guard case .absent = await fixture.business.receipt(for: proof) else {
                Issue.record("A fenced proof unexpectedly has a receipt")
                return
            }
        }
    }

    @Test func sessionAndBusinessEpochRevocationBlocksValidDispatchedProof() async throws {
        let sessionRevoked = try await BusinessJournalFixture.make()
        try await withFixture(sessionRevoked) { fixture in
            let proof = try await fixture.prepareIntent()
            let current = await fixture.runtime.snapshot()
            let invalidation = await fixture.runtime.commit(id: UUID()) { _ in
                [.invalidated(.init(operationID: UUID(), executionIDs: [], retentionGroups: [],
                    authorizationEpoch: current.authorizationEpoch + 1, reason: .permissionRevoked))]
            }
            try requireCommitted(invalidation, "Session epoch invalidation")
            guard case .notCommitted = await fixture.business.commit(proof) else {
                Issue.record("A session epoch-revoked proof reached the business handler")
                return
            }
            #expect(try fixture.count() == 0)
            guard case .absent = await fixture.business.receipt(for: proof) else {
                Issue.record("A session epoch-revoked proof unexpectedly has a receipt")
                return
            }
        }

        let businessRevoked = try await BusinessJournalFixture.make()
        try await withFixture(businessRevoked) { fixture in
            let proof = try await fixture.prepareIntent()
            let current = try await fixture.authority.authorization()
            let request = AgentLibraryMaintenanceRequest(id: UUID(), namespace: "tests.invalidate", revision: 1,
                scope: .library, requestedAt: Date())
            let operation = try await fixture.authority.begin(request, expected: current)
            try await fixture.business.purgeResults(receiptIDs: [], maintenance: operation)
            _ = try await fixture.authority.complete(operation, at: Date())
            guard case .notCommitted = await fixture.business.commit(proof) else {
                Issue.record("A business epoch-revoked proof reached the business handler")
                return
            }
            #expect(try fixture.count() == 0)
            guard case .absent = await fixture.business.receipt(for: proof) else {
                Issue.record("A business epoch-revoked proof unexpectedly has a receipt")
                return
            }
        }
    }
}

private enum HookFailure: Error { case failed }

private func withFixture<T>(_ fixture: BusinessJournalFixture,
                            _ body: (BusinessJournalFixture) async throws -> T) async throws -> T {
    do {
        let result = try await body(fixture)
        await fixture.shutdown()
        return result
    } catch {
        await fixture.shutdown()
        throw error
    }
}

private struct CounterHandler: SQLiteBusinessCommandHandler {
    let namespace = "tests"

    func businessKey(for effect: AgentResolvedEffect) throws -> String { "journal-counter" }

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

private final class BusinessJournalFixture: Sendable {
    let directory: URL
    let databasePath: String
    let library: FileSessionLibrary
    let database: DatabaseQueue
    let business: SQLiteBusinessEffects
    let authority: SQLiteLibraryAuthority
    let runtime: SessionRuntime
    let handler = CounterHandler()
    let sessionID: ConversationID
    let executionID: ExecutionID
    let invocationID: UUID
    let attemptID: UUID
    let toolCall: CanonicalToolCall
    let route: AgentModelRoute
    let toolDefinition: ToolDefinition
    let proposalCallDigestMatches: Bool

    static func make(proposalCallDigestMatches: Bool = true,
                     afterCommitHook: (@Sendable () throws -> Void)? = nil) async throws -> BusinessJournalFixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mira-business-journal-\(UUID().uuidString)")
        let library = try FileSessionLibrary(directory: directory)
        let databasePath = directory.appendingPathComponent("business.sqlite").path
        let resolver = JournalAgentEffectResolver(journal: library, payloads: library)
        let database = try businessJournalDatabase(path: databasePath)
        let authority = try SQLiteLibraryAuthority(database: database)
        var business: SQLiteBusinessEffects?
        var runtime: SessionRuntime?
        do {
            let madeBusiness = try SQLiteBusinessEffects(database: database, libraryID: authority.libraryID, resolver: resolver,
                handlers: [CounterHandler()], validator: FixtureValidator(), afterCommitHook: afterCommitHook)
            business = madeBusiness
            let sessionID = ConversationID()
            let executionID = ExecutionID()
            let openedRuntime = try await SessionRuntime.open(id: sessionID, journal: library, payloads: library)
            runtime = openedRuntime
            let route = AgentModelRoute(id: RouteID(), revision: 1, connectionID: ConnectionID(), connectionRevision: 1,
            modelDescriptorID: ModelDescriptorID(), modelRevision: 1, modelAuthorizationRevision: 1, adapter: .init(id: "synthetic.model", revision: 1),
            invocationID: "test-invocation", invocationRevision: 1, endpointID: "test-endpoint", metadataEvidence: [], modelID: "fixture", credential: nil, contextWindow: 4_096, maximumOutputTokens: 512,
            capabilities: .init(streamsText: true, callsTools: true, producesThinking: true), configuration: .object([:]))
            let toolDefinition = ToolDefinition(name: "tests.write", description: "Synthetic write",
            inputSchema: .object(["type": .string("object"), "properties": .object([:]),
                "additionalProperties": .bool(false)]))
            return BusinessJournalFixture(directory: directory, databasePath: databasePath, library: library, database: database,
            business: madeBusiness, authority: authority, runtime: openedRuntime, sessionID: sessionID, executionID: executionID, invocationID: UUID(),
            attemptID: UUID(), toolCall: .init(id: "call-1", name: toolDefinition.name, arguments: "{}"), route: route,
            toolDefinition: toolDefinition, proposalCallDigestMatches: proposalCallDigestMatches)
        } catch {
            await runtime?.close()
            if let business { try? await business.close() }
            await authority.close(); try? await library.close(); try? database.close()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private init(directory: URL, databasePath: String, library: FileSessionLibrary, database: DatabaseQueue, business: SQLiteBusinessEffects, authority: SQLiteLibraryAuthority,
                 runtime: SessionRuntime, sessionID: ConversationID, executionID: ExecutionID, invocationID: UUID,
                 attemptID: UUID, toolCall: CanonicalToolCall, route: AgentModelRoute, toolDefinition: ToolDefinition,
                 proposalCallDigestMatches: Bool) {
        self.directory = directory; self.databasePath = databasePath; self.library = library; self.database = database; self.business = business
        self.authority = authority; self.runtime = runtime; self.sessionID = sessionID; self.executionID = executionID; self.invocationID = invocationID
        self.attemptID = attemptID; self.toolCall = toolCall; self.route = route; self.toolDefinition = toolDefinition
        self.proposalCallDigestMatches = proposalCallDigestMatches
    }

    func prepareIntent(dispatch: Bool = true) async throws -> AgentEffectProof {
        let userID = MessageID()
        _ = try await admit(userID: userID)
        let request = AgentContextRequest(sessionID: sessionID, executionID: executionID, workspaceID: nil,
            userText: "Question", authorizationEpoch: 0, destination: .model(route))
        let input = AgentModelInput(stepID: attemptID, executionID: executionID, instructions: "Answer.",
            messages: [.init(role: .user, blocks: [.init(id: "text", content: .text("Question"))])], tools: [toolDefinition])
        let prepared = AgentPreparedModelRequest(adapter: route.adapter, input: input, wirePayload: .object([:]), estimatedInputTokens: 1)
        let build = AgentContextBuild(request: request, prepared: prepared, inheritedSources: [], evidence: [], omissions: [])
        let attemptCommit = await runtime.commit(id: UUID()) { context in
            let staged = try await AgentRequestRecord.stage(build, context: context)
            return [.phaseChanged(executionID: executionID, phase: .preparing),
                    .attemptStarted(.init(id: attemptID, executionID: executionID, stepID: attemptID, stepIndex: 1,
                        attemptIndex: 1, request: staged.request, contents: staged.contents))]
        }
        try requireCommitted(attemptCommit, "Attempt start")

        let invocation = await runtime.commit(id: UUID()) { context in
            let output = try await context.stageBytes(Data("model output".utf8), kind: .modelOutput, retentionGroup: UUID())
            let callRef = try await context.stage(toolCall, kind: .toolCall, retentionGroup: UUID())
            return [.attemptResolved(.init(attemptID: attemptID, status: .completed, output: output)),
                    .toolProposed(.init(id: invocationID, attemptID: attemptID, modelOrder: 0,
                        toolName: toolDefinition.name, effect: .localWrite, call: callRef)),
                    .phaseChanged(executionID: executionID, phase: .waitingForTools)]
        }
        try requireCommitted(invocation, "Tool proposal")
        // Read the committed reference so the proposal digest names the exact journal bytes.
        guard let callRef = (await runtime.snapshot().invocations[invocationID]?.invocation.call) else {
            throw MiraError(.storage, "The tool call was not recorded.")
        }
        let proposalDigest = proposalCallDigestMatches ? callRef.digest : String(repeating: "b", count: 64)
        let proposal = makeProposal(callDigest: proposalDigest)
        let auth = try await authority.authorization()
        let intentCommit = await runtime.commit(id: UUID()) { context in
            let proposalRef = try await context.stage(proposal, kind: .effectIntent, retentionGroup: UUID())
            var facts: [SessionFact] = [.toolPrepared(.init(invocationID: invocationID, authorization: auth, proposal: proposalRef))]
            if dispatch { facts.append(.toolDispatched(invocationID: invocationID, authorizationEpoch: 0)) }
            return facts
        }
        try requireCommitted(intentCommit, "Tool intent")
        let state = await runtime.snapshot()
        guard let intent = state.invocations[invocationID]?.intent else { throw MiraError(.storage, "The tool intent was not recorded.") }
        return .init(sessionID: sessionID, executionID: executionID, invocationID: invocationID,
            intentBatchID: intent.batchID, intentSequence: intent.sequence, authorization: intent.intent.authorization,
            proposal: intent.intent.proposal)
    }

    private func admit(userID: MessageID) async throws -> SessionPayloadReference {
        let result = await runtime.commit(id: UUID()) { context in
            let title = try await context.stageBytes(Data("Synthetic".utf8), kind: .title, retentionGroup: UUID())
            let user = try await context.stageBytes(Data("Question".utf8), kind: .userText, retentionGroup: UUID())
            let routeRef = try await context.stage(AgentExecutionPlan(runtimeID: UUID(), catalogGeneration: 0, driverID: "mira.default", driverRevision: 1, instructions: "Answer.", limits: .init(), priority: .foreground, route: route), kind: .executionPlan, retentionGroup: UUID())
            return [.opened(.init(workspaceID: nil, title: title)),
                    .admitted(.init(executionID: executionID, userMessageID: userID, userBody: user, plan: routeRef, hasModelRoute: true,
                        authorizationEpoch: 0, timeZoneIdentifier: "UTC"))]
        }
        try requireCommitted(result, "Admission")
        return try #require((await runtime.snapshot()).executions[executionID]?.admission.plan)
    }

    private func makeProposal(callDigest: String) -> AgentToolProposal {
        let output: JSONValue = .object(["type": .string("object"),
            "properties": .object(["ok": .object(["type": .string("boolean")])]),
            "required": .array([.string("ok")]), "additionalProperties": .bool(false)])
        let descriptor = AgentToolDescriptor(definition: toolDefinition, revision: 1, outputSchema: output,
            executionMode: .exclusive, timeoutMilliseconds: 1_000, maximumResultBytes: 1_024)
        return .init(descriptor: descriptor, effect: .localWrite, businessNamespace: "tests", callDigest: callDigest, inheritedSources: [],
            plan: .init(input: .object([:]), sources: [], targets: []))
    }

    func count() throws -> Int {
        let db = try DatabaseQueue(path: databasePath)
        defer { try? db.close() }
        return try db.read { db in
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'synthetic_counter')") == true else { return 0 }
            return try Int.fetchOne(db, sql: "SELECT count FROM synthetic_counter WHERE id = 1") ?? 0
        }
    }

    func shutdown() async {
        await runtime.close()
        try? await library.close()
        try? await business.close()
        await authority.close()
        try? database.close()
        try? FileManager.default.removeItem(at: directory)
    }
}

private func requireCommitted(_ result: SessionCommitResult, _ operation: String) throws {
    guard case .committed = result else { throw MiraError(.storage, "\(operation) did not commit.") }
}

private func businessJournalDatabase(path: String) throws -> DatabaseQueue {
    var configuration = Configuration()
    configuration.foreignKeysEnabled = true
    configuration.prepareDatabase { try $0.execute(sql: "PRAGMA synchronous = FULL") }
    return try DatabaseQueue(path: path, configuration: configuration)
}
