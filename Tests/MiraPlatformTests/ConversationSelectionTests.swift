import Foundation
import Testing
import MiraCore
import MiraData

@Suite("Conversation selection loading")
@MainActor
struct ConversationSelectionTests {
    @Test func providerToggleRefreshesRoutesWithoutReloadingCachedHistory() async throws {
        let fixture = try SelectionFixture()
        defer { fixture.cleanup() }
        _ = try fixture.installConversationRoute()
        let first = try await fixture.application.createConversation(workspaceID: nil)
        let second = try await fixture.application.createConversation(workspaceID: nil)
        let model = ConversationModel(application: fixture.application)
        await model.reload()
        await model.selectConversation(first)
        let firstPage = model.activePage
        await model.selectConversation(second)
        let secondPage = model.activePage
        firstPage.composer = "Retained synthetic draft"
        let loads = model.snapshotLoadCount
        var connection = try #require(model.configuration.connections.first)
        connection.isEnabled = false
        connection.revision += 1
        try await fixture.application.saveConnection(connection, expectedRevision: connection.revision - 1)

        model.receive(.configurationChanged)
        for _ in 0..<100 {
            if model.configuration.connections.first?.isEnabled == false { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(model.configuration.connections.first?.isEnabled == false)
        #expect(model.routes.isEmpty)
        #expect(model.snapshotLoadCount == loads)
        #expect(firstPage.loadTask == nil && secondPage.loadTask == nil)
        #expect(firstPage.composer == "Retained synthetic draft")
        #expect(model.activePage === secondPage)
        await fixture.application.shutdown()
    }

    @Test func repeatedSelectionPreservesComposerAndCurrentSnapshot() async throws {
        let fixture = try SelectionFixture()
        defer { fixture.cleanup() }
        let conversationID = try await fixture.application.createConversation(workspaceID: nil)
        let model = ConversationModel(application: fixture.application)
        await model.reload()
        await model.selectConversation(conversationID)
        let inspectionRevision = model.activePage.inspectionRevision
        await model.reload()
        #expect(model.activePage.inspectionRevision == inspectionRevision)

        let executionID = ExecutionID()
        let route = ResolvedModelRouteSnapshot(
            name: "Synthetic", providerKind: .openAICompatible, baseURL: "https://fixture.invalid/v1",
            modelID: "fixture", credentialReference: "fixture", contextWindow: 32_768
        )
        let message = Message(
            id: MessageID(), conversationID: conversationID, executionID: executionID, sequence: 1,
            role: .user, status: .committed, text: "Synthetic current message", createdAt: Date()
        )
        model.activePage.messages = [message]
        model.activePage.executions = [Execution(
            id: executionID, conversationID: conversationID, triggerMessageID: message.id,
            status: .waitingForModel, route: route, createdAt: Date(), updatedAt: Date()
        )]
        model.activePage.streamBuffer.replace(drafts: [executionID: "partial"], thinkingTraces: [:])
        model.activePage.pendingSaveIDs = [executionID]
        model.activePage.composer = "Unsent draft"
        model.activePage.streamBuffer.receiveDraft("latest partial", for: executionID)

        await model.selectConversation(conversationID)

        #expect(model.activePage.composer == "Unsent draft")
        #expect(model.activePage.messages == [message])
        #expect(model.activePage.executions.count == 1)
        #expect(model.activePage.pendingSaveIDs == [executionID])
        #expect(model.activePage.streamBuffer.drafts[executionID] == "partial")
        try await Task.sleep(for: .milliseconds(140))
        #expect(model.activePage.streamBuffer.drafts[executionID] == "latest partial")
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
        model.activePage.streamBuffer.receiveDraft("stale queued output", for: staleExecutionID)
        #expect(model.activePage.streamBuffer.drafts.isEmpty)

        // The database snapshot is still empty. The accepted reload must cancel the
        // queued draft even though the observable model fields do not change.
        await model.reload()
        try await Task.sleep(for: .milliseconds(140))

        #expect(model.activePage.streamBuffer.drafts.isEmpty)
        #expect(model.activePage.streamBuffer.thinkingTraces.isEmpty)
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
        model.activePage.composer = "First conversation draft"
        let executionID = ExecutionID()
        let route = ResolvedModelRouteSnapshot(
            name: "Synthetic", providerKind: .openAICompatible, baseURL: "https://fixture.invalid/v1",
            modelID: "fixture", credentialReference: "fixture", contextWindow: 32_768
        )
        let message = Message(
            id: MessageID(), conversationID: firstID, executionID: executionID, sequence: 1,
            role: .user, status: .committed, text: "First conversation message", createdAt: Date()
        )
        model.activePage.messages = [message]
        model.activePage.executions = [Execution(
            id: executionID, conversationID: firstID, triggerMessageID: message.id,
            status: .waitingForModel, route: route, createdAt: Date(), updatedAt: Date()
        )]
        model.activePage.streamBuffer.replace(drafts: [executionID: "first partial"], thinkingTraces: [:])

        await model.selectConversation(secondID)

        #expect(model.selectedConversationID == secondID)
        #expect(!model.activePage.isLoading)
        #expect(model.activePage.composer.isEmpty)
        #expect(model.activePage.messages.isEmpty)
        #expect(model.activePage.executions.isEmpty)
        #expect(model.activePage.pendingSaveIDs.isEmpty)
        #expect(model.activePage.streamBuffer.drafts.isEmpty)
        #expect(model.activePage.streamBuffer.thinkingTraces.isEmpty)
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
        #expect(model.activePage.messages.isEmpty)
        #expect(model.activePage.executions.isEmpty)
        #expect(model.activePage.streamBuffer.drafts.isEmpty)
        await fixture.application.shutdown()
    }
    @Test func revisitingAConversationReusesItsPageAndPreservesTransientState() async throws {
        let fixture = try SelectionFixture()
        defer { fixture.cleanup() }
        let firstID = try await fixture.application.createConversation(workspaceID: nil)
        let secondID = try await fixture.application.createConversation(workspaceID: nil)
        let model = ConversationModel(application: fixture.application)
        await model.reload()

        await model.selectConversation(firstID)
        let firstPage = model.activePage
        let routeID = RouteID()
        let executionID = ExecutionID()
        firstPage.composer = "Keep this draft"
        firstPage.selectedRouteID = routeID
        firstPage.readingState.recordOffset(432)
        firstPage.messages = [syntheticMessage(conversationID: firstID, executionID: executionID)]
        firstPage.streamBuffer.replace(drafts: [executionID: "partial"], thinkingTraces: [:])
        await model.selectConversation(secondID)
        let loadsBeforeReturn = model.snapshotLoadCount
        await model.selectConversation(firstID)

        #expect(model.activePage === firstPage)
        #expect(model.snapshotLoadCount == loadsBeforeReturn)
        #expect(firstPage.composer == "Keep this draft")
        #expect(firstPage.selectedRouteID == routeID)
        #expect(firstPage.readingState.visibleOffset == 432)
        #expect(firstPage.messages.count == 1)
        #expect(firstPage.streamBuffer.drafts[executionID] == "partial")
        await fixture.application.shutdown()
    }

    @Test func pageLimitEvictsOnlyContentAndReloadsAnEvictedConversation() async throws {
        let fixture = try SelectionFixture()
        defer { fixture.cleanup() }
        let firstID = try await fixture.application.createConversation(workspaceID: nil)
        let secondID = try await fixture.application.createConversation(workspaceID: nil)
        let thirdID = try await fixture.application.createConversation(workspaceID: nil)
        let model = ConversationModel(application: fixture.application, pageLimit: 2)
        await model.reload()

        await model.selectConversation(firstID)
        let firstPage = model.activePage
        let executionID = ExecutionID()
        firstPage.composer = "Retained draft"
        firstPage.selectedRouteID = RouteID()
        firstPage.readingState.recordOffset(721)
        firstPage.messages = [syntheticMessage(conversationID: firstID, executionID: executionID)]
        firstPage.executions = [syntheticExecution(conversationID: firstID, executionID: executionID)]
        firstPage.streamBuffer.replace(drafts: [executionID: "evicted stream"], thinkingTraces: [:])

        await model.selectConversation(secondID)
        await model.selectConversation(thirdID)
        #expect(!model.retainedPages.contains(where: { $0 === firstPage }))
        #expect(firstPage.messages.isEmpty)
        #expect(firstPage.executions.isEmpty)
        #expect(firstPage.streamBuffer.drafts.isEmpty)
        #expect(firstPage.composer == "Retained draft")
        #expect(firstPage.selectedRouteID != nil)
        #expect(firstPage.readingState.visibleOffset == 721)

        let loadsBeforeReturn = model.snapshotLoadCount
        await model.selectConversation(firstID)
        #expect(model.activePage === firstPage)
        #expect(model.snapshotLoadCount == loadsBeforeReturn + 1)
        #expect(firstPage.composer == "Retained draft")
        #expect(firstPage.readingState.visibleOffset == 721)
        await fixture.application.shutdown()
    }

    @Test func repeatedNewConversationKeepsOneDraftPageAcrossHistoryNavigation() async throws {
        let fixture = try SelectionFixture()
        defer { fixture.cleanup() }
        let historyID = try await fixture.application.createConversation(workspaceID: nil)
        let model = ConversationModel(application: fixture.application)
        await model.reload()
        await model.selectConversation(historyID)

        await model.newConversation()
        let draftPage = model.activePage
        draftPage.composer = "Draft across history"
        await model.newConversation()
        #expect(model.activePage === draftPage)
        #expect(model.retainedPages.filter { $0.conversationID == nil }.count == 1)

        await model.selectConversation(historyID)
        await model.newConversation()
        #expect(model.activePage === draftPage)
        #expect(model.activePage.composer == "Draft across history")
        #expect(model.selectedConversationID == nil)
        #expect(try fixture.store.conversations(includeArchived: true).map(\.id) == [historyID])
        await fixture.application.shutdown()
    }

    @Test func firstSendWithoutAConfiguredRouteKeepsTheDraftWithoutCreatingAConversation() async throws {
        let fixture = try SelectionFixture()
        defer { fixture.cleanup() }
        let model = ConversationModel(application: fixture.application)
        await model.reload()
        model.activePage.composer = "Retry when configured"

        await model.send()
        await model.send()

        #expect(model.selectedConversationID == nil)
        #expect(model.activePage.composer == "Retry when configured")
        #expect(model.error != nil)
        #expect(try fixture.store.conversations(includeArchived: true).isEmpty)
        await fixture.application.shutdown()
    }

    @Test func firstSendPromotesTheDraftPageInPlaceAndNewKeepsOneDraftPage() async throws {
        let fixture = try SelectionFixture()
        defer { fixture.cleanup() }
        let route = try fixture.installConversationRoute()
        let model = ConversationModel(application: fixture.application)
        await model.reload()
        model.activePage.selectedRouteID = route.id
        model.activePage.composer = "First offline message"
        let draftPage = model.activePage
        let pageID = draftPage.id

        await model.send()

        #expect(model.activePage === draftPage)
        #expect(draftPage.id == pageID)
        #expect(draftPage.conversationID != nil)
        #expect(draftPage.composer.isEmpty)
        let conversations = try fixture.store.conversations(includeArchived: true)
        #expect(conversations.count == 1)
        let conversationID = try #require(draftPage.conversationID)
        #expect(conversations.map(\.id) == [conversationID])
        #expect(try fixture.store.messages(in: conversationID).filter { $0.role == .user }.map(\.text) == ["First offline message"])
        #expect(try fixture.store.executions(in: conversationID).count == 1)

        await model.newConversation()
        let newDraftPage = model.activePage
        await model.newConversation()

        #expect(model.activePage === newDraftPage)
        #expect(model.retainedPages.filter { $0.conversationID == nil }.count == 1)
        #expect(try fixture.store.conversations(includeArchived: true).map(\.id) == [conversationID])
        await fixture.application.shutdown()
    }

    @Test func contentInvalidationClearsVisibleAndHiddenPageContentSynchronously() async throws {
        let fixture = try SelectionFixture()
        defer { fixture.cleanup() }
        let firstID = try await fixture.application.createConversation(workspaceID: nil)
        let secondID = try await fixture.application.createConversation(workspaceID: nil)
        let model = ConversationModel(application: fixture.application)
        await model.reload()
        await model.selectConversation(firstID)
        let firstPage = model.activePage
        await model.selectConversation(secondID)
        let secondPage = model.activePage

        let firstExecutionID = ExecutionID()
        let secondExecutionID = ExecutionID()
        firstPage.messages = [syntheticMessage(conversationID: firstID, executionID: firstExecutionID)]
        firstPage.executions = [syntheticExecution(conversationID: firstID, executionID: firstExecutionID)]
        firstPage.pendingSaveIDs = [firstExecutionID]
        firstPage.streamBuffer.receiveDraft("pending hidden stream", for: firstExecutionID)
        secondPage.messages = [syntheticMessage(conversationID: secondID, executionID: secondExecutionID)]
        secondPage.executions = [syntheticExecution(conversationID: secondID, executionID: secondExecutionID)]
        secondPage.pendingSaveIDs = [secondExecutionID]
        secondPage.streamBuffer.replace(drafts: [secondExecutionID: "visible stream"], thinkingTraces: [:])

        model.receive(.conversationContentInvalidated)
        firstPage.streamBuffer.flush()
        for page in [firstPage, secondPage] {
            #expect(page.messages.isEmpty)
            #expect(page.executions.isEmpty)
            #expect(page.pendingSaveIDs.isEmpty)
            #expect(page.streamBuffer.drafts.isEmpty)
            #expect(page.streamBuffer.thinkingTraces.isEmpty)
        }
        for page in [firstPage, secondPage] { await page.loadTask?.value }

        for page in [firstPage, secondPage] {
            #expect(page.messages.isEmpty)
            #expect(page.executions.isEmpty)
            #expect(page.pendingSaveIDs.isEmpty)
            #expect(page.streamBuffer.drafts.isEmpty)
            #expect(page.streamBuffer.thinkingTraces.isEmpty)
        }
        await fixture.application.shutdown()
    }

    @Test func conversationChangedRefreshesOnlyTheNamedPage() async throws {
        let fixture = try SelectionFixture()
        defer { fixture.cleanup() }
        let firstID = try await fixture.application.createConversation(workspaceID: nil)
        let secondID = try await fixture.application.createConversation(workspaceID: nil)
        let model = ConversationModel(application: fixture.application)
        await model.reload()
        await model.selectConversation(firstID)
        let firstPage = model.activePage
        await model.selectConversation(secondID)
        let secondPage = model.activePage
        let secondMessage = syntheticMessage(conversationID: secondID, executionID: ExecutionID())
        secondPage.messages = [secondMessage]
        let secondRevision = secondPage.inspectionRevision
        let loadsBeforeChange = model.snapshotLoadCount

        model.receive(.conversationChanged(firstID))
        await firstPage.loadTask?.value

        #expect(model.activePage === secondPage)
        #expect(model.snapshotLoadCount == loadsBeforeChange + 1)
        #expect(secondPage.messages == [secondMessage])
        #expect(secondPage.inspectionRevision == secondRevision)
        let failure = MiraError(.storage, "Synthetic background save failure")
        model.receive(.conversationFailure(firstID, failure))
        #expect(firstPage.error == failure)
        #expect(secondPage.error == nil)
        #expect(model.error == nil)
        await fixture.application.shutdown()
    }
}

private func syntheticMessage(conversationID: ConversationID, executionID: ExecutionID) -> Message {
    Message(id: MessageID(), conversationID: conversationID, executionID: executionID, sequence: 1,
            role: .user, status: .committed, text: "Synthetic message", createdAt: Date())
}

private func syntheticExecution(conversationID: ConversationID, executionID: ExecutionID) -> Execution {
    let message = MessageID()
    let route = ResolvedModelRouteSnapshot(name: "Synthetic", providerKind: .openAICompatible,
                                           baseURL: "https://fixture.invalid/v1", modelID: "fixture",
                                           credentialReference: "fixture", contextWindow: 32_768)
    return Execution(id: executionID, conversationID: conversationID, triggerMessageID: message,
                     status: .waitingForModel, route: route, createdAt: Date(), updatedAt: Date())
}

private struct SelectionFixture {
    let directory: URL
    let store: SQLiteMiraStore
    let application: MiraApplication

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MiraConversationSelectionTests-\(UUID().uuidString)", isDirectory: true)
        store = try SQLiteMiraStore(directory: directory)
        application = try MiraApplication(store: store, provider: NoNetworkProvider())
    }

    func installConversationRoute() throws -> ModelRoute {
        let connection = ProviderConnection(name: "Offline fixture", providerKind: .openAICompatible,
                                             baseURL: "https://fixture.invalid/v1", credentialReference: "fixture")
        let model = ModelDescriptor(connectionID: connection.id, modelID: "fixture", contextWindow: 32_768,
                                    textCapability: .declared)
        let route = ModelRoute(id: model.poolRouteID, name: "Offline fixture route", modelDescriptorID: model.id)
        try store.saveConnection(connection, expectedRevision: nil)
        try store.saveModel(model, expectedRevision: nil)
        try store.saveRoute(route, expectedRevision: nil)
        try store.saveRouteBinding(.init(scope: .global, purpose: .conversation, routeID: route.id), expectedRevision: nil)
        return route
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
