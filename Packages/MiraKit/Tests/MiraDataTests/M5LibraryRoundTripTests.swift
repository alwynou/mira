import Foundation
import GRDB
import MiraCore
import Testing
@testable import MiraData

@Suite("M5 library round trip")
struct M5LibraryRoundTripTests {
    @Test func canonicalBundleRoundTripPreservesScopesVersionsCitationsAndPrivacy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mira-m5-round-trip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let library = root.appendingPathComponent("library", isDirectory: true)
        let store = try SQLiteMiraStore(directory: library)
        let now = Date(timeIntervalSince1970: 4_000.25)
        let workspaceA = Workspace(id: .init(), name: "Writing")
        let workspaceB = Workspace(id: .init(), name: "Research")
        try store.saveWorkspace(workspaceA, expectedRevision: nil)
        try store.saveWorkspace(workspaceB, expectedRevision: nil)

        let connection = ProviderConnection(name: "Synthetic", providerKind: .openAICompatible, baseURL: "https://example.invalid/v1", credentialReference: "m5.fixture")
        try store.saveConnection(connection, expectedRevision: nil)
        let model = ModelDescriptor(connectionID: connection.id, connectionRevision: connection.revision, modelID: "m5-fixture", contextWindow: 65_536, textCapability: .declared)
        try store.saveModel(model, expectedRevision: nil)
        let route = ModelRoute(name: "M5 fixture", modelDescriptorID: model.id, maxOutputTokens: 256)
        try store.saveRoute(route, expectedRevision: nil)

        let conversation = Conversation(id: .init(), workspaceID: workspaceA.id, title: "M5", createdAt: now, updatedAt: now)
        try store.createConversation(conversation)
        let resolved = try store.modelConfiguration().resolve(purpose: .conversation, explicitRouteID: route.id, conversation: conversation, workspace: workspaceA)

        let oldURL = root.appendingPathComponent("public.md")
        try Data("# Public notes\n\nThe original editor workflow.\n".utf8).write(to: oldURL)
        let oldImport = try store.importMarkdownFile(oldURL, workspaceID: nil, updating: nil, expectedRevision: nil, at: now)
        let oldChunk = try #require(store.knowledgeSource(oldImport.source.id, versionID: oldImport.version.id, workspaceID: nil, connectionID: nil).chunks.first)
        try Data("# Public notes\n\nThe current editor workflow.\n".utf8).write(to: oldURL)
        let currentImport = try store.importMarkdownFile(oldURL, workspaceID: nil, updating: oldImport.source.id, expectedRevision: oldImport.source.revision, at: now.addingTimeInterval(1))
        _ = try store.setSourceRemoteUse(currentImport.source.id, workspaceID: nil, allowed: true, expectedRevision: currentImport.source.revision, at: now.addingTimeInterval(2))

        let localURL = root.appendingPathComponent("local.md")
        try Data("# Private notes\n\nResearch workspace local material.\n".utf8).write(to: localURL)
        let localImport = try store.importMarkdownFile(localURL, workspaceID: workspaceB.id, updating: nil, expectedRevision: nil, at: now)

        let active = try store.createMemory(
            draft: .init(content: "The user prefers the current editor workflow.", scope: .global),
            source: .manualEntry(id: UUID(), statement: "The user prefers the current editor workflow."),
            operationID: UUID(), replacing: nil, expectedRevision: nil, at: now
        ).memory
        let candidateDraft = MemoryDraft(content: "The user is evaluating a research editor.", scope: .workspace(workspaceA.id))
        let candidateCreated = try store.createMemory(
            draft: candidateDraft,
            source: .manualEntry(id: UUID(), statement: candidateDraft.content),
            operationID: UUID(), replacing: nil, expectedRevision: nil, at: now
        ).memory
        let candidate = try store.changeMemoryState(candidateCreated.id, workspaceID: workspaceA.id, state: .candidate, expectedRevision: candidateCreated.revision, at: now.addingTimeInterval(1))
        let forgotten = try store.createMemory(
            draft: .init(content: "The user forgot this temporary note.", scope: .global),
            source: .manualEntry(id: UUID(), statement: "The user forgot this temporary note."),
            operationID: UUID(), replacing: nil, expectedRevision: nil, at: now
        ).memory
        _ = try store.forgetMemory(forgotten.id, workspaceID: nil, expectedRevision: forgotten.revision, at: now.addingTimeInterval(2))

        let execution = try store.enqueue(conversationID: conversation.id, text: "Please use the public editor notes.", route: resolved, executionID: .init(), messageID: .init(), at: now.addingTimeInterval(3))
        try store.recordSourceUsage([.init(sourceID: oldImport.source.id, sourceVersionID: oldImport.version.id, chunkID: oldChunk.id)], executionID: execution.id, at: now.addingTimeInterval(3))
        try store.recordMemoryUsage([.init(memoryID: active.id, revision: active.revision)], executionID: execution.id, at: now.addingTimeInterval(3))
        let attemptID = UUID()
        let request = CanonicalModelRequest(executionID: execution.id, system: "", messages: [], requestID: attemptID)
        try store.prepareAttempt(.init(id: attemptID, executionID: execution.id, stepID: UUID(), stepIndex: 1, request: request, createdAt: now.addingTimeInterval(4)))
        try store.finishAttempt(attemptID, output: .init(text: "The current editor workflow is ready.", toolCalls: [], finishReason: .stop), invocations: [], usage: .init(inputTokens: 8, outputTokens: 7), error: nil, at: now.addingTimeInterval(5))
        _ = try store.finish(executionID: execution.id, status: .completed, text: "The current editor workflow is ready.", usage: .init(inputTokens: 8, outputTokens: 7), error: nil, assistantMessageID: .init(), at: now.addingTimeInterval(6))

