import Foundation
import GRDB
import Testing

@testable import MiraCore
@testable import MiraData

@Suite("Memory forget through the current kernel", .timeLimit(.minutes(1)))
struct MemoryForgetWorkflowTests {
    @Test(arguments: [false, true])
    func forgetPurgesDomainAndHiddenHistoryWhilePreservingVisibleMessages(reopenAfterPurge: Bool) async throws {
        let text = "I prefer green tea"
        let input: JSONValue = .object([
            "content": .string(text), "quote": .string(text),
            "kind": .string("preference"), "scope": .string("current"), "sensitive": .bool(false),
        ])
        let remember = try CanonicalToolCall(id: "remember", name: "memory.remember", arguments: input.jsonString())
        let search = CanonicalToolCall(id: "recall", name: "memory.search", arguments: "{\"query\":\"green tea\"}")
        try await withTaskWorkflow(
            outputs: [
                modelToolStream([remember]), [.blockStarted(.init(id: "text", content: .text("Saved locally."))), .blockFinished(id: "text"), .finished(.stop)],
                modelToolStream([search]), [.blockStarted(.init(id: "text", content: .text("You prefer green tea."))), .blockFinished(id: "text"), .finished(.stop)],
                [.blockStarted(.init(id: "text", content: .text("Independent answer"))), .blockFinished(id: "text"), .finished(.stop)],
            ], memoryEnabled: true
        ) { f in
            let source = try await f.run("Remember: " + text)
            let memoryStore = try #require(f.memory)
            let original = try #require(
                try await memoryStore.memoryList(workspaceID: nil, states: [.active], query: "", limit: 10).memories
                    .first)
            var draft = try #require(original.draft)
            draft.allowsRemoteUse = true
            let memory = try await memoryStore.reviseMemory(
                original.id, workspaceID: nil, draft: draft,
                expectedRevision: original.revision, operationID: UUID(), authorization: f.authority.authorization(),
                at: TaskWorkflowFixture.now)
            let recalled = try await f.run("Which tea do I prefer?")
            let unrelated = try await f.run("An independent statement")
            let affected = [source, recalled]
            var hidden: [SessionPayloadReference] = []
            var visible: [SessionPayloadReference] = []
            for address in affected {
                let state = try await f.runtime.sessionSnapshot(id: address.sessionID)
                hidden += state.references.values.filter {
                    ![.title, .userText, .visibleAnswer, .visibleThinking].contains($0.kind)
                }
                visible += state.references.values.filter {
                    [.userText, .visibleAnswer, .visibleThinking].contains($0.kind)
                }
            }
            let beforeVisible = try await bytes(visible, from: f.library)
            let unrelatedState = try await f.runtime.sessionSnapshot(id: unrelated.sessionID)
            let unrelatedReferences = Array(unrelatedState.references.values)
            let beforeUnrelated = try await bytes(unrelatedReferences, from: f.library)
            let receiptsBefore = try await f.database.read { db in
                try Int.fetchOne(db, sql: "SELECT count(*) FROM business_receipts")
            }
            #expect(receiptsBefore == 1)
            let projection = try SQLiteSessionProjection(
                path: f.directory.appendingPathComponent("projection.sqlite").path)
            let query = try SessionProjectionCoordinator(journal: f.library, projection: projection)
            for address in affected + [unrelated] { _ = try await query.catchUp(sessionID: address.sessionID) }
            var plans = try SQLiteSessionPrivacyPlanStore(database: f.database, libraryID: f.authority.libraryID)
            var business = try SQLiteBusinessPrivacyStore(database: f.database, libraryID: f.authority.libraryID)
            var currentMemory = memoryStore
            var libraryScope = RuntimeScope(kind: .library(f.authority.libraryID))
            let registry = RuntimeRegistry<any AgentLibraryMaintenanceHandler>()
            let projections = try SessionPrivacyProjections(
                journal: f.library, payloads: f.library, stores: [projection])
            let fault = ForgetPurgeFault(store: memoryStore, fail: reopenAfterPurge)
            var handler = MemoryForgetHandler(
                memories: fault,
                sessions: SessionPrivacyMaintenance(journal: f.library, payloads: f.library, plans: plans),
                plans: plans, business: business, projections: projections)
            try await registry.register(id: "memory.forget", value: handler, scope: libraryScope)
            var coordinator = try AgentLibraryMaintenanceCoordinator(
                access: f.access, handlers: registry,
                workOwners: [
                    .application(id: "runtime", runtime: f.runtime),
                    .init(id: "readers") {
                        await query.close()
                        await f.tasks.close()
                        await f.reminders.close()
                        await f.scope.dispose()
                        try await f.business.close()
                    },
                ], now: { TaskWorkflowFixture.now.addingTimeInterval(1) })
            do {
                let expected = try await f.authority.authorization()
                let request = AgentLibraryMaintenanceRequest(
                    id: UUID(), namespace: "memory.forget", revision: 1,
                    scope: .sources([.domain(namespace: "memories", id: memory.id.rawValue, revision: memory.revision)]
                    ),
                    requestedAt: TaskWorkflowFixture.now)
                var saved: SessionPrivacyPlan?
                if reopenAfterPurge {
                    await #expect(throws: MiraError.self) {
                        _ = try await coordinator.perform(request, expected: expected)
                    }
                    let pending = try #require(try await f.authority.state().pending)
                    #expect(await f.access.snapshot().phase == .maintenance)
                    saved = try #require(try await plans.load(operation: pending))
                    #expect(saved?.changes.count == 2)
                    #expect(try await f.library.read(hidden[0]).isEmpty == false)
                    await coordinator.close()
                    await libraryScope.dispose()
                    await plans.close()
                    await business.close()
                    await currentMemory.close()
                    plans = try SQLiteSessionPrivacyPlanStore(database: f.database, libraryID: f.authority.libraryID)
                    business = try SQLiteBusinessPrivacyStore(database: f.database, libraryID: f.authority.libraryID)
                    currentMemory = try SQLiteMemoryStore(database: f.database, libraryID: f.authority.libraryID)
                    libraryScope = RuntimeScope(kind: .library(f.authority.libraryID))
                    handler = MemoryForgetHandler(
                        memories: currentMemory,
                        sessions: SessionPrivacyMaintenance(journal: f.library, payloads: f.library, plans: plans),
                        plans: plans, business: business, projections: projections)
                    try await registry.register(id: "memory.forget", value: handler, scope: libraryScope)
                    coordinator = try AgentLibraryMaintenanceCoordinator(
                        access: f.access, handlers: registry, workOwners: [],
                        now: { TaskWorkflowFixture.now.addingTimeInterval(1) })
                }
                let completed = try await coordinator.perform(request, expected: expected)
                #expect(completed.completedAt != nil)
                #expect(try await f.authority.state().pending == nil)
                #expect(await f.access.snapshot().phase == .ready)
                let detail = try await currentMemory.memoryDetail(memory.id, workspaceID: nil)
                #expect(detail.memory.forgottenAt == request.requestedAt)
                #expect(detail.memory.draft == nil)
                #expect(detail.revisions.allSatisfy { $0.draft == nil && $0.bodyPurgedAt != nil })
                #expect(detail.evidence.allSatisfy { $0.excerpt == nil && $0.sourceHash == nil })
                let historyScope = RuntimeScope(kind: .application)
                let extraction = try SQLiteMemoryExtractionStore(database: f.database, libraryID: f.authority.libraryID)
                let historyReader = JournalSessionReader(journal: f.library, payloads: f.library)
                let history = MemoryApplication(store: currentMemory, extractionStatusReader: extraction, reader: historyReader, privacyHistory: plans,
                    access: f.access, scope: historyScope, now: { TaskWorkflowFixture.now })
                do {
                    for address in affected {
                        let head = try await f.library.head(sessionID: address.sessionID)
                        let expectedNotices = [address.executionID: [MemoryContextNotice(memoryID: memory.id, reason: .forgotten)]]
                        #expect(try await history.contextNotices(sessionID: address.sessionID,
                            executionIDs: [address.executionID], workspaceID: nil) == expectedNotices)
                        #expect(try await history.contextNotices(sessionID: address.sessionID,
                            executionIDs: [address.executionID], workspaceID: nil) == expectedNotices)
                        #expect(try await f.library.head(sessionID: address.sessionID) == head)
                        await #expect(throws: MiraError.self) {
                            try await history.citation(.init(memoryID: memory.id, revision: memory.revision),
                                sessionID: address.sessionID, executionID: address.executionID, workspaceID: nil)
                        }
                        await #expect(throws: MiraError.self) {
                            try await historyReader.executionSources([.sessionExecution(sessionID: address.sessionID,
                                executionID: address.executionID)])
                        }
                    }
                    #expect(try await history.contextNotices(sessionID: unrelated.sessionID,
                        executionIDs: [unrelated.executionID], workspaceID: nil).isEmpty)
                    let digest = try #require(try await f.database.read { db in
                        try String.fetchOne(db, sql: "SELECT digest FROM session_privacy_plans WHERE operation_id = ?",
                            arguments: [request.id.uuidString])
                    })
                    try await f.database.write { db in
                        try db.execute(sql: "UPDATE session_privacy_plans SET digest = 'invalid' WHERE operation_id = ?",
                            arguments: [request.id.uuidString])
                    }
                    await #expect(throws: MiraError.self) {
                        try await history.contextNotices(sessionID: recalled.sessionID,
                            executionIDs: [recalled.executionID], workspaceID: nil)
                    }
                    try await f.database.write { db in
                        try db.execute(sql: "UPDATE session_privacy_plans SET digest = ? WHERE operation_id = ?",
                            arguments: [digest, request.id.uuidString])
                    }
                } catch {
                    await history.close(); await historyScope.dispose(); await extraction.close(); throw error
                }
                await history.close(); await historyScope.dispose(); await extraction.close()
                for reference in hidden {
                    await #expect(throws: MiraError.self) { _ = try await f.library.read(reference) }
                }
                #expect(try await bytes(visible, from: f.library) == beforeVisible)
                #expect(try await bytes(unrelatedReferences, from: f.library) == beforeUnrelated)
                for address in affected {
                    let state = try await JournalSessionReader(journal: f.library, payloads: f.library).snapshot(
                        sessionID: address.sessionID
                    ).state
                    #expect(state.excludedExecutionIDs == [address.executionID])
                    let messages = try await projection.messages(
                        sessionID: address.sessionID, beforeSequence: nil, limit: 100)
                    #expect(messages.count == 2)
                    #expect(
                        messages.allSatisfy {
                            $0.isExcludedFromContext && !$0.bodyInvalidated && !$0.thinkingInvalidated
                        })
                    if let saved, let change = saved.changes.first(where: { $0.batch.sessionID == address.sessionID }) {
                        // The persisted plan keeps exact batch identity across adapter recreation.
                        #expect(
                            try await f.library.batch(id: change.batch.id, sessionID: address.sessionID) == change.batch
                        )
                        let roundTrip = try SessionCodec.decode(
                            SessionBatch.self, from: SessionCodec.encode(change.batch))
                        try await projection.apply(roundTrip)
                    }
                }
                #expect(
                    try await projection.executions(sessionID: unrelated.sessionID, beforeSequence: nil, limit: 10)
                        .allSatisfy { !$0.isExcludedFromContext })
                #expect(
                    try await f.database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM business_receipts") }
                        == receiptsBefore)
                #expect(
                    try await f.database.read {
                        try Int.fetchOne(
                            $0,
                            sql:
                                "SELECT count(*) FROM business_operations WHERE result_blob IS NOT NULL OR result_purged != 1"
                        )
                    } == 0)
                await #expect(throws: MiraError.self) { try await handler.verify(completed) }
            } catch {
                await coordinator.close()
                await libraryScope.dispose()
                await query.close()
                await plans.close()
                await business.close()
                await currentMemory.close()
                try? await projection.close()
                throw error
            }
            await coordinator.close()
            await libraryScope.dispose()
            await query.close()
            await plans.close()
            await business.close()
            await currentMemory.close()
            try await projection.close()
        }
    }

    private func bytes(_ references: [SessionPayloadReference], from library: FileSessionLibrary) async throws -> [Data]
    {
        var result: [Data] = []
        for reference in references { result.append(try await library.read(reference)) }
        return result
    }
}

private actor ForgetPurgeFault: MemoryPrivacyStore {
    let store: SQLiteMemoryStore
    var fail: Bool
    init(store: SQLiteMemoryStore, fail: Bool) {
        self.store = store
        self.fail = fail
    }
    func memoryForgetScope(operation: AgentLibraryMaintenanceOperation) async throws -> MemoryForgetScope {
        try await store.memoryForgetScope(operation: operation)
    }
    func purgeMemoryForget(_ scope: MemoryForgetScope, operation: AgentLibraryMaintenanceOperation) async throws {
        try await store.purgeMemoryForget(scope, operation: operation)
        if fail {
            fail = false
            throw MiraError(.storage, "Synthetic interruption after memory purge.")
        }
    }
    func verifyMemoryForgotten(_ scope: MemoryForgetScope, operation: AgentLibraryMaintenanceOperation) async throws {
        try await store.verifyMemoryForgotten(scope, operation: operation)
    }
}
