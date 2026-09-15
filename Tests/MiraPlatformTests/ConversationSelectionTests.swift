import Foundation
import MiraCore
import MiraData
import MiraProviders
import Testing

@Suite("Conversation selection loading", .timeLimit(.minutes(1)))
@MainActor
struct ConversationSelectionTests {
    @Test
    func providerToggleRefreshesRoutesWithoutReloadingCachedHistory() async throws {
        try await withFixture { fixture in
            let route = try await fixture.installHTTPConversationRoute()
            let firstID = try await fixture.createSession(title: "First")
            let secondID = try await fixture.createSession(title: "Second")
            let model = ConversationModel(library: fixture.library)
            let observer = Task { @MainActor in await model.observe() }
            defer { observer.cancel() }

            try await eventually { model.isReady && !model.routes.isEmpty }
            await model.reload()
            await model.selectConversation(firstID)
            let firstPage = model.activePage
            firstPage.composer = "Retained synthetic draft"
            firstPage.readingState.recordOffset(246)
            await model.selectConversation(secondID)
            let secondPage = model.activePage
            secondPage.composer = "Current draft"
            secondPage.readingState.recordOffset(135)
            try await eventually {
                firstPage.loadTask == nil && secondPage.loadTask == nil
                    && !firstPage.isLoading && !secondPage.isLoading
            }
            await model.reload()
            try await eventually {
                firstPage.loadTask == nil && secondPage.loadTask == nil
                    && !firstPage.isLoading && !secondPage.isLoading
            }
            let loads = model.snapshotLoadCount
            let firstMessages = firstPage.messages
            let secondMessages = secondPage.messages

            let group = try await fixture.library.workloads()
            let connection = try #require(await group.modelSettings.connection(id: route.connectionID))
            _ = try await group.credentialSettings.saveConnection(
                id: connection.id, name: connection.name, isEnabled: false,
                definitionID: connection.definitionID, endpoints: connection.endpoints,
                discovery: connection.discovery, defaultInvocation: connection.defaultInvocation,
                previous: connection, credentialEndpointID: connection.endpoints[0].id, credential: .keep)

            try await eventually { model.routes.isEmpty && model.snapshotLoadCount == loads }
            #expect(model.activePage === secondPage)
            #expect(model.activePage.composer == "Current draft")
            #expect(model.activePage.readingState.visibleOffset == 135)
            #expect(firstPage.composer == "Retained synthetic draft")
            #expect(firstPage.readingState.visibleOffset == 246)
            #expect(firstPage.messages == firstMessages)
            #expect(secondPage.messages == secondMessages)

            observer.cancel()
            await observer.value
        }
    }

    @Test
    func repeatedSelectionPreservesComposerAndCurrentSnapshot() async throws {
        try await withFixture { fixture in
            let conversationID = try await fixture.createSession(title: "Synthetic conversation")
            let model = ConversationModel(library: fixture.library)
            let observer = Task { @MainActor in await model.observe() }
            defer { observer.cancel() }

            try await eventually { model.isReady }
            await model.reload()
            await model.selectConversation(conversationID)
            let page = model.activePage
            page.composer = "Unsent draft"
            page.readingState.recordOffset(123)
            let inspectionRevision = page.inspectionRevision

            await model.reload()
            #expect(model.activePage === page)
            #expect(page.composer == "Unsent draft")
            #expect(page.readingState.visibleOffset == 123)
            #expect(page.inspectionRevision > inspectionRevision)

            observer.cancel()
            await observer.value
        }
    }

    @Test
    func switchingConversationClearsCurrentDraftAndLoadsTheNewSnapshot() async throws {
        try await withFixture { fixture in
            let firstID = try await fixture.createSession(title: "First")
            let secondID = try await fixture.createSession(title: "Second")
            let model = ConversationModel(library: fixture.library)
            let observer = Task { @MainActor in await model.observe() }
            defer { observer.cancel() }

            try await eventually { model.isReady }
            await model.reload()
            await model.selectConversation(firstID)
            let firstPage = model.activePage
            firstPage.composer = "First conversation draft"
            firstPage.readingState.recordOffset(321)
            let executionID = ExecutionID()
            firstPage.pendingSaveIDs = [executionID]
            firstPage.streamBuffer.receive(makeOutput(sessionID: firstID, executionID: executionID))
            firstPage.streamBuffer.flush()

            await model.selectConversation(secondID)

            #expect(model.selectedConversationID == secondID)
            #expect(model.activePage.composer.isEmpty)
            #expect(model.activePage.messages.isEmpty)
            #expect(model.activePage.executions.isEmpty)
            #expect(model.activePage.pendingSaveIDs.isEmpty)
            #expect(model.activePage.streamBuffer.observation?.cursor.sessionID == secondID)
            #expect(model.activePage.streamBuffer.observation?.value == nil)
            #expect(firstPage.composer == "First conversation draft")
            #expect(firstPage.readingState.visibleOffset == 321)

            observer.cancel()
            await observer.value
        }
    }

