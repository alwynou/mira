import Foundation
import GRDB
import Testing

@testable import MiraCore
@testable import MiraData

private enum KnowledgePrivacyScenario: CaseIterable, Sendable {
    case revoke, delete, scopeCommit, domainCommit, beforeBlobRemoval, afterBlobRemoval
    var action: KnowledgePrivacyAction { self == .revoke ? .revokeRemoteUse : .deleteSource }
    var fault: KnowledgeStorageFaultStage? {
        switch self {
        case .revoke, .delete: nil
        case .scopeCommit: .afterPrivacyScopeCommit
        case .domainCommit: .afterDomainPrivacyCommit
        case .beforeBlobRemoval: .beforeBlobRemoval
        case .afterBlobRemoval: .afterBlobRemoval
        }
    }
}

@Suite("Knowledge privacy workflows", .timeLimit(.minutes(1)))
struct KnowledgePrivacyWorkflowTests {
    @Test(arguments: KnowledgePrivacyScenario.allCases)
    fileprivate func sourceHistoryAndDescendantsFollowOriginalPlan(scenario: KnowledgePrivacyScenario) async throws {
        try await withTaskWorkflow(knowledgeEnabled: true) { f in
            let original = try #require(f.knowledge)
            let app = KnowledgeApplication(
                store: original, reader: .init(journal: f.library, payloads: f.library),
                access: f.access, scope: f.scope, now: { TaskWorkflowFixture.now })
            let originalText = "# Original\nThe original source body."
            let selectedFile = f.directory.appendingPathComponent("user-selected.md")
            try Data(originalText.utf8).write(to: selectedFile)
            let imported = try await app.importMarkdown(
                .init(title: "privacy.md", bytes: Data(originalText.utf8)),
                workspaceID: nil, operationID: UUID())
            let allowed = try await app.allowRemoteUse(
                imported.source.id, workspaceID: nil,
                expectedRevision: imported.source.revision, operationID: UUID())
            let detail = try await app.detail(
                imported.source.id, versionID: imported.version.id,
                scope: .init(workspaceID: nil, destination: .model(f.route)))
            let chunk = try #require(detail.chunks.first)
            let read = CanonicalToolCall(
                id: "read-old", name: "source.read_chunk",
                arguments: "{\"chunk_id\":\"\(chunk.id.rawValue.uuidString.lowercased())\"}")
            await f.model.append([
                modelToolStream([read]),
                [
                    .blockStarted(.init(id: "thinking", content: .thinking("Source reasoning"))),
                    .blockFinished(id: "thinking"),
                    .blockStarted(.init(id: "text", content: .text("Answer grounded in the original source."))), .blockFinished(id: "text"), .finished(.stop),
                ],
            ])
            let first = try await f.run("Read the source")
            let updated = try await app.importMarkdown(
                .init(title: "privacy.md", bytes: Data("# Updated\nA later source body.".utf8)),
                workspaceID: nil, updating: imported.source.id, expectedRevision: allowed.revision, operationID: UUID())
            await f.model.append([[.blockStarted(.init(id: "text", content: .text("Follow-up answer."))), .blockFinished(id: "text"), .finished(.stop)]])
            let followup = try await f.run("Continue from that source", sessionID: first.sessionID)
            await f.model.append([[.blockStarted(.init(id: "text", content: .text("Unrelated answer."))), .blockFinished(id: "text"), .finished(.stop)]])
            let unrelated = try await f.run("An unrelated question")
            let affected = try await f.runtime.sessionSnapshot(id: first.sessionID)
            let other = try await f.runtime.sessionSnapshot(id: unrelated.sessionID)
            let visible = affected.references.values.filter {
                [.userText, .visibleAnswer, .visibleThinking].contains($0.kind)
            }
            let hidden = affected.references.values.filter {
                ![.title, .userText, .visibleAnswer, .visibleThinking].contains($0.kind)
            }
            let beforeVisible = try await bytes(visible, from: f.library)
            let otherReferences = Array(other.references.values)
            let beforeOther = try await bytes(otherReferences, from: f.library)
            #expect(visible.contains { $0.kind == .visibleThinking })
            #expect(!hidden.isEmpty)

            let projection = try SQLiteSessionProjection(
                path: f.directory.appendingPathComponent("privacy-projection.sqlite").path)
            let query = try SessionProjectionCoordinator(journal: f.library, projection: projection)
            _ = try await query.catchUp(sessionID: first.sessionID)
            _ = try await query.catchUp(sessionID: unrelated.sessionID)
            let projections = try SessionPrivacyProjections(
                journal: f.library, payloads: f.library, stores: [projection])
            var plans = try SQLiteSessionPrivacyPlanStore(database: f.database, libraryID: f.authority.libraryID)
            var business = try SQLiteBusinessPrivacyStore(database: f.database, libraryID: f.authority.libraryID)
            var knowledge = try SQLiteKnowledgeStore(
                database: f.database, libraryID: f.authority.libraryID,
                directory: f.directory.appendingPathComponent("knowledge"),
                faultInjector: { stage in
                    if stage == scenario.fault {
                        throw MiraError(.storage, "Synthetic knowledge maintenance interruption.")
                    }
                })
            var libraryScope = RuntimeScope(kind: .library(f.authority.libraryID))
            let registry = RuntimeRegistry<any AgentLibraryMaintenanceHandler>()
            var handler = KnowledgePrivacyHandler(
                action: scenario.action, knowledge: knowledge, blobs: knowledge,
                sessions: SessionPrivacyMaintenance(journal: f.library, payloads: f.library, plans: plans),
                plans: plans, business: business, projections: projections)
            try await registry.register(id: "knowledge.privacy", value: handler, scope: libraryScope)
            var coordinator = try AgentLibraryMaintenanceCoordinator(
                access: f.access, handlers: registry,
                workOwners: [
                    .application(id: "runtime", runtime: f.runtime),
                    .init(id: "readers") {
                        await query.close()
                        await app.close()
                        await original.close()
                        await f.tasks.close()
                        await f.reminders.close()
                        await f.scope.dispose()
                        try await f.business.close()
                    },
                ], now: { TaskWorkflowFixture.now.addingTimeInterval(1) })
            do {
                let expected = try await f.authority.authorization()
                let request = AgentLibraryMaintenanceRequest(
                    id: UUID(), namespace: scenario.action.namespace, revision: 1,
                    scope: .sources([KnowledgeSources.metadata(updated.source)]), requestedAt: TaskWorkflowFixture.now)
                var savedScope: KnowledgePrivacyScope?
                var savedPlan: SessionPrivacyPlan?
                if scenario.fault != nil {
                    await #expect(throws: MiraError.self) {
                        _ = try await coordinator.perform(request, expected: expected)
                    }
                    let pending = try #require(try await f.authority.state().pending)
                    #expect(pending.request == request)
                    #expect(await f.access.snapshot().phase == .maintenance)
                    savedScope = try await knowledge.prepareKnowledgePrivacy(operation: pending)
                    savedPlan = try await plans.load(operation: pending)
                    if scenario == .scopeCommit {
                        #expect(savedPlan == nil)
                    } else {
                        #expect(savedPlan?.changes.count == 1)
                    }
                    await coordinator.close()
                    await libraryScope.dispose()
                    await knowledge.close()
                    await plans.close()
                    await business.close()
                    knowledge = try SQLiteKnowledgeStore(
                        database: f.database, libraryID: f.authority.libraryID,
                        directory: f.directory.appendingPathComponent("knowledge"))
                    plans = try SQLiteSessionPrivacyPlanStore(database: f.database, libraryID: f.authority.libraryID)
                    business = try SQLiteBusinessPrivacyStore(database: f.database, libraryID: f.authority.libraryID)
                    #expect(try await knowledge.prepareKnowledgePrivacy(operation: pending) == savedScope)
                    libraryScope = RuntimeScope(kind: .library(f.authority.libraryID))
                    handler = KnowledgePrivacyHandler(
                        action: scenario.action, knowledge: knowledge, blobs: knowledge,
                        sessions: SessionPrivacyMaintenance(journal: f.library, payloads: f.library, plans: plans),
                        plans: plans, business: business, projections: projections)
                    try await registry.register(id: "knowledge.privacy", value: handler, scope: libraryScope)
                    coordinator = try AgentLibraryMaintenanceCoordinator(
                        access: f.access, handlers: registry, workOwners: [],
                        now: { TaskWorkflowFixture.now.addingTimeInterval(1) })
                }
                let completed = try await coordinator.perform(request, expected: expected)
                #expect(completed.completedAt != nil)
                #expect(try await f.authority.state().pending == nil)
                #expect(await f.access.snapshot().phase == .ready)
                // Inspect persisted facts directly; completed operations no longer authorize maintenance APIs.
                let encoded = try #require(
                    try await f.database.read { db in
                        try Data.fetchOne(
                            db, sql: "SELECT plan_json FROM session_privacy_plans WHERE operation_id = ?",
                            arguments: [request.id.uuidString])
                    })
                let plan = try SessionCodec.decode(SessionPrivacyPlan.self, from: encoded)
                #expect(plan.roots.contains(KnowledgeSources.chunk(chunk)))
                #expect(plan.roots.contains(KnowledgeSources.metadata(imported.source)))
                #expect(plan.roots.contains(KnowledgeSources.metadata(updated.source)))
                if let savedPlan { #expect(plan == savedPlan) }
                for change in plan.changes {
                    #expect(
                        try await f.library.batch(id: change.batch.id, sessionID: change.batch.sessionID)
                            == change.batch)
                }
                let state = try await JournalSessionReader(journal: f.library, payloads: f.library).snapshot(
                    sessionID: first.sessionID
                ).state
                #expect(state.excludedExecutionIDs == [first.executionID, followup.executionID])
                let messages = try await projection.messages(
                    sessionID: first.sessionID, beforeSequence: nil, limit: 100)
                #expect(messages.count == 4)
                #expect(messages.allSatisfy { $0.isExcludedFromContext })
                if scenario.action == .revokeRemoteUse {
                    #expect(messages.allSatisfy { !$0.bodyInvalidated && !$0.thinkingInvalidated })
                    #expect(
                        try await knowledge.sourceChunk(chunk.id, scope: .init(workspaceID: nil, destination: .local))
                            .text == originalText)
                    #expect(try await bytes(visible, from: f.library) == beforeVisible)
                } else {
                    #expect(messages.filter { $0.role == .user }.allSatisfy { !$0.bodyInvalidated })
                    #expect(messages.filter { $0.role == .assistant }.allSatisfy { $0.bodyInvalidated })
                    #expect(messages.contains { $0.thinkingInvalidated })
                    for (reference, previous) in zip(visible, beforeVisible) {
                        if reference.kind == .userText {
                            #expect(try await f.library.read(reference) == previous)
                        } else {
                            await #expect(throws: MiraError.self) { _ = try await f.library.read(reference) }
                        }
                    }
                    await #expect(throws: MiraError.self) {
                        _ = try await knowledge.knowledgeSource(
                            imported.source.id, versionID: nil, scope: .init(workspaceID: nil, destination: .local))
                    }
                    #expect(
                        try ManagedBlobStore(directory: f.directory.appendingPathComponent("knowledge")).digests()
                            .isEmpty)
                }
                for reference in hidden {
                    await #expect(throws: MiraError.self) { _ = try await f.library.read(reference) }
                }
                await #expect(throws: MiraError.self) {
                    _ = try await knowledge.sourceChunk(
                        chunk.id, scope: .init(workspaceID: nil, destination: .model(f.route)))
                }
                #expect(try Data(contentsOf: selectedFile) == Data(originalText.utf8))
                #expect(try await bytes(otherReferences, from: f.library) == beforeOther)
                #expect(
                    try await projection.executions(sessionID: unrelated.sessionID, beforeSequence: nil, limit: 20)
                        .allSatisfy { !$0.isExcludedFromContext })
                await #expect(throws: MiraError.self) { try await handler.verify(completed) }
            } catch {
                await coordinator.close()
                await libraryScope.dispose()
                await query.close()
                await app.close()
                await knowledge.close()
                await plans.close()
                await business.close()
                try? await projection.close()
                throw error
            }
            await coordinator.close()
            await libraryScope.dispose()
            await query.close()
            await app.close()
            await knowledge.close()
            await plans.close()
            await business.close()
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
