import Foundation
import Testing
import MiraCore
import MiraData

@Suite("Conversation selection loading")
@MainActor
struct ConversationSelectionTests {
    @Test func repeatedSelectionPreservesComposerAndCurrentSnapshot() async throws {
        let fixture = try SelectionFixture()
        defer { fixture.cleanup() }
        let conversationID = try await fixture.application.createConversation(workspaceID: nil)
        let model = ConversationModel(application: fixture.application)
        await model.reload()
        await model.selectConversation(conversationID)
        let inspectionRevision = model.inspectionRevision
        await model.reload()
        #expect(model.inspectionRevision == inspectionRevision)

        let executionID = ExecutionID()
        let route = ResolvedModelRouteSnapshot(
            name: "Synthetic", providerKind: .openAICompatible, baseURL: "https://fixture.invalid/v1",
            modelID: "fixture", credentialReference: "fixture", contextWindow: 32_768
        )
        let message = Message(
            id: MessageID(), conversationID: conversationID, executionID: executionID, sequence: 1,
            role: .user, status: .committed, text: "Synthetic current message", createdAt: Date()
        )
        model.messages = [message]
        model.executions = [Execution(
            id: executionID, conversationID: conversationID, triggerMessageID: message.id,
            status: .waitingForModel, route: route, createdAt: Date(), updatedAt: Date()
        )]
        model.streamBuffer.replace(drafts: [executionID: "partial"], thinkingTraces: [:])
        model.pendingSaveIDs = [executionID]
        model.composer = "Unsent draft"
        model.streamBuffer.receiveDraft("latest partial", for: executionID)

        await model.selectConversation(conversationID)

        #expect(model.composer == "Unsent draft")
        #expect(model.messages == [message])
        #expect(model.executions.count == 1)
        #expect(model.pendingSaveIDs == [executionID])
        #expect(model.streamBuffer.drafts[executionID] == "partial")
        try await Task.sleep(for: .milliseconds(140))
        #expect(model.streamBuffer.drafts[executionID] == "latest partial")
        await fixture.application.shutdown()
    }

    @Test func identicalAuthoritativeReloadCancelsQueuedStaleDraft() async throws {
        let fixture = try SelectionFixture()
        defer { fixture.cleanup() }
        let conversationID = try await fixture.application.createConversation(workspaceID: nil)
        let model = ConversationModel(application: fixture.application)
        await model.reload()
        await model.selectConversation(conversationID)

        let staleExecutionID = ExecutionID()
        model.streamBuffer.receiveDraft("stale queued output", for: staleExecutionID)
        #expect(model.streamBuffer.drafts.isEmpty)

        // The database snapshot is still empty. The accepted reload must cancel the
        // queued draft even though the observable model fields do not change.
        await model.reload()
        try await Task.sleep(for: .milliseconds(140))

        #expect(model.streamBuffer.drafts.isEmpty)
        #expect(model.streamBuffer.thinkingTraces.isEmpty)
        await fixture.application.shutdown()
    }

    @Test func switchingConversationClearsCurrentDraftAndLoadsTheNewSnapshot() async throws {
        let fixture = try SelectionFixture()
        defer { fixture.cleanup() }
        let firstID = try await fixture.application.createConversation(workspaceID: nil)
        let secondID = try await fixture.application.createConversation(workspaceID: nil)
        let model = ConversationModel(application: fixture.application)
        await model.reload()
        await model.selectConversation(firstID)
        model.composer = "First conversation draft"
        let executionID = ExecutionID()
        let route = ResolvedModelRouteSnapshot(
            name: "Synthetic", providerKind: .openAICompatible, baseURL: "https://fixture.invalid/v1",
            modelID: "fixture", credentialReference: "fixture", contextWindow: 32_768
        )
        let message = Message(
            id: MessageID(), conversationID: firstID, executionID: executionID, sequence: 1,
            role: .user, status: .committed, text: "First conversation message", createdAt: Date()
        )
        model.messages = [message]
        model.executions = [Execution(
            id: executionID, conversationID: firstID, triggerMessageID: message.id,
            status: .waitingForModel, route: route, createdAt: Date(), updatedAt: Date()
        )]
        model.streamBuffer.replace(drafts: [executionID: "first partial"], thinkingTraces: [:])

        await model.selectConversation(secondID)

        #expect(model.selectedConversationID == secondID)
        #expect(!model.isLoadingConversation)
        #expect(model.composer.isEmpty)
        #expect(model.messages.isEmpty)
        #expect(model.executions.isEmpty)
        #expect(model.pendingSaveIDs.isEmpty)
        #expect(model.streamBuffer.drafts.isEmpty)
        #expect(model.streamBuffer.thinkingTraces.isEmpty)
        await fixture.application.shutdown()
    }

    @Test func concurrentLateRefreshCannotReplaceTheCurrentConversation() async throws {
        let fixture = try SelectionFixture()
        defer { fixture.cleanup() }
        let firstID = try await fixture.application.createConversation(workspaceID: nil)
        let secondID = try await fixture.application.createConversation(workspaceID: nil)
        let model = ConversationModel(application: fixture.application)
        await model.reload()

        let firstSelection = Task { await model.selectConversation(firstID) }
        while model.selectedConversationID != firstID { await Task.yield() }
        let refresh = Task { await model.reload() }
        await Task.yield()
        let secondSelection = Task { await model.selectConversation(secondID) }
        await firstSelection.value
        await refresh.value
        await secondSelection.value

        #expect(model.selectedConversationID == secondID)
        #expect(model.messages.isEmpty)
        #expect(model.executions.isEmpty)
        #expect(model.streamBuffer.drafts.isEmpty)
        await fixture.application.shutdown()
    }
}

private struct SelectionFixture {
    let directory: URL
    let application: MiraApplication

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MiraConversationSelectionTests-\(UUID().uuidString)", isDirectory: true)
        let store = try SQLiteMiraStore(directory: directory)
        application = try MiraApplication(store: store, provider: NoNetworkProvider())
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private struct NoNetworkProvider: ModelProviderPort {
    func stream(request: CanonicalModelRequest, route: ResolvedModelRouteSnapshot) -> AsyncThrowingStream<CanonicalStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: MiraError(.network, "Synthetic provider must not be contacted."))
        }
    }
}