    @Test
    func concurrentLateRefreshCannotReplaceTheCurrentConversation() async throws {
        try await withFixture { fixture in
            let firstID = try await fixture.createSession(title: "First")
            let secondID = try await fixture.createSession(title: "Second")
            let model = ConversationModel(library: fixture.library)
            let observer = Task { @MainActor in await model.observe() }
            defer { observer.cancel() }

            try await eventually { model.isReady }
            await model.reload()

            let firstSelection = Task { @MainActor in await model.selectConversation(firstID) }
            while model.selectedConversationID != firstID { await Task.yield() }
            let refresh = Task { @MainActor in await model.reload() }
            await Task.yield()
            let secondSelection = Task { @MainActor in await model.selectConversation(secondID) }
            await firstSelection.value
            await refresh.value
            await secondSelection.value

            #expect(model.selectedConversationID == secondID)
            #expect(model.activePage.conversationID == secondID)
            #expect(model.activePage.messages.isEmpty)
            #expect(model.activePage.executions.isEmpty)
            #expect(model.activePage.streamBuffer.observation?.cursor.sessionID == secondID)
            #expect(model.activePage.streamBuffer.observation?.value == nil)

            observer.cancel()
            await observer.value
        }
    }

    @Test
    func revisitingAConversationReusesItsPageAndPreservesTransientState() async throws {
        try await withFixture { fixture in
            let firstID = try await fixture.createSession(title: "First")
            let secondID = try await fixture.createSession(title: "Second")
            let model = ConversationModel(library: fixture.library)
            let observer = Task { @MainActor in await model.observe() }
            defer { observer.cancel() }

            try await eventually { model.isReady }
            await model.reload()
            await model.selectConversation(firstID)
            let firstPage = model.activePage
            firstPage.composer = "Keep this draft"
            firstPage.selectedRouteID = RouteID()
            firstPage.readingState.recordOffset(432)
            let executionID = ExecutionID()
            firstPage.streamBuffer.receive(makeOutput(sessionID: firstID, executionID: executionID))
            firstPage.streamBuffer.flush()

            await model.selectConversation(secondID)
            let loadsBeforeReturn = model.snapshotLoadCount
            await model.selectConversation(firstID)

            #expect(model.activePage === firstPage)
            #expect(model.snapshotLoadCount == loadsBeforeReturn)
            #expect(firstPage.composer == "Keep this draft")
            #expect(firstPage.selectedRouteID != nil)
            #expect(firstPage.readingState.visibleOffset == 432)
            #expect(firstPage.streamBuffer.observation?.value?.answer == "Synthetic answer")

            observer.cancel()
            await observer.value
        }
    }

    @Test
    func pageLimitEvictsOnlyContentAndReloadsAnEvictedConversation() async throws {
        try await withFixture { fixture in
            let firstID = try await fixture.createSession(title: "First")
            let secondID = try await fixture.createSession(title: "Second")
            let thirdID = try await fixture.createSession(title: "Third")
            let model = ConversationModel(library: fixture.library, pageLimit: 2)
            let observer = Task { @MainActor in await model.observe() }
            defer { observer.cancel() }

            try await eventually { model.isReady }
            await model.reload()
            await model.selectConversation(firstID)
            let firstPage = model.activePage
            firstPage.composer = "Retained draft"
            firstPage.selectedRouteID = RouteID()
            firstPage.readingState.recordOffset(721)
            let executionID = ExecutionID()
            firstPage.pendingSaveIDs = [executionID]
            firstPage.streamBuffer.receive(makeOutput(sessionID: firstID, executionID: executionID))
            firstPage.streamBuffer.flush()
            firstPage.pendingSaveIDs = []

            await model.selectConversation(secondID)
            await model.selectConversation(thirdID)

            #expect(!model.retainedPages.contains(where: { $0 === firstPage }))
            #expect(firstPage.messages.isEmpty)
            #expect(firstPage.executions.isEmpty)
            #expect(firstPage.streamBuffer.observation == nil)
            #expect(firstPage.composer == "Retained draft")
            #expect(firstPage.selectedRouteID != nil)
            #expect(firstPage.readingState.visibleOffset == 721)

            await model.selectConversation(firstID)
            #expect(model.activePage === firstPage)
            #expect(firstPage.isLoaded)
            #expect(!firstPage.isLoading)
            #expect(firstPage.loadTask == nil)
            #expect(firstPage.session?.id == firstID)
            #expect(firstPage.composer == "Retained draft")
            #expect(firstPage.readingState.visibleOffset == 721)

            observer.cancel()
            await observer.value
        }
    }

