import Foundation
import GRDB
import Testing

@testable import MiraCore
@testable import MiraData

@Suite("Session privacy maintenance", .timeLimit(.minutes(1)))
struct SessionPrivacyMaintenanceTests {
    @Test func selectingARetryAlsoInvalidatesItsOriginalFailedExecution() async throws {
        try await withTaskWorkflow(outputs: [[], [.blockStarted(.init(id: "text", content: .text("Retry answer"))), .blockFinished(id: "text"), .finished(.stop)]]) { f in
            let failed = try await f.run("A recoverable statement", expectedStatus: .failed)
            let retried = ExecutionID()
            let command = AgentSubmitCommand(
                id: UUID(), sessionID: failed.sessionID, executionID: retried,
                input: .retry(executionID: failed.executionID),
                options: .init(instructions: "Retry the statement.", route: f.route))
            try taskRequireCommitted(await f.runtime.submit(command))
            try taskRequireCommitted(await f.runtime.waitForExecution(id: retried, sessionID: failed.sessionID))
            #expect(
                try await f.runtime.sessionSnapshot(id: failed.sessionID).executions[retried]?.completion?.status
                    == .completed)
            #expect(await f.runtime.shutdown().isSettled)
            await f.tasks.close()
            await f.reminders.close()
            await f.scope.dispose()
            let expected = try await f.authority.authorization()
            let source = AgentSourceReference.sessionExecution(sessionID: failed.sessionID, executionID: retried)
            let request = AgentLibraryMaintenanceRequest(
                id: UUID(), namespace: "privacy.fixture", revision: 1,
                scope: .sources([source]), requestedAt: TaskWorkflowFixture.now)
            let operation = try await f.access.begin(request, expected: expected)
            let plans = try SQLiteSessionPrivacyPlanStore(database: f.database, libraryID: f.authority.libraryID)
            do {
                let engine = SessionPrivacyMaintenance(journal: f.library, payloads: f.library, plans: plans)
                let plan = try await engine.prepare(
                    operation: operation, roots: [source], retention: .preserveVisibleHistory, reason: .forgotten)
                let change = try #require(plan.changes.first)
                #expect(Set(change.dependencies.map(\.executionID)) == [failed.executionID, retried])
                try await engine.apply(operation: operation)
                try await engine.verify(operation: operation)
                let state = try await JournalSessionReader(journal: f.library, payloads: f.library).snapshot(
                    sessionID: failed.sessionID
                ).state
                #expect(state.excludedExecutionIDs == [failed.executionID, retried])
                let body = try #require(state.executions[failed.executionID]?.admission.userBody)
                #expect(try await f.library.read(body) == Data("A recoverable statement".utf8))
            } catch {
                await plans.close()
                throw error
            }
            await plans.close()
        }
    }

    @Test func realToolRequestsDraftsAndOrphansArePurgedThroughTheLibraryCoordinator() async throws {
        let outputs: [[AgentModelStreamEvent]] = [
            modelToolStream([.init(id: "task-list", name: "task.list", arguments: "{}")]),
            [.blockStarted(.init(id: "text", content: .text("Visible task answer"))), .blockFinished(id: "text"), .finished(.stop)],
        ]
        try await withTaskWorkflow(outputs: outputs) { f in
            let task = try await f.save(draft: .init(title: "Private task evidence"))
            let address = try await f.run("List tasks")
            let original = try await f.runtime.sessionSnapshot(id: address.sessionID)
            let hidden = original.references.values.filter {
                ![.title, .userText, .visibleAnswer, .visibleThinking].contains($0.kind)
            }
            #expect(
                Set(hidden.map(\.kind)).isSuperset(of: [
                    .request, .modelOutput, .toolCall, .effectIntent, .toolResult, .replay, .draft, .executionPlan,
                ]))
            let visible = original.references.values.filter { [.userText, .visibleAnswer].contains($0.kind) }
            let visibleBytes = try await visible.asyncPrivacyBytes(from: f.library)
            // A cancelled command can leave staged bytes with no published journal owner.
            let orphan = try await f.library.stage(
                Data("Unpublished private draft".utf8), sessionID: address.sessionID,
                batchID: UUID(), retentionGroup: UUID(), kind: .draft)
            let orphanURL = f.directory.appendingPathComponent("sessions/payloads")
                .appendingPathComponent(address.sessionID.rawValue.uuidString).appendingPathComponent(
                    orphan.batchID.uuidString
                )
                .appendingPathComponent(orphan.id.uuidString + ".bin")
            let plans = try SQLiteSessionPrivacyPlanStore(database: f.database, libraryID: f.authority.libraryID)
            let scope = RuntimeScope(kind: .library(f.authority.libraryID))
            let registry = RuntimeRegistry<any AgentLibraryMaintenanceHandler>()
            let source = AgentSourceReference.domain(namespace: "tasks", id: task.id.rawValue, revision: task.revision)
            let engine = SessionPrivacyMaintenance(journal: f.library, payloads: f.library, plans: plans)
            let handler = PrivacyHandler(engine: engine, roots: [source])
            try await registry.register(id: "privacy.fixture", value: handler, scope: scope)
            let coordinator = try AgentLibraryMaintenanceCoordinator(
                access: f.access, handlers: registry,
                workOwners: [
                    .application(id: "application", runtime: f.runtime),
                    .init(id: "domain-applications") {
                        await f.tasks.close()
                        await f.reminders.close()
                        await f.scope.dispose()
                    },
                ])
            do {
                let expected = try await f.authority.authorization()
                let request = AgentLibraryMaintenanceRequest(
                    id: UUID(), namespace: handler.identity.namespace, revision: 1,
                    scope: .sources([source]), requestedAt: TaskWorkflowFixture.now)
                let completed = try await coordinator.perform(request, expected: expected)
                #expect(completed.completedAt != nil)
                #expect(try await f.authority.state().pending == nil)
                for reference in hidden { await expectCode(.notFound) { try await f.library.read(reference) } }
                #expect(try await visible.asyncPrivacyBytes(from: f.library) == visibleBytes)
                #expect(!FileManager.default.fileExists(atPath: orphanURL.path))
                try Data("Unknown orphan".utf8).write(to: orphanURL)
                await #expect(throws: MiraError.self) { try await f.library.verifyNoUnpublished() }
                try await f.library.purgeUnpublished()
                try await f.library.verifyNoUnpublished()
                let current = try await JournalSessionReader(journal: f.library, payloads: f.library).snapshot(
                    sessionID: address.sessionID)
                #expect(current.state.excludedExecutionIDs == [address.executionID])
            } catch {
                await coordinator.close()
                await scope.dispose()
                await plans.close()
                throw error
            }
            await coordinator.close()
            await scope.dispose()
            await plans.close()
        }
    }

    @Test("Privacy roots expand through cross-session replay dependencies and preserve visible history")
    func expandsCrossSessionClosureAndPreservesVisibleHistory() async throws {
        try await withPrivacyFixture { fixture in
            try await withPrivacyPlanStore(fixture) { plans in
                let operation = try await fixture.beginOperation(id: UUID())
                let maintenance = SessionPrivacyMaintenance(
                    journal: fixture.library, payloads: fixture.library, plans: plans)
                let plan = try await maintenance.prepare(
                    operation: operation, roots: [fixture.root], retention: .preserveVisibleHistory, reason: .forgotten)

                #expect(Set(plan.changes.map(\.batch.sessionID)) == Set(fixture.chain.map(\.sessionID)))
                for session in fixture.chain {
                    let change = try #require(plan.changes.first { $0.batch.sessionID == session.sessionID })
                    #expect(change.dependencies.first?.sources == session.sources)
                    #expect(
                        change.batch.events.compactMap { event -> SessionInvalidation? in
                            guard case .invalidated(let fact) = event.fact else { return nil }
                            return fact
                        }.first?.retentionGroups == session.hiddenGroups)
                }
                #expect(plan.changes.contains { $0.batch.sessionID == fixture.unrelated.sessionID } == false)

                try await maintenance.apply(operation: operation)
                try await maintenance.verify(operation: operation)
                await #expect(throws: MiraError.self) {
                    try await plans.retainedHistory(sessionID: fixture.chain[0].sessionID,
                        operationIDs: [operation.request.id], executionIDs: [fixture.chain[0].executionID])
                }
                for session in fixture.chain {
                    let state = try await JournalSessionReader(journal: fixture.library, payloads: fixture.library)
                        .snapshot(sessionID: session.sessionID).state
                    #expect(state.excludedExecutionIDs == Set([session.executionID]))
                    #expect(try await fixture.library.read(session.user) == Data("user".utf8))
                    #expect(try await fixture.library.read(session.answer) == Data("answer".utf8))
                    #expect(try await fixture.library.read(session.thinking) == Data("thinking".utf8))
                    await expectCode(.notFound) { _ = try await fixture.library.read(session.plan) }
                    await expectCode(.notFound) { _ = try await fixture.library.read(session.replay) }
                    #expect(
                        try await plans.retainedDependencies(
                            sessionID: session.sessionID,
                            invalidationIDs: [operation.request.id], operation: operation)
                            == [.init(executionID: session.executionID, sources: session.sources)])
                }
                #expect(
                    (try await JournalSessionReader(journal: fixture.library, payloads: fixture.library)
                        .snapshot(sessionID: fixture.unrelated.sessionID).state.excludedExecutionIDs).isEmpty)

                let completed = try await fixture.authority.complete(operation, at: fixture.date.addingTimeInterval(1))
                for session in fixture.chain {
                    let records = try await plans.retainedHistory(sessionID: session.sessionID,
                        operationIDs: [operation.request.id], executionIDs: [session.executionID])
                    let record = try #require(records.first)
                    #expect(records.count == 1 && record.request == operation.request)
                    #expect(record.batch == plan.changes.first { $0.batch.sessionID == session.sessionID }?.batch)
                    #expect(record.dependencies == [.init(executionID: session.executionID, sources: [fixture.root])])
                    let reader = JournalSessionReader(journal: fixture.library, payloads: fixture.library)
                    let snapshot = try await reader.snapshot(sessionID: session.sessionID)
                    let contexts = try await reader.historyContexts(in: snapshot,
                        executionIDs: [session.executionID], privacyHistory: plans)
                    #expect(contexts[session.executionID]?.sources == [fixture.root])
                    #expect(contexts[session.executionID]?.connectionID == nil)
                    let changedBatch = SessionBatch(id: UUID(), sessionID: record.batch.sessionID,
                        expectedSequence: record.batch.expectedSequence, events: record.batch.events)
                    let forged = FixedPrivacyHistory(records: [.init(batch: changedBatch, request: record.request,
                        dependencies: record.dependencies)])
                    await #expect(throws: MiraError.self) {
                        try await reader.historyContexts(in: snapshot, executionIDs: [session.executionID], privacyHistory: forged)
                    }
                }
                await #expect(throws: MiraError.self) {
                    try await plans.retainedHistory(sessionID: fixture.unrelated.sessionID,
                        operationIDs: [operation.request.id], executionIDs: [fixture.unrelated.executionID])
                }
                let next = try await fixture.beginOperation(id: UUID(), expected: completed.authorization)
                let generated = try await SessionPrivacyMaintenance(
                    journal: fixture.library, payloads: fixture.library, plans: plans
                )
                .prepare(operation: next, roots: [fixture.root], retention: .purgeGeneratedHistory, reason: .forgotten)
                #expect(Set(generated.changes.map(\.batch.sessionID)) == Set(fixture.chain.map(\.sessionID)))
                try await SessionPrivacyMaintenance(journal: fixture.library, payloads: fixture.library, plans: plans)
                    .apply(operation: next)
                for session in fixture.chain {
                    await expectCode(.notFound) { _ = try await fixture.library.read(session.answer) }
                    await expectCode(.notFound) { _ = try await fixture.library.read(session.thinking) }
                }
                _ = try await fixture.authority.complete(next, at: fixture.date.addingTimeInterval(2))
            }
        }
    }

    @Test("An acknowledgement loss leaves a durable plan that a new store reuses")
    func acknowledgementLossReusesPersistedPlan() async throws {
        try await withPrivacyFixture { fixture in
            let failing = try SQLiteSessionPrivacyPlanStore(
                database: fixture.database, libraryID: fixture.authority.libraryID,
                afterCommitHook: { throw MiraError(.storage, "Synthetic plan acknowledgement loss.") })
            var reopened: SQLiteSessionPrivacyPlanStore?
            do {
                let operation = try await fixture.beginOperation(id: UUID())
                let failedMaintenance = SessionPrivacyMaintenance(
                    journal: fixture.library, payloads: fixture.library, plans: failing)
                await #expect(throws: MiraError.self) {
                    _ = try await failedMaintenance.prepare(
                        operation: operation, roots: [fixture.root], retention: .preserveVisibleHistory,
                        reason: .forgotten)
                }
                await failing.close()
                reopened = try SQLiteSessionPrivacyPlanStore(
                    database: fixture.database, libraryID: fixture.authority.libraryID)
                let store = try #require(reopened)
                let reused = try await SessionPrivacyMaintenance(
                    journal: fixture.library, payloads: fixture.library, plans: store
                )
                .prepare(
                    operation: operation, roots: [fixture.root], retention: .preserveVisibleHistory, reason: .forgotten)
                let loaded = try await SessionPrivacyMaintenance(
                    journal: fixture.library, payloads: fixture.library, plans: store
                )
                .prepare(
                    operation: operation, roots: [fixture.root], retention: .preserveVisibleHistory, reason: .forgotten)
                #expect(reused == loaded)
                await store.close()
            } catch {
                await failing.close()
                await reopened?.close()
                throw error
            }
        }
    }

    @Test(
        "Journal and delete faults resume the original plan",
        arguments: [SessionStorageFaultStage.beforePayloadDelete, .afterJournalSync])
    func deleteFaultReopensFromPersistentPlan(stage: SessionStorageFaultStage) async throws {
        try await withPrivacyFixture { fixture in
            let plans = try SQLiteSessionPrivacyPlanStore(
                database: fixture.database, libraryID: fixture.authority.libraryID)
            do {
                let operation = try await fixture.beginOperation(id: UUID())
                let maintenance = SessionPrivacyMaintenance(
                    journal: fixture.library, payloads: fixture.library, plans: plans)
                let plan = try await maintenance.prepare(
                    operation: operation, roots: [fixture.root], retention: .preserveVisibleHistory, reason: .forgotten)
                for runtime in fixture.runtimes { await runtime.close() }
                try await fixture.library.close()

                let faulty = try FileSessionLibrary(
                    directory: fixture.directory.appendingPathComponent("sessions"),
                    faultInjector: { currentStage in
                        if currentStage == stage { throw MiraError(.storage, "Synthetic payload delete fault.") }
                    })
                let faultyMaintenance = SessionPrivacyMaintenance(journal: faulty, payloads: faulty, plans: plans)
                await #expect(throws: MiraError.self) { try await faultyMaintenance.apply(operation: operation) }
                if stage == .afterJournalSync {
                    await #expect(throws: MiraError.self) { try await faulty.purgeUnpublished() }
                }
                try await faulty.close()
                await plans.close()

                let reopenedLibrary = try FileSessionLibrary(
                    directory: fixture.directory.appendingPathComponent("sessions"))
                let reopenedPlans = try SQLiteSessionPrivacyPlanStore(
                    database: fixture.database, libraryID: fixture.authority.libraryID)
                do {
                    let reopenedMaintenance = SessionPrivacyMaintenance(
                        journal: reopenedLibrary, payloads: reopenedLibrary, plans: reopenedPlans)
                    try await reopenedMaintenance.apply(operation: operation)
                    let restoredURL = fixture.payloadURL(fixture.chain[0].plan)
                    try Data("restored".utf8).write(to: restoredURL)
                    await #expect(throws: MiraError.self) { try await reopenedMaintenance.verify(operation: operation) }
                    try FileManager.default.removeItem(at: restoredURL)
                    try await reopenedMaintenance.verify(operation: operation)
                    #expect(try await reopenedPlans.load(operation: operation) == plan)
                    _ = try await fixture.authority.complete(operation, at: fixture.date.addingTimeInterval(1))
                    await reopenedPlans.close()
                    try await reopenedLibrary.close()
                } catch {
                    await reopenedPlans.close()
                    try? await reopenedLibrary.close()
                    throw error
                }
            } catch {
                await plans.close()
                throw error
            }
        }
    }

    @Test("A captured plan rejects new sessions and active executions")
    func planRejectsUnexpectedWritersAndActiveExecution() async throws {
        try await withPrivacyFixture { fixture in
            try await withPrivacyPlanStore(fixture) { plans in
                let operation = try await fixture.beginOperation(id: UUID())
                let maintenance = SessionPrivacyMaintenance(
                    journal: fixture.library, payloads: fixture.library, plans: plans)
                _ = try await maintenance.prepare(
                    operation: operation, roots: [fixture.root], retention: .preserveVisibleHistory, reason: .forgotten)
                let newID = ConversationID()
                let runtime = try await SessionRuntime.open(
                    id: newID, journal: fixture.library, payloads: fixture.library)
                do {
                    let result = await runtime.commit(id: UUID()) { context in
                        let title = try await context.stageBytes(Data("new".utf8), kind: .title, retentionGroup: UUID())
                        return [.opened(.init(workspaceID: nil, title: title))]
                    }
                    try requireCommitted(result)
                    await runtime.close()
                    await #expect(throws: MiraError.self) { try await maintenance.apply(operation: operation) }
                } catch {
                    await runtime.close()
                    throw error
                }
            }
        }

        try await withPrivacyFixture { fixture in
            let activeID = ConversationID()
            let active = try await SessionRuntime.open(
                id: activeID, journal: fixture.library, payloads: fixture.library)
            do {
                let executionID = ExecutionID()
                let admitted = await active.commit(id: UUID()) { context in
                    let title = try await context.stageBytes(Data("active".utf8), kind: .title, retentionGroup: UUID())
                    let body = try await context.stageBytes(
                        Data("active user".utf8), kind: .userText, retentionGroup: UUID())
                    let plan = try await context.stage(
                        AgentExecutionPlan(
                            runtimeID: UUID(), catalogGeneration: 1,
                            driverID: "mira.default", driverRevision: 1, instructions: "Active", limits: .init(),
                            priority: .foreground, route: nil), kind: .executionPlan, retentionGroup: UUID())
                    return [
                        .opened(.init(workspaceID: nil, title: title)),
                        .admitted(
                            .init(
                                executionID: executionID, userMessageID: MessageID(), userBody: body,
                                plan: plan, hasModelRoute: false, authorizationEpoch: 0, timeZoneIdentifier: "UTC")),
                    ]
                }
                try requireCommitted(admitted)
                try await withPrivacyPlanStore(fixture) { plans in
                    let operation = try await fixture.beginOperation(id: UUID())
                    let maintenance = SessionPrivacyMaintenance(
                        journal: fixture.library, payloads: fixture.library, plans: plans)
                    await #expect(throws: MiraError.self) {
                        _ = try await maintenance.prepare(
                            operation: operation, roots: [fixture.root], retention: .preserveVisibleHistory,
                            reason: .forgotten)
                    }
                }
                await active.close()
            } catch {
                await active.close()
                throw error
            }
        }
    }
}