        let backup = root.appendingPathComponent("m5.bundle", isDirectory: true)
        try store.exportBackup(to: backup)
        let databaseBeforeRestore = try Data(contentsOf: backup.appendingPathComponent("Mira.sqlite"))
        let restoredDirectory = root.appendingPathComponent("restored", isDirectory: true)
        try store.restoreBackup(from: backup, to: restoredDirectory)
        let databaseAfterRestore = try Data(contentsOf: backup.appendingPathComponent("Mira.sqlite"))
        #expect(databaseAfterRestore == databaseBeforeRestore)

        let restored = try SQLiteMiraStore(directory: restoredDirectory)
        let restoredSource = try restored.knowledgeSource(oldImport.source.id, versionID: currentImport.version.id, workspaceID: workspaceA.id, connectionID: resolved.connectionID)
        #expect(restoredSource.source.id == oldImport.source.id)
        #expect(restoredSource.source.currentVersionID == currentImport.version.id)
        #expect(Set(restoredSource.versions.map(\.id)) == Set([oldImport.version.id, currentImport.version.id]))
        let restoredOldChunk = try restored.sourceChunk(oldChunk.id, workspaceID: workspaceA.id, connectionID: resolved.connectionID)
        #expect(restoredOldChunk.text.contains("original editor workflow"))
        #expect(try restored.searchKnowledge(query: "original editor", workspaceID: workspaceA.id, connectionID: nil, limit: 20).hits.isEmpty)
        #expect(try restored.searchKnowledge(query: "current editor", workspaceID: workspaceA.id, connectionID: nil, limit: 20).hits.map(\.source.id) == [oldImport.source.id])
        #expect(try restored.searchKnowledge(query: "Research workspace", workspaceID: workspaceA.id, connectionID: nil, limit: 20).hits.isEmpty)
        #expect(try restored.knowledgeSource(localImport.source.id, versionID: localImport.version.id, workspaceID: workspaceB.id, connectionID: nil).source.workspaceID == workspaceB.id)
        #expect(throws: MiraError.self) { try restored.knowledgeSource(localImport.source.id, versionID: nil, workspaceID: workspaceA.id, connectionID: nil) }
        #expect(Set(try restored.workspaces().map(\.id)) == [workspaceA.id, workspaceB.id])

        let restoredActive = try restored.memoryDetail(active.id, workspaceID: workspaceB.id).memory
        let restoredCandidate = try restored.memoryDetail(candidate.id, workspaceID: workspaceA.id).memory
        #expect(restoredActive.state == .active && restoredActive.revision == active.revision)
        #expect(restoredCandidate.state == .candidate && restoredCandidate.revision == candidate.revision)
        #expect(throws: MiraError.self) { try restored.memoryDetail(candidate.id, workspaceID: workspaceB.id) }
        let forgottenDetail = try restored.memoryDetail(forgotten.id, workspaceID: nil)
        #expect(forgottenDetail.memory.state == .removed && forgottenDetail.memory.forgottenAt != nil && forgottenDetail.memory.draft == nil)
        #expect(forgottenDetail.evidence.count == 1 && forgottenDetail.revisions.count == 2)
        #expect(forgottenDetail.evidence.allSatisfy { $0.excerpt == nil && $0.sourceHash == nil && $0.bodyPurgedAt != nil })
        #expect(forgottenDetail.revisions.allSatisfy { $0.draft == nil && $0.bodyPurgedAt != nil })
        let suppressionReason = try restored.pool.read { db in
            try String.fetchOne(db, sql: "SELECT reason FROM memory_source_suppressions WHERE source_kind = 'manualEntry' AND source_id = ?", arguments: [forgottenDetail.evidence.first?.sourceID.uuidString.lowercased() ?? ""])
        }
        #expect(suppressionReason == "forgotten")

        let sourceCitation = try restored.sourceCitation(.init(versionID: oldImport.version.id, chunkID: oldChunk.id), executionID: execution.id, conversationID: conversation.id)
        #expect(sourceCitation.version.id == oldImport.version.id && sourceCitation.chunk.text.contains("original editor workflow"))
        let memoryCitation = try restored.memoryCitation(.init(memoryID: active.id, revision: active.revision), executionID: execution.id, conversationID: conversation.id)
        #expect(memoryCitation.memory.id == active.id && memoryCitation.revision.revision == active.revision)
        #expect(try restored.messages(in: conversation.id).contains { $0.role == .user && $0.text == "Please use the public editor notes." })
        #expect(try restored.executions(in: conversation.id).allSatisfy { $0.status == .completed })
        #expect(try restored.executions(in: conversation.id).map(\.id) == [execution.id])
        #expect(try restored.messages(in: conversation.id).count == 2)
        #expect(try store.memoryDetail(active.id, workspaceID: nil).memory == restoredActive)
        #expect(try restored.memoryCapturePolicy().mode == .manualOnly)
        #expect(try restored.memoryExtractionJobs(conversationID: nil, limit: 20).isEmpty)
    }
}