    @Test
    func repeatedNewConversationKeepsOneDraftPageAcrossHistoryNavigation() async throws {
        try await withFixture { fixture in
            let historyID = try await fixture.createSession(title: "History")
            let model = ConversationModel(library: fixture.library)
            let observer = Task { @MainActor in await model.observe() }
            defer { observer.cancel() }

            try await eventually { model.isReady }
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
            #expect(model.conversations.map(\.id).contains(historyID))

            observer.cancel()
            await observer.value
        }
    }

    @Test
    func firstSendWithoutAConfiguredRouteKeepsTheDraftWithoutCreatingAConversation() async throws {
        try await withFixture { fixture in
            let model = ConversationModel(library: fixture.library)
            let observer = Task { @MainActor in await model.observe() }
            defer { observer.cancel() }

            try await eventually { model.isReady }
            await model.reload()
            model.activePage.composer = "Retry when configured"

            await model.send()
            await model.send()

            #expect(model.selectedConversationID == nil)
            #expect(model.activePage.composer == "Retry when configured")
            #expect(model.error != nil)
            #expect(model.conversations.isEmpty)

            observer.cancel()
            await observer.value
        }
    }

    @Test
    func libraryMaintenanceInvalidatesVisibleAndHiddenPageContentSynchronously() async throws {
        try await withFixture { fixture in
            let firstID = try await fixture.createSession(title: "First")
            let secondID = try await fixture.createSession(title: "Second")
            let model = ConversationModel(library: fixture.library)
            let observer = Task { @MainActor in await model.observe() }
            defer { observer.cancel() }

            try await eventually { model.isReady }
            await model.reload()
            await model.selectConversation(firstID)
            let firstPage = model.activePage
            await model.selectConversation(secondID)
            let secondPage = model.activePage

            for (page, sessionID) in [(firstPage, firstID), (secondPage, secondID)] {
                let executionID = ExecutionID()
                page.pendingSaveIDs = [executionID]
                page.streamBuffer.receive(makeOutput(sessionID: sessionID, executionID: executionID))
                page.streamBuffer.flush()
            }

            let archive = fixture.directory
                .deletingLastPathComponent()
                .appendingPathComponent("ConversationSelectionExport-\(UUID().uuidString)")
            _ = try await fixture.library.exportArchive(to: archive)
            try await eventually { !model.isReady }

            for page in [firstPage, secondPage] {
                #expect(page.messages.isEmpty)
                #expect(page.executions.isEmpty)
                #expect(page.pendingSaveIDs.isEmpty)
                #expect(page.streamBuffer.observation == nil)
            }

            observer.cancel()
            await observer.value
            try? FileManager.default.removeItem(at: archive)
        }
    }
}

private func makeOutput(sessionID: ConversationID, executionID: ExecutionID) -> SessionOutputObservation {
    .init(
        cursor: .init(sessionID: sessionID, sequence: 1), revision: 1,
        value: .init(
            executionID: executionID, attemptID: UUID(), stepID: UUID(),
            answer: "Synthetic answer", thinking: "Synthetic thinking"),
        isClosing: false)
}

private func withFixture<T: Sendable>(
    _ body: @MainActor (SelectionFixture) async throws -> T
) async throws -> T {
    let fixture = try await SelectionFixture()
    do {
        let result = try await body(fixture)
        await fixture.close()
        return result
    } catch {
        await fixture.close()
        throw error
    }
}