private struct SyntheticSession: Sendable {
    let sessionID: ConversationID
    let executionID: ExecutionID
    let source: AgentSourceReference
    let sources: [AgentSourceReference]
    let user: SessionPayloadReference
    let plan: SessionPayloadReference
    let answer: SessionPayloadReference
    let thinking: SessionPayloadReference
    let replay: SessionPayloadReference
    let hiddenGroups: Set<UUID>
}

private final class PrivacyFixture: @unchecked Sendable {
    let directory: URL
    let database: DatabaseQueue
    let authority: SQLiteLibraryAuthority
    let library: FileSessionLibrary
    let runtimes: [SessionRuntime]
    let chain: [SyntheticSession]
    let unrelated: SyntheticSession
    let root: AgentSourceReference
    let date = Date(timeIntervalSince1970: 1_900_000_000)

    static func make() async throws -> PrivacyFixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mira-session-privacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var database: DatabaseQueue?
        var authority: SQLiteLibraryAuthority?
        var library: FileSessionLibrary?
        var runtimes: [SessionRuntime] = []
        do {
            var configuration = Configuration()
            configuration.foreignKeysEnabled = true
            configuration.prepareDatabase { try $0.execute(sql: "PRAGMA synchronous=FULL") }
            let db = try DatabaseQueue(
                path: directory.appendingPathComponent("business.sqlite").path, configuration: configuration)
            database = db
            let auth = try SQLiteLibraryAuthority(database: db)
            authority = auth
            let sessions = try FileSessionLibrary(directory: directory.appendingPathComponent("sessions"))
            library = sessions
            let root = AgentSourceReference.domain(namespace: "privacy.fixture", id: UUID(), revision: 1)
            let ids = (0..<4).map { _ in ConversationID() }
            for id in ids {
                runtimes.append(try await SessionRuntime.open(id: id, journal: sessions, payloads: sessions))
            }
            let a = try await makeCompleted(runtimes[0], sources: [root])
            let b = try await makeCompleted(runtimes[1], sources: [a.source])
            let c = try await makeCompleted(runtimes[2], sources: [b.source])
            let unrelated = try await makeCompleted(runtimes[3], sources: [])
            return PrivacyFixture(
                directory: directory, database: db, authority: auth, library: sessions,
                runtimes: runtimes, chain: [a, b, c], unrelated: unrelated, root: root)
        } catch {
            for runtime in runtimes { await runtime.close() }
            try? await library?.close()
            await authority?.close()
            try? database?.close()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func beginOperation(id: UUID, expected: AgentLibraryAuthorization? = nil) async throws
        -> AgentLibraryMaintenanceOperation
    {
        let authorization = try await authority.authorization()
        let request = AgentLibraryMaintenanceRequest(
            id: id, namespace: "session.privacy.fixture", revision: 1,
            scope: .library, requestedAt: date)
        return try await authority.begin(request, expected: expected ?? authorization)
    }

    func payloadURL(_ reference: SessionPayloadReference) -> URL {
        directory.appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("payloads", isDirectory: true)
            .appendingPathComponent(reference.sessionID.rawValue.uuidString, isDirectory: true)
            .appendingPathComponent(reference.batchID.uuidString, isDirectory: true)
            .appendingPathComponent(reference.id.uuidString + ".bin")
            .standardizedFileURL
    }

    func close() async {
        for runtime in runtimes { await runtime.close() }
        try? await library.close()
        await authority.close()
        try? database.close()
        try? FileManager.default.removeItem(at: directory)
    }

    private init(
        directory: URL, database: DatabaseQueue, authority: SQLiteLibraryAuthority, library: FileSessionLibrary,
        runtimes: [SessionRuntime], chain: [SyntheticSession], unrelated: SyntheticSession,
        root: AgentSourceReference
    ) {
        self.directory = directory
        self.database = database
        self.authority = authority
        self.library = library
        self.runtimes = runtimes
        self.chain = chain
        self.unrelated = unrelated
        self.root = root
    }
}

private func makeCompleted(_ runtime: SessionRuntime, sources: [AgentSourceReference]) async throws -> SyntheticSession
{
    let sessionID = runtime.id
    let executionID = ExecutionID()
    let messageID = MessageID()
    let admission = await runtime.commit(id: UUID()) { context in
        let title = try await context.stageBytes(Data("session".utf8), kind: .title, retentionGroup: UUID())
        let user = try await context.stageBytes(Data("user".utf8), kind: .userText, retentionGroup: UUID())
        let plan = try await context.stage(
            AgentExecutionPlan(
                runtimeID: UUID(), catalogGeneration: 1,
                driverID: "mira.default", driverRevision: 1, instructions: "Fixture", limits: .init(),
                priority: .foreground, route: nil), kind: .executionPlan, retentionGroup: UUID())
        return [
            .opened(.init(workspaceID: nil, title: title)),
            .admitted(
                .init(
                    executionID: executionID, userMessageID: messageID, userBody: user,
                    plan: plan, hasModelRoute: false, authorizationEpoch: 0, timeZoneIdentifier: "UTC")),
        ]
    }
    try requireCommitted(admission)
    let state = await runtime.snapshot()
    let user = try #require(state.executions[executionID]?.admission.userBody)
    let plan = try #require(state.executions[executionID]?.admission.plan)
    try requireCommitted(
        await runtime.commit(id: UUID()) { _ in [.phaseChanged(executionID: executionID, phase: .settling)] })
    let answerText = Data("answer".utf8)
    let thinkingText = Data("thinking".utf8)
    let replay = AgentReplayRecord(messages: [.init(role: .assistant, blocks: [.init(id: "text", content: .text("answer"))])], sources: sources)
    let finished = await runtime.commit(id: UUID()) { context in
        let answer = try await context.stageBytes(answerText, kind: .visibleAnswer, retentionGroup: UUID())
        let thinking = try await context.stageBytes(thinkingText, kind: .visibleThinking, retentionGroup: UUID())
        let replayReference = try await context.stage(replay, kind: .replay, retentionGroup: UUID())
        return [
            .finished(
                .init(
                    executionID: executionID, status: .completed, assistantMessageID: MessageID(),
                    answer: answer, visibleThinking: thinking, replay: replayReference))
        ]
    }
    try requireCommitted(finished)
    let completed = await runtime.snapshot()
    let completion = try #require(completed.executions[executionID]?.completion)
    let answer = try #require(completion.answer)
    let thinking = try #require(completion.visibleThinking)
    let replayRef = try #require(completion.replay)
    return .init(
        sessionID: sessionID, executionID: executionID,
        source: .sessionExecution(sessionID: sessionID, executionID: executionID), sources: sources,
        user: user, plan: plan, answer: answer, thinking: thinking, replay: replayRef,
        hiddenGroups: [plan.retentionGroup, replayRef.retentionGroup])
}

private func requireCommitted(_ result: SessionCommitResult) throws {
    switch result {
    case .committed: return
    case .notCommitted(let error), .indeterminate(_, let error): throw error
    }
}

private func withPrivacyFixture<T>(_ body: (PrivacyFixture) async throws -> T) async throws -> T {
    let fixture = try await PrivacyFixture.make()
    do {
        let value = try await body(fixture)
        await fixture.close()
        return value
    } catch {
        await fixture.close()
        throw error
    }
}

private func withPrivacyPlanStore<T>(
    _ fixture: PrivacyFixture,
    _ body: (SQLiteSessionPrivacyPlanStore) async throws -> T
) async throws -> T {
    let plans = try SQLiteSessionPrivacyPlanStore(database: fixture.database, libraryID: fixture.authority.libraryID)
    do {
        let value = try await body(plans)
        await plans.close()
        return value
    } catch {
        await plans.close()
        throw error
    }
}

private func expectCode<T>(_ expected: MiraError.Code, _ operation: () async throws -> T) async {
    do {
        _ = try await operation()
        Issue.record("Expected MiraError.\(expected), but the operation succeeded.")
    } catch let error as MiraError {
        #expect(error.code == expected)
    } catch {
        Issue.record("Expected MiraError.\(expected), got \(error).")
    }
}

private struct PrivacyHandler: AgentLibraryMaintenanceHandler {
    let identity = AgentLibraryMaintenanceHandlerIdentity(namespace: "privacy.fixture", revision: 1)
    let engine: SessionPrivacyMaintenance
    let roots: [AgentSourceReference]
    func apply(_ operation: AgentLibraryMaintenanceOperation) async throws {
        _ = try await engine.prepare(
            operation: operation, roots: roots, retention: .preserveVisibleHistory, reason: .forgotten)
        try await engine.apply(operation: operation)
    }
    func verify(_ operation: AgentLibraryMaintenanceOperation) async throws {
        try await engine.verify(operation: operation)
    }
}

extension Array where Element == SessionPayloadReference {
    fileprivate func asyncPrivacyBytes(from library: FileSessionLibrary) async throws -> [Data] {
        var result: [Data] = []
        for reference in self { result.append(try await library.read(reference)) }
        return result
    }
}


extension SessionPrivacyMaintenanceTests {
    @Test func projectionVerificationRejectsMissingVisibleHistoryAndRebuildRepairsIt() async throws {
        try await withPrivacyFixture { fixture in
            try await withPrivacyPlanStore(fixture) { plans in
                let operation = try await fixture.beginOperation(id: UUID())
                let engine = SessionPrivacyMaintenance(journal: fixture.library, payloads: fixture.library, plans: plans)
                let plan = try await engine.prepare(operation: operation, roots: [fixture.root],
                    retention: .preserveVisibleHistory, reason: .forgotten)
                try await engine.apply(operation: operation)
                let path = fixture.directory.appendingPathComponent("projection.sqlite").path
                let projection = try SQLiteSessionProjection(path: path)
                let maintenance = try SessionPrivacyProjections(journal: fixture.library, payloads: fixture.library, stores: [projection])
                do {
                    try await maintenance.rebuild(plan: plan)
                    try await maintenance.verify(plan: plan)
                    let change = try #require(plan.changes.first)
                    let decoded = try SessionCodec.decode(SessionBatch.self, from: SessionCodec.encode(change.batch))
                    try await projection.apply(decoded)
                    let tamper = try DatabaseQueue(path: path)
                    do {
                        try await tamper.write { db in
                            try db.execute(sql: "DELETE FROM projection_messages WHERE session_id = ? AND role = 'assistant'",
                                arguments: [change.batch.sessionID.rawValue.uuidString])
                        }
                        try tamper.close()
                    } catch { try? tamper.close(); throw error }
                    await #expect(throws: MiraError.self) { try await maintenance.verify(plan: plan) }
                    try await maintenance.rebuild(plan: plan)
                    try await maintenance.verify(plan: plan)
                    try await projection.close()
                } catch { try? await projection.close(); throw error }
            }
        }
    }
}

private struct FixedPrivacyHistory: SessionPrivacyHistoryReader {
    let records: [SessionPrivacyHistoryRecord]
    func retainedHistory(sessionID: ConversationID, operationIDs: Set<UUID>,
                         executionIDs: Set<ExecutionID>) async throws -> [SessionPrivacyHistoryRecord] { records }
}
