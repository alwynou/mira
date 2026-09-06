import Foundation
import MiraCore
import MiraData
import Testing

@Suite("Memory history lifecycle status")
struct MemoryHistoryStatusTests {
    @Test func noticesReportUpdatedSupersededArchivedExpiredAndUnavailablePolicies() throws {
        let fixture = try MemoryHistoryStatusFixture()
        defer { fixture.cleanup() }
        let now = Date(timeIntervalSince1970: 1_000)
        let sharedConversation = try fixture.conversation()

        let updatedExecution = try fixture.execution(text: "Updated memory", conversationID: sharedConversation.id)
        let updated = try fixture.memory("Updated memory")
        try fixture.store.recordMemoryUsage([.init(memoryID: updated.id, revision: updated.revision)], executionID: updatedExecution.id, at: now)
        var revisedDraft = try #require(updated.draft)
        revisedDraft.content = "Updated memory revision"
        let revised = try fixture.store.reviseMemory(updated.id, workspaceID: nil, draft: revisedDraft, expectedRevision: updated.revision, at: now.addingTimeInterval(1))
        #expect(revised.revision == 2)
        try fixture.complete(updatedExecution, at: now.addingTimeInterval(2))

        let supersededExecution = try fixture.execution(text: "Superseded memory", conversationID: sharedConversation.id)
        let superseded = try fixture.memory("Superseded memory")
        try fixture.store.recordMemoryUsage([.init(memoryID: superseded.id, revision: superseded.revision)], executionID: supersededExecution.id, at: now)
        let successor = try fixture.store.createMemory(
            draft: .init(content: "Successor memory", scope: .global),
            source: .manualEntry(id: UUID(), statement: "Successor memory"), operationID: UUID(),
            replacing: superseded.id, expectedRevision: superseded.revision, at: now.addingTimeInterval(2)
        ).memory
        #expect(successor.state == .active)
        #expect(try fixture.store.memoryDetail(superseded.id, workspaceID: nil).memory.supersededBy == successor.id)
        try fixture.complete(supersededExecution, at: now.addingTimeInterval(3))

        let archivedExecution = try fixture.execution(text: "Archived memory", conversationID: sharedConversation.id)
        let archived = try fixture.memory("Archived memory")
        try fixture.store.recordMemoryUsage([.init(memoryID: archived.id, revision: archived.revision)], executionID: archivedExecution.id, at: now)
        _ = try fixture.store.changeMemoryState(archived.id, workspaceID: nil, state: .archived, expectedRevision: archived.revision, at: now.addingTimeInterval(3))
        try fixture.complete(archivedExecution, at: now.addingTimeInterval(4))

        let expiredExecution = try fixture.execution(text: "Expired memory", conversationID: sharedConversation.id)
        let expired = try fixture.store.createMemory(
            draft: .init(content: "Expired memory", scope: .global, validUntil: now.addingTimeInterval(10)),
            source: .manualEntry(id: UUID(), statement: "Expired memory"), operationID: UUID(), replacing: nil, expectedRevision: nil, at: now
        ).memory
        try fixture.store.recordMemoryUsage([.init(memoryID: expired.id, revision: expired.revision)], executionID: expiredExecution.id, at: now)
        try fixture.complete(expiredExecution, at: now.addingTimeInterval(5))

        let policyWorkspace = Workspace(id: .init(), name: "Policy workspace", allowsRemoteSend: true)
        try fixture.store.saveWorkspace(policyWorkspace, expectedRevision: nil)
        let policyExecution = try fixture.execution(text: "Policy memory", workspaceID: policyWorkspace.id)
        let policySource = try #require(try fixture.store.messages(in: policyExecution.conversationID).first { $0.role == .user })
        let policyMemory = try fixture.store.createMemory(
            draft: .init(content: "Policy memory", scope: .global),
            source: .message(id: policySource.id, excerpt: policySource.text), operationID: UUID(), replacing: nil, expectedRevision: nil, at: now
        ).memory
        try fixture.store.recordMemoryUsage([.init(memoryID: policyMemory.id, revision: policyMemory.revision)], executionID: policyExecution.id, at: now)
        let disabledWorkspace = Workspace(id: policyWorkspace.id, name: policyWorkspace.name, allowsRemoteSend: false, revision: policyWorkspace.revision + 1)
        try fixture.store.saveWorkspace(disabledWorkspace, expectedRevision: policyWorkspace.revision)

        let notices = try fixture.store.memoryContextNotices(in: updatedExecution.conversationID, at: now.addingTimeInterval(20))
        #expect(notices[updatedExecution.id] == [.init(memoryID: updated.id, reason: .updated)])
        #expect(notices[supersededExecution.id] == [.init(memoryID: superseded.id, reason: .superseded)])
        #expect(notices[archivedExecution.id] == [.init(memoryID: archived.id, reason: .archived)])
        #expect(notices[expiredExecution.id] == [.init(memoryID: expired.id, reason: .expired)])
        #expect(notices[policyExecution.id] == nil)

        let policyNotices = try fixture.store.memoryContextNotices(in: policyExecution.conversationID, at: now)
        #expect(policyNotices[policyExecution.id] == [.init(memoryID: policyMemory.id, reason: .unavailable)])

        let activeIDs = Set(try fixture.store.memoryList(workspaceID: nil, states: [.active], query: "", limit: 100).memories.map(\.id))
        #expect(activeIDs.contains(successor.id))
        #expect(!activeIDs.contains(superseded.id))
        #expect(!activeIDs.contains(expired.id))
        #expect(!activeIDs.contains(archived.id))
    }