@MainActor
private func eventually(
    timeout: Duration = .seconds(15),
    _ predicate: @escaping () -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while !predicate() {
        if ContinuousClock.now >= deadline {
            throw MiraError(.busy, "The synthetic condition was not reached.")
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

private struct SelectionFixture: Sendable {
    let directory: URL
    let library: MacLibrary
    let credentials: SelectionCredentials

    init() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MiraConversationSelectionTests-\(UUID().uuidString)", isDirectory: true)
        let credentials = SelectionCredentials()
        self.directory = root
        self.credentials = credentials
        self.library = try await MacLibrary.open(
            directory: root,
            notifications: SelectionNotifications(),
            credentials: credentials,
            modules: { [MacHTTPModule(registry: $0, credentials: credentials)] })
    }

    func createSession(title: String) async throws -> ConversationID {
        let id = ConversationID()
        let workloads = try await library.workloads()
        let result = await workloads.application.createSession(
            id: id, commandID: UUID(), title: title, workspaceID: nil)
        guard case .committed = result else {
            throw MiraError(.storage, "The synthetic session could not be created.")
        }
        return id
    }

    func installHTTPConversationRoute() async throws -> HTTPRouteFixture {
        let group = try await library.workloads()
        let provider = try #require(ProviderModelCatalog.bundled.providers.first { $0.id == "openai" })
        let template = try provider.makeConnection(id: .init(), name: "HTTP fixture", credential: nil,
                                                   baseURL: "https://fixture.invalid/v1")
        let connection = try await group.credentialSettings.saveConnection(
            id: .init(), name: "HTTP fixture", isEnabled: true,
            definitionID: template.definitionID, endpoints: template.endpoints,
            discovery: template.discovery, defaultInvocation: template.defaultInvocation,
            previous: nil, credentialEndpointID: template.endpoints[0].id,
            credential: .replace("fixture-secret")).connection
        let configured = try ProviderModelCatalog.bundled.configuration(
            connection: connection, modelID: "gpt-4", displayName: "HTTP fixture route", isEnabled: true)
        // This private fixture endpoint has no official catalog association.
        let model = AgentConfiguredModel(
            id: configured.model.id, revision: configured.model.revision,
            authorizationRevision: configured.model.authorizationRevision,
            reference: configured.model.reference, displayName: configured.model.displayName,
            isEnabled: true, invocations: configured.model.invocations,
            facts: configured.model.facts + [.init(
                field: AgentModelMetadataField.contextWindow, value: .number(16_384),
                source: .user, sourceID: "tests.selection", sourceRevision: "1",
                observedAt: Date(), invocationID: configured.preset.invocationID)])
        let preset = configured.preset
        try await group.modelSettings.savePoolModel(
            model, preset: preset, expectedModelRevision: nil, expectedPresetRevision: nil)
        let existingBinding = try await group.modelSettings.bindings(scope: .global)
            .first(where: { $0.purpose == AgentModelPurposeID.conversation })
        try await group.modelSettings.saveBinding(
            .init(
                scope: .global, purpose: AgentModelPurposeID.conversation,
                routeID: preset.id, revision: (existingBinding?.revision ?? 0) + 1),
            expectedRevision: existingBinding?.revision)
        return .init(connectionID: connection.id, routeID: preset.id)
    }

    func close() async {
        _ = await library.close()
        try? FileManager.default.removeItem(at: directory)
    }
}

private struct SelectionNotifications: LocalNotificationPort, Sendable {
    func permission() async -> NotificationPermission { .denied }
    func requestPermission() async throws -> Bool { false }
    func pending() async -> [ReminderNotification] { [] }
    func install(_ notification: ReminderNotification) async throws {}
    func remove(_ identifier: String) async {}
}

private struct HTTPRouteFixture: Sendable {
    let connectionID: ConnectionID
    let routeID: RouteID
}

private final class SelectionCredentials: MacCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func read(reference: String, version: Int) throws -> String {
        guard let value = lock.withLock({ values["\(reference):\(version)"] }) else {
            throw MiraError(.credentialMissing, "Synthetic credentials are unavailable.")
        }
        return value
    }

    func save(_ secret: String, reference: String, version: Int) throws {
        lock.withLock { values["\(reference):\(version)"] = secret }
    }

    func delete(reference: String, version: Int) throws {
        lock.withLock { values["\(reference):\(version)"] = nil }
    }
}
