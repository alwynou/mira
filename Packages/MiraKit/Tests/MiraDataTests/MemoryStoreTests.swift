import Foundation
import GRDB
import MiraCore
import Testing
@testable import MiraData

@Suite("SQLite memory store")
struct MemoryStoreTests {
    @Test func manualMemoryRoundTripsAndRevisionUsesCAS() throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteMiraStore(directory: directory)
        let source = UUID()
        let draft = MemoryDraft(content: "Prefers tea", scope: .global)
        let created = try store.createMemory(draft: draft, source: .manualEntry(id: source, statement: "Prefers tea"), operationID: UUID(), replacing: nil, expectedRevision: nil, at: Date(timeIntervalSince1970: 1_000))
        #expect(created.memory.draft == draft)
        #expect(try store.memoryDetail(created.memory.id, workspaceID: nil).evidence.first?.sourceHash?.isEmpty == false)
        var revised = draft
        revised.content = "Prefers green tea"
        let next = try store.reviseMemory(created.memory.id, workspaceID: nil, draft: revised, expectedRevision: 1, at: Date(timeIntervalSince1970: 1_001))
        #expect(next.revision == 2)
        #expect(throws: MiraError.self) { try store.reviseMemory(created.memory.id, workspaceID: nil, draft: draft, expectedRevision: 1, at: .now) }
    }

    @Test func operationReceiptsAreStableAcrossSetOrderingAndForgottenRowsDoNotResurrect() throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteMiraStore(directory: directory)
        let connectionA = ConnectionID(), connectionB = ConnectionID()
        var first = MemoryDraft(content: "Keep this", scope: .global, allowedConnectionIDs: [connectionA, connectionB])
        let operation = UUID()
        let source = UUID()
        let created = try store.createMemory(draft: first, source: .manualEntry(id: source, statement: first.content), operationID: operation, replacing: nil, expectedRevision: nil, at: .now)
        first.allowedConnectionIDs = [connectionB, connectionA]
        let replay = try store.createMemory(draft: first, source: .manualEntry(id: source, statement: first.content), operationID: operation, replacing: nil, expectedRevision: nil, at: .now)
        #expect(replay.memory.id == created.memory.id)
        let forgotten = try store.forgetMemory(created.memory.id, workspaceID: nil, expectedRevision: 1, at: .now)
        #expect(forgotten.memoryID == created.memory.id)
        #expect(throws: MiraError.self) { _ = try store.createMemory(draft: first, source: .manualEntry(id: source, statement: first.content), operationID: operation, replacing: nil, expectedRevision: nil, at: .now) }
        #expect(throws: MiraError.self) { _ = try store.createMemory(draft: first, source: .manualEntry(id: source, statement: first.content), operationID: UUID(), replacing: nil, expectedRevision: nil, at: .now) }
        let fresh = try store.createMemory(draft: first, source: .manualEntry(id: UUID(), statement: first.content), operationID: UUID(), replacing: nil, expectedRevision: nil, at: .now)
        #expect(fresh.memory.id != created.memory.id)
    }

    @Test func committedUserEvidenceIsExactAndAssistantEvidenceIsRejected() throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteMiraStore(directory: directory)
        let route = try installFixture(in: store)
        let conversation = Conversation(id: .init(), workspaceID: nil, title: "", createdAt: .now, updatedAt: .now)
        try store.createConversation(conversation)
        let execution = try store.enqueue(conversationID: conversation.id, text: "User fact", route: route, executionID: .init(), messageID: .init(), at: .now)
        let user = try store.messages(in: conversation.id).first!
        let draft = MemoryDraft(content: "User fact", scope: .global)
        let created = try store.createMemory(draft: draft, source: .message(id: user.id, excerpt: "User fact"), operationID: UUID(), replacing: nil, expectedRevision: nil, at: .now)
        #expect(try store.memoryDetail(created.memory.id, workspaceID: nil).evidence.first?.sourceID == user.id.rawValue)
        _ = try store.finish(executionID: execution.id, status: .failed, text: "Assistant", usage: .init(), error: .init(.network, "failed"), assistantMessageID: .init(), at: .now)
        let assistant = try store.messages(in: conversation.id).first { $0.role == .assistant }!
        #expect(throws: MiraError.self) { _ = try store.createMemory(draft: draft, source: .message(id: assistant.id, excerpt: "Assistant"), operationID: UUID(), replacing: nil, expectedRevision: nil, at: .now) }
        _ = try store.forgetMemory(created.memory.id, workspaceID: nil, expectedRevision: created.memory.revision, at: .now)
        let recreated = try store.createMemory(draft: draft, source: .message(id: user.id, excerpt: "User fact"), operationID: UUID(), replacing: nil, expectedRevision: nil, at: .now)
        #expect(recreated.memory.id != created.memory.id)
    }

    @Test func emptyRecallReturnsNoUnrelatedMemoriesAndForgetRedactsLinkedExecution() throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteMiraStore(directory: directory)
        let route = try installFixture(in: store)
        let conversation = Conversation(id: .init(), workspaceID: nil, title: "", createdAt: .now, updatedAt: .now)
        try store.createConversation(conversation)
        let execution = try store.enqueue(conversationID: conversation.id, text: "User source", route: route, executionID: .init(), messageID: .init(), at: .now)
        let source = try store.messages(in: conversation.id).first!
        let memory = try store.createMemory(draft: .init(content: "Remember source", scope: .global), source: .message(id: source.id, excerpt: "User source"), operationID: UUID(), replacing: nil, expectedRevision: nil, at: .now).memory
        #expect(try store.recallMemories(query: "", workspaceID: nil, connectionID: route.connectionID, limit: 20, at: .now).memories.isEmpty)
        let requestID = UUID()
        let request = CanonicalModelRequest(executionID: execution.id, system: "", messages: [], requestID: requestID)
        try store.prepareAttempt(.init(id: requestID, executionID: execution.id, stepID: .init(), stepIndex: 1, request: request, createdAt: .now))
        try store.recordMemoryUsage([MemoryUsage(memoryID: memory.id, revision: memory.revision)], executionID: execution.id, at: .now)
        let receipt = try store.forgetMemory(memory.id, workspaceID: nil, expectedRevision: 1, at: .now)
        #expect(receipt.redactedExecutionIDs.contains(execution.id))
        #expect(try store.attempts(for: execution.id).first?.request == nil)
        #expect(try store.executions(in: conversation.id).first?.bodyPurgedAt != nil)
        #expect(throws: MiraError.self) { try store.checkpoint(executionID: execution.id, text: "late body", at: .now) }
    }

    @Test func recallUsesEntityIDAllowlistsTemporalPolicyAndPunctuationTokens() throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteMiraStore(directory: directory)
        let route = try installFixture(in: store)
        let now = Date(timeIntervalSince1970: 1_000)
        let allowed = try store.createMemory(
            draft: .init(content: "Preferred editor", scope: .global, allowedConnectionIDs: [route.connectionID], validFrom: Date(timeIntervalSince1970: 900), validUntil: Date(timeIntervalSince1970: 1_100)),
            source: .manualEntry(id: UUID(), statement: "Preferred editor"), operationID: UUID(), replacing: nil, expectedRevision: nil, at: now).memory
        _ = try store.createMemory(
            draft: .init(content: "Other editor", scope: .global, allowedConnectionIDs: [ConnectionID()], validFrom: Date(timeIntervalSince1970: 900), validUntil: Date(timeIntervalSince1970: 1_100)),
            source: .manualEntry(id: UUID(), statement: "Other editor"), operationID: UUID(), replacing: nil, expectedRevision: nil, at: now)
        _ = try store.createMemory(
            draft: .init(content: "Expired editor", scope: .global, allowedConnectionIDs: [route.connectionID], validUntil: Date(timeIntervalSince1970: 999)),
            source: .manualEntry(id: UUID(), statement: "Expired editor"), operationID: UUID(), replacing: nil, expectedRevision: nil, at: now)

        let result = try store.recallMemories(query: "Tell me about my editor.", workspaceID: nil, connectionID: route.connectionID, limit: 20, at: now)
        #expect(result.memories.map(\.id) == [allowed.id])
    }

    @Test func globalMemoryInheritsSourceWorkspaceOutboundPolicy() throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteMiraStore(directory: directory)
        let route = try installFixture(in: store)
        let sourceWorkspace = Workspace(id: .init(), name: "Source", allowsRemoteSend: false)
        try store.saveWorkspace(sourceWorkspace, expectedRevision: nil)
        let conversation = Conversation(id: .init(), workspaceID: sourceWorkspace.id, title: "", createdAt: .now, updatedAt: .now)
        try store.createConversation(conversation)
        let execution = try store.enqueue(conversationID: conversation.id, text: "Source fact", route: route, executionID: .init(), messageID: .init(), at: .now)
        let sourceMessage = try store.messages(in: conversation.id).first!
        let memory = try store.createMemory(draft: .init(content: "Source fact", scope: .global), source: .message(id: sourceMessage.id, excerpt: "Source fact"), operationID: UUID(), replacing: nil, expectedRevision: nil, at: .now).memory

        #expect(try store.recallMemories(query: "Source fact", workspaceID: nil, connectionID: route.connectionID, limit: 20, at: .now).memories.isEmpty)

        let enabledWorkspace = Workspace(id: sourceWorkspace.id, name: sourceWorkspace.name, allowsRemoteSend: true, revision: 2, allowedConnectionIDs: [route.connectionID])
        try store.saveWorkspace(enabledWorkspace, expectedRevision: 1)
        #expect(try store.recallMemory(memory.id, workspaceID: nil, connectionID: route.connectionID, at: .now).id == memory.id)
        _ = execution
    }

    @Test func sharedSourceSuppressionKeepsStrongestReasonAcrossMemoryStates() throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteMiraStore(directory: directory)
        let sourceID = UUID()
        let first = try store.createMemory(draft: .init(content: "First assertion", scope: .global), source: .manualEntry(id: sourceID, statement: "Reviewed statement"), operationID: UUID(), replacing: nil, expectedRevision: nil, at: .now).memory
        let second = try store.createMemory(draft: .init(content: "Second assertion", scope: .global), source: .manualEntry(id: sourceID, statement: "Reviewed statement"), operationID: UUID(), replacing: nil, expectedRevision: nil, at: .now).memory
        _ = try store.changeMemoryState(second.id, workspaceID: nil, state: .rejected, expectedRevision: second.revision, at: .now)
        _ = try store.forgetMemory(first.id, workspaceID: nil, expectedRevision: first.revision, at: .now)
        let backup = directory.deletingLastPathComponent().appendingPathComponent("mira-shared-suppression-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: backup) }
        try store.exportBackup(to: backup)
    }

    @Test func replacementConfirmationRequiresSuccessorChainAndBothCASRevisions() throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteMiraStore(directory: directory)
        let old = try store.createMemory(draft: .init(content: "Old preference", scope: .global), source: .manualEntry(id: UUID(), statement: "Old preference"), operationID: UUID(), replacing: nil, expectedRevision: nil, at: .now).memory
        let current = try store.createMemory(draft: .init(content: "Current preference", scope: .global), source: .manualEntry(id: UUID(), statement: "Current preference"), operationID: UUID(), replacing: old.id, expectedRevision: old.revision, at: .now).memory
        let candidate = try store.createMemory(draft: .init(content: "Competing preference", scope: .global), source: .manualEntry(id: UUID(), statement: "Competing preference"), operationID: UUID(), replacing: old.id, expectedRevision: old.revision + 1, at: .now).memory
        let unrelated = try store.createMemory(draft: .init(content: "Unrelated preference", scope: .global), source: .manualEntry(id: UUID(), statement: "Unrelated preference"), operationID: UUID(), replacing: nil, expectedRevision: nil, at: .now).memory
        #expect(throws: MiraError.self) { _ = try store.confirmMemoryReplacement(candidate.id, workspaceID: nil, replacingCurrent: current.id, expectedCandidateRevision: 99, expectedCurrentRevision: current.revision, at: .now) }
        #expect(throws: MiraError.self) { _ = try store.confirmMemoryReplacement(candidate.id, workspaceID: nil, replacingCurrent: unrelated.id, expectedCandidateRevision: candidate.revision, expectedCurrentRevision: unrelated.revision, at: .now) }
        let confirmed = try store.confirmMemoryReplacement(candidate.id, workspaceID: nil, replacingCurrent: current.id, expectedCandidateRevision: candidate.revision, expectedCurrentRevision: current.revision, at: .now)
        #expect(confirmed.state == .active)
        #expect(try store.memoryDetail(current.id, workspaceID: nil).memory.supersededBy == candidate.id)

        let rejectedCandidate = try store.createMemory(draft: .init(content: "Rejected competition", scope: .global), source: .manualEntry(id: UUID(), statement: "Rejected competition"), operationID: UUID(), replacing: old.id, expectedRevision: old.revision + 1, at: .now).memory
        _ = try store.changeMemoryState(rejectedCandidate.id, workspaceID: nil, state: .rejected, expectedRevision: rejectedCandidate.revision, at: .now)
        #expect(try store.memoryDetail(rejectedCandidate.id, workspaceID: nil).replacements.allSatisfy { $0.state == .rejected })
        let backup = directory.deletingLastPathComponent().appendingPathComponent("mira-replacements-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: backup) }
        try store.exportBackup(to: backup)
    }

    private func installFixture(in store: SQLiteMiraStore) throws -> ResolvedModelRouteSnapshot {
        let route = ResolvedModelRouteSnapshot(name: "Fixture", providerKind: .openAICompatible, baseURL: "https://example.invalid", modelID: "fixture", credentialReference: "fixture", contextWindow: 4096)
        try store.saveConnection(.init(id: route.connectionID, revision: route.connectionRevision, name: "Fixture connection", providerKind: route.providerKind, baseURL: route.baseURL, credentialReference: route.credentialReference, credentialVersion: route.credentialVersion), expectedRevision: nil)
        try store.saveModel(.init(id: route.modelDescriptorID, revision: route.modelRevision, connectionID: route.connectionID, connectionRevision: route.connectionRevision, modelID: route.modelID, contextWindow: route.contextWindow, textCapability: route.textCapability, toolCapability: route.toolCapability, probeObservation: route.probeObservation), expectedRevision: nil)
        try store.saveRoute(.init(id: route.id, revision: route.revision, name: route.name, modelDescriptorID: route.modelDescriptorID, maxOutputTokens: route.maxOutputTokens, requestsUsage: route.requestsUsage), expectedRevision: nil)
        return route
    }

    private func testDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mira-memory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }
}