    @Test func noticesAreLimitedToExecutionsInTheRequestedConversation() throws {
        let fixture = try MemoryHistoryStatusFixture()
        defer { fixture.cleanup() }
        let now = Date(timeIntervalSince1970: 1_000)
        let conversationExecution = try fixture.execution(text: "Relevant conversation")
        let otherExecution = try fixture.execution(text: "Other conversation")
        let memory = try fixture.memory("Relevant conversation")
        try fixture.store.recordMemoryUsage([.init(memoryID: memory.id, revision: memory.revision)], executionID: conversationExecution.id, at: now)
        _ = try fixture.store.changeMemoryState(memory.id, workspaceID: nil, state: .archived, expectedRevision: memory.revision, at: now.addingTimeInterval(1))

        let relevant = try fixture.store.memoryContextNotices(in: conversationExecution.conversationID, at: now)
        #expect(relevant[conversationExecution.id] == [.init(memoryID: memory.id, reason: .archived)])
        #expect(relevant[otherExecution.id] == nil)
        #expect(try fixture.store.memoryContextNotices(in: otherExecution.conversationID, at: now).isEmpty)
    }
}

private struct MemoryHistoryStatusFixture {
    let directory: URL
    let store: SQLiteMiraStore
    let route: ResolvedModelRouteSnapshot

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("mira-memory-history-status-" + UUID().uuidString)
        store = try SQLiteMiraStore(directory: directory)
        route = .init(name: "Fixture", providerKind: .openAICompatible, baseURL: "https://example.invalid", modelID: "fixture", credentialReference: "fixture", contextWindow: 65_536)
        try store.saveConnection(.init(id: route.connectionID, revision: route.connectionRevision, name: "Fixture connection", providerKind: route.providerKind, baseURL: route.baseURL, credentialReference: route.credentialReference), expectedRevision: nil)
        try store.saveModel(.init(id: route.modelDescriptorID, revision: route.modelRevision, connectionID: route.connectionID, connectionRevision: route.connectionRevision, modelID: route.modelID, contextWindow: route.contextWindow, textCapability: route.textCapability, toolCapability: route.toolCapability), expectedRevision: nil)
        try store.saveRoute(.init(id: route.id, revision: route.revision, name: route.name, modelDescriptorID: route.modelDescriptorID, maxOutputTokens: route.maxOutputTokens, requestsUsage: route.requestsUsage), expectedRevision: nil)
    }

    func conversation(workspaceID: WorkspaceID? = nil) throws -> Conversation {
        let conversation = Conversation(id: .init(), workspaceID: workspaceID, title: "Fixture", createdAt: .now, updatedAt: .now)
        try store.createConversation(conversation)
        return conversation
    }

    func execution(text: String, workspaceID: WorkspaceID? = nil) throws -> Execution {
        let conversation = try conversation(workspaceID: workspaceID)
        return try execution(text: text, conversationID: conversation.id)
    }

    func execution(text: String, conversationID: ConversationID) throws -> Execution {
        guard let conversation = try store.conversations(includeArchived: true).first(where: { $0.id == conversationID }) else {
            throw MiraError(.notFound, "The fixture conversation does not exist.")
        }
        let workspace = try conversation.workspaceID.flatMap { workspaceID in
            try store.workspaces().first { $0.id == workspaceID }
        }
        let resolved = try store.modelConfiguration().resolve(purpose: .conversation, explicitRouteID: route.id, conversation: conversation, workspace: workspace)
        return try store.enqueue(conversationID: conversation.id, text: text, route: resolved, executionID: .init(), messageID: .init(), at: .now)
    }

    func complete(_ execution: Execution, at: Date) throws {
        _ = try store.finish(executionID: execution.id, status: .completed, text: "Synthetic reply", usage: .init(), error: nil, assistantMessageID: .init(), at: at)
    }

    func memory(_ content: String) throws -> Memory {
        try store.createMemory(draft: .init(content: content, scope: .global), source: .manualEntry(id: UUID(), statement: content), operationID: UUID(), replacing: nil, expectedRevision: nil, at: Date(timeIntervalSince1970: 1_000)).memory
    }

    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}
