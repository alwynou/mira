#if DEBUG
    import Foundation
    import MiraCore
    import Testing

    @Suite("macOS conversation model", .timeLimit(.minutes(1)))
    @MainActor
    struct ConversationModelTests {
        @Test
        func memoryHistoryChangesRefreshRetainedPagesWithoutReloadingMessages() async throws {
            try await withDirectory { directory in
                let library = try await Self.openDemoLibrary(directory: directory, stress: false)
                let model = ConversationModel(library: library)
                let observer = Task { await model.observe() }
                do {
                    try await eventually { model.isReady && !model.routes.isEmpty }
                    let group = try #require(model.workgroup)
                    let memory = try await group.memories.createMemory(
                        draft: .init(content: "Synthetic jasmine tea preference", scope: .global),
                        source: .manualEntry(id: UUID(), statement: "Synthetic jasmine tea preference"),
                        operationID: UUID()).memory
                    let page = model.activePage
                    page.composer = "What is my synthetic jasmine tea preference?"
                    await model.send()
                    let sessionID = try #require(page.conversationID)
                    try await Self.waitForExecution(group, sessionID: sessionID)
                    await model.reload()
                    try await eventually {
                        page.loadTask == nil && page.noticeTask == nil && page.messages.contains { $0.summary.role == .assistant }
                    }
                    let reply = try #require(page.messages.last(where: { $0.summary.role == .assistant }))
                    let executionID = reply.summary.executionID
                    #expect(page.memoryNotices.isEmpty)
                    page.composer = "Draft remains while the memory changes."
                    page.readingState.recordOffset(123)
                    await model.newConversation()
                    let destination = model.activePage
                    destination.composer = "Independent draft"
                    let messages = page.messages
                    let loads = model.snapshotLoadCount
                    _ = try await group.memories.reviseMemory(memory.id, workspaceID: nil,
                        draft: .init(content: "Synthetic jasmine tea with clearer wording", scope: .global),
                        expectedRevision: 1, operationID: UUID())
                    try await eventually {
                        page.memoryNotices[executionID] == [.init(memoryID: memory.id, reason: .updated)]
                    }
                    #expect(model.snapshotLoadCount == loads)
                    #expect(page.messages == messages)
                    #expect(page.readingState.visibleOffset == 123)
                    #expect(page.composer == "Draft remains while the memory changes.")
                    #expect(model.activePage === destination && destination.memoryNotices.isEmpty)
                    #expect(page.transcriptItems.last(where: { $0.role == .assistant })?.memoryNotices
                        == [.init(memoryID: memory.id, reason: .updated)])
                    _ = try await group.memories.changeMemoryState(memory.id, workspaceID: nil, state: .archived,
                        expectedRevision: 2, operationID: UUID())
                    try await eventually {
                        page.memoryNotices[executionID] == [.init(memoryID: memory.id, reason: .archived)]
                    }
                    observer.cancel(); await observer.value
                    #expect(page.memoryNotices.isEmpty && page.noticeTask == nil)
                    #expect(await library.close().isSettled)
                } catch {
                    observer.cancel(); await observer.value; _ = await library.close(); throw error
                }
            }
        }

        @Test
        func genericApprovalUsesObservedRequestAndRejectsStaleProposal() async throws {
            try await withDirectory { directory in
                let library = try await Self.openDemoLibrary(directory: directory, stress: false)
                let model = ConversationModel(library: library)
                let observer = Task { await model.observe() }
                var pending: Task<RuntimeApprovalDecision, Error>?
                do {
                    try await eventually { model.isReady }
                    let group = try #require(model.workgroup)
                    let request = RuntimeApprovalRequest(
                        invocationID: UUID(), executionID: ExecutionID(), proposalHash: "complete-proposal",
                        authorizationEpoch: 7, expiresAt: Date().addingTimeInterval(30),
                        prompt: "Review this synthetic platform operation and its full input.")
                    pending = Task { try await group.approvals.request(request) }
                    try await eventually { model.approvals.contains(request) }
                    let changed = RuntimeApprovalRequest(
                        invocationID: request.id, executionID: request.executionID, proposalHash: "changed-proposal",
                        authorizationEpoch: request.authorizationEpoch, expiresAt: request.expiresAt,
                        prompt: request.prompt)
                    await model.resolveApproval(changed, decision: .approved)
                    #expect(model.approvals.contains(request))
                    await model.resolveApproval(request, decision: .denied)
                    #expect(try await pending?.value == .denied)
                    try await eventually { model.approvals.isEmpty }
                    await model.resolveApproval(request, decision: .approved)
                    #expect(model.error == nil)
                    observer.cancel()
                    await observer.value
                    #expect(await library.close().isSettled)
                } catch {
                    observer.cancel()
                    await observer.value
                    _ = await library.close()
                    _ = try? await pending?.value
                    throw error
                }
            }
        }

        @Test
        func sendsDurableThinkingAndBodyAndRetainsDraftPageAcrossConversationSwitches() async throws {
            try await withDirectory { directory in
                let library = try await Self.openDemoLibrary(directory: directory, stress: true)
                let model = ConversationModel(library: library)
                let observer = Task { @MainActor in await model.observe() }
                do {
                    try await eventually { model.isReady && !model.routes.isEmpty }
                    let group = try #require(model.workgroup)
                    let firstPage = model.activePage
                    firstPage.composer = "Show the local demo fixture."
                    await model.send()
                    let sessionID = try #require(firstPage.conversationID)
                    firstPage.composer = "Draft retained while browsing."
                    firstPage.readingState.recordOffset(123)
                    await model.newConversation()
                    let streamingDestination = model.activePage
                    streamingDestination.composer = "Second conversation draft."
                    try await Self.waitForExecution(group, sessionID: sessionID)
                    #expect(model.activePage === streamingDestination)
                    #expect(streamingDestination.composer == "Second conversation draft.")
                    try await eventually {
                        guard firstPage.activeExecution == nil else { return false }
                        guard let assistant = firstPage.messages.last(where: { $0.summary.role == .assistant }) else {
                            return false
                        }
                        return assistant.body.text?.isEmpty == false && assistant.thinking.text?.isEmpty == false
                    }

                    let assistant = try #require(firstPage.messages.last(where: { $0.summary.role == .assistant }))
                    #expect(assistant.body.text?.isEmpty == false)
                    #expect(assistant.thinking.text?.isEmpty == false)
                    let durablePage = try await group.queries.messagePage(sessionID: sessionID)
                    #expect(durablePage.session?.id == sessionID)
                    #expect(durablePage.messages.contains { $0.id == assistant.id })
                    firstPage.composer = "Draft retained while browsing."
                    firstPage.readingState.recordOffset(123)
                    let pageID = firstPage.id

                    await model.newConversation()
                    let secondPage = model.activePage
                    #expect(secondPage.id != pageID)
                    secondPage.composer = "Second conversation draft."
                    secondPage.readingState.recordOffset(37)
                    await model.selectConversation(sessionID)

                    #expect(model.activePage === firstPage)
                    #expect(model.activePage.id == pageID)
                    #expect(model.activePage.composer == "Draft retained while browsing.")
                    #expect(model.activePage.readingState.visibleOffset == 123)
                    #expect(model.activePage.messages.contains { $0.id == assistant.id })
                    await model.selectConversation(nil)
                    #expect(model.activePage === secondPage)
                    #expect(model.activePage.composer == "Second conversation draft.")
                    #expect(model.activePage.readingState.visibleOffset == 37)
                    await model.selectConversation(sessionID)
                    #expect(model.activePage === firstPage)

                    observer.cancel()
                    await observer.value
                    #expect(await library.close().isSettled)
                } catch {
                    observer.cancel()
                    await observer.value
                    _ = await library.close()
                    throw error
                }
            }
        }

        @Test
        func cancellingConversationObservationDoesNotCancelAcceptedStressExecution() async throws {
            try await withDirectory { directory in
                let library = try await Self.openDemoLibrary(directory: directory, stress: true)
                let model = ConversationModel(library: library)
                let observer = Task { @MainActor in await model.observe() }
                do {
                    try await eventually { model.isReady && !model.routes.isEmpty }
                    let group = try #require(model.workgroup)
                    model.activePage.composer = "Keep running after the window observer stops."
                    let send = Task { @MainActor in await model.send() }
                    try await eventually {
                        guard let sessionID = model.activePage.conversationID else { return false }
                        return await group.application.snapshot().ownedExecutions.contains {
                            $0.sessionID == sessionID
                        }
                    }
                    await send.value
                    let sessionID = try #require(model.activePage.conversationID)
                    try await eventually {
                        await group.application.snapshot().ownedExecutions.contains { $0.sessionID == sessionID }
                    }
                    let address = try #require(
                        await group.application.snapshot().ownedExecutions.first { $0.sessionID == sessionID })

                    observer.cancel()
                    await observer.value
                    let beforeCancel = try await group.application.sessionSnapshot(id: sessionID)
                    #expect(beforeCancel.executions[address.executionID]?.completion == nil)

                    await group.application.cancel(sessionID: sessionID)
                    try committed(
                        await group.application.waitForExecution(
                            id: address.executionID, sessionID: sessionID))
                    let afterCancel = try await group.application.sessionSnapshot(id: sessionID)
                    #expect(afterCancel.executions[address.executionID]?.completion?.status == .cancelled)
                    #expect(await library.close().isSettled)
                } catch {
                    observer.cancel()
                    await observer.value
                    _ = await library.close()
                    throw error
                }
            }
        }

        @Test
        func cancellingSubmissionBeforeOrDuringAdmissionPreservesOneOutcome() async throws {
            try await withDirectory { directory in
                let library = try await Self.openDemoLibrary(directory: directory, stress: true)
                let model = ConversationModel(library: library)
                let observer = Task { @MainActor in await model.observe() }
                let page = model.activePage
                let input = "Cancel this submission during admission without duplicating it."
                var send: Task<Void, Never>?
                do {
                    try await eventually { model.isReady && !model.routes.isEmpty }
                    page.composer = input
                    send = Task { @MainActor in await model.send(page) }
                    try await eventually { page.isSending }
                    await model.cancel(page)
                    if let send { await send.value }

                    guard let sessionID = page.conversationID else {
                        #expect(page.composer == input)
                        #expect(page.pendingAdmission == nil)
                        #expect(!page.isSending)
                        send = nil
                        observer.cancel()
                        await observer.value
                        #expect(await library.close().isSettled)
                        return
                    }

                    let group = try #require(model.workgroup)
                    try await Self.waitForExecution(group, sessionID: sessionID)
                    let state = try await group.application.sessionSnapshot(id: sessionID)
                    let executionID = try #require(state.executionOrder.last)
                    #expect(
                        state.executions[executionID]?.completion?.status == .cancelled,
                        "The accepted submission must be cancelled by the page cancellation request.")
                    let pageSnapshot = try await group.queries.messagePage(sessionID: sessionID)
                    #expect(pageSnapshot.messages.filter { $0.summary.role == .user }.count <= 1)

                    send = nil
                    observer.cancel()
                    await observer.value
                    #expect(await library.close().isSettled)
                } catch {
                    if let send {
                        send.cancel()
                        await send.value
                    }
                    observer.cancel()
                    await observer.value
                    _ = await library.close()
                    throw error
                }
            }
        }

        @Test
        func archivesThroughTheModelAndRefreshesTheSidebar() async throws {
            try await withDirectory { directory in
                let library = try await Self.openDemoLibrary(directory: directory, stress: false)
                let model = ConversationModel(library: library)
                let observer = Task { @MainActor in await model.observe() }
                do {
                    try await eventually { model.isReady && !model.routes.isEmpty }
                    let group = try #require(model.workgroup)
                    model.activePage.composer = "Archive this local conversation."
                    await model.send()
                    let sessionID = try #require(model.activePage.conversationID)
                    try await Self.waitForExecution(group, sessionID: sessionID)
                    try await eventually {
                        model.activePage.activeExecution == nil
                            && model.activePage.messages.contains { $0.summary.role == .assistant }
                    }
                    await model.archive(sessionID)
                    try await eventually {
                        !model.conversations.contains { $0.id == sessionID }
                    }

                    model.showArchived = true
                    try await eventually {
                        model.conversations.contains { $0.id == sessionID && $0.summary.isArchived }
                    }
                    #expect(model.conversations.contains { $0.id == sessionID && $0.summary.isArchived })
                    #expect(try await group.application.sessionSnapshot(id: sessionID).isArchived)
                    observer.cancel()
                    await observer.value
                    #expect(await library.close().isSettled)
                } catch {
                    observer.cancel()
                    await observer.value
                    _ = await library.close()
                    throw error
                }
            }
        }

        @Test
        func retriesTheSamePendingCommandAfterExportWithoutResubmittingIt() async throws {
            try await withDirectory { directory in
                let library = try await Self.openDemoLibrary(directory: directory, stress: false)
                let model = ConversationModel(library: library)
                let observer = Task { @MainActor in await model.observe() }
                do {
                    try await eventually { model.isReady && !model.routes.isEmpty }
                    let page = model.activePage
                    let oldGroup = try #require(model.workgroup)
                    let input = "Recover this accepted command after replacement."
                    let route = try await oldGroup.modelSettings.resolve(
                        purpose: AgentModelPurposeID.conversation, explicitRouteID: nil,
                        sessionSelection: .inherit, workspaceID: page.workspaceID, requiredCapabilities: []
                    )
                    .route
                    let command = AgentSubmitCommand(
                        id: UUID(), sessionID: .init(), executionID: .init(),
                        input: .message(id: .init(), text: input, timeZoneIdentifier: "UTC"),
                        options: .init(instructions: "Answer from the local demo fixture.", route: route),
                        opening: .init(title: String(input.prefix(80)), workspaceID: page.workspaceID))
                    page.composer = input
                    page.pendingAdmission = command
                    page.pendingAdmissionRuntimeID = oldGroup.application.id

                    try committed(await oldGroup.application.submit(command))
                    try committed(
                        await oldGroup.application.waitForExecution(
                            id: command.executionID, sessionID: command.sessionID))
                    let beforeExport = try await oldGroup.queries.messagePage(sessionID: command.sessionID)
                    let messageIDsBeforeExport = beforeExport.messages.map(\.id)
                    #expect(beforeExport.messages.count == 2)

                    let archive = directory.deletingLastPathComponent().appendingPathComponent("PendingCommandExport")
                    _ = try await library.exportArchive(to: archive)
                    try await eventually {
                        model.isReady && model.workgroup != nil && model.workgroup !== oldGroup
                    }
                    let newGroup = try #require(model.workgroup)
                    await model.retrySaving(page)

                    #expect(page.conversationID == command.sessionID)
                    #expect(page.pendingAdmission == nil)
                    #expect(page.pendingAdmissionRuntimeID == nil)
                    #expect(page.composer.isEmpty)
                    let afterRetry = try await newGroup.queries.messagePage(sessionID: command.sessionID)
                    #expect(afterRetry.messages.map(\.id) == messageIDsBeforeExport)
                    #expect(afterRetry.executions.filter { $0.id == command.executionID }.count == 1)
                    #expect(afterRetry.session?.id == command.sessionID)

                    observer.cancel()
                    await observer.value
                    #expect(await library.close().isSettled)
                } catch {
                    observer.cancel()
                    await observer.value
                    _ = await library.close()
                    throw error
                }
            }
        }

        @Test
        func maintenanceAndExportReplaceWorkgroupWhileRetainingPageDraftAndGeometry() async throws {
            try await withDirectory { directory in
                let library = try await Self.openDemoLibrary(directory: directory, stress: false)
                let model = ConversationModel(library: library)
                let observer = Task { @MainActor in await model.observe() }
                do {
                    try await eventually { model.isReady && !model.routes.isEmpty }
                    let group = try #require(model.workgroup)
                    model.activePage.composer = "Preserve this draft through maintenance."
                    await model.send()
                    let sessionID = try #require(model.activePage.conversationID)
                    try await Self.waitForExecution(group, sessionID: sessionID)
                    try await eventually {
                        model.activePage.activeExecution == nil
                            && model.activePage.messages.contains { $0.summary.role == .assistant }
                    }
                    let page = model.activePage
                    page.composer = "Draft survives workgroup replacement."
                    page.readingState.recordOffset(211)
                    let oldGroup = try #require(model.workgroup)
                    let request = AgentLibraryMaintenanceRequest(
                        id: UUID(), namespace: "knowledge.collect", revision: 1,
                        scope: .library, requestedAt: Date())

                    _ = try await library.maintain(request)
                    try await eventually {
                        model.isReady && model.workgroup != nil && model.workgroup !== oldGroup
                            && model.activePage === page && page.messages.contains { $0.summary.role == .assistant }
                    }
                    let maintenanceGroup = try #require(model.workgroup)
                    #expect(await oldGroup.status().isClosed)
                    #expect(model.activePage === page)
                    #expect(page.composer == "Draft survives workgroup replacement.")
                    #expect(page.readingState.visibleOffset == 211)
                    let maintainedPage = try await maintenanceGroup.queries.messagePage(sessionID: sessionID)
                    #expect(maintainedPage.messages.contains { $0.summary.role == .assistant })

                    page.composer = "Draft survives export too."
                    page.readingState.recordOffset(319)
                    let archive = directory.deletingLastPathComponent().appendingPathComponent("ConversationExport")
                    _ = try await library.exportArchive(to: archive)
                    try await eventually {
                        model.isReady && model.workgroup != nil && model.workgroup !== maintenanceGroup
                            && model.activePage === page && page.messages.contains { $0.summary.role == .assistant }
                    }
                    let exportedGroup = try #require(model.workgroup)
                    #expect(page.composer == "Draft survives export too.")
                    #expect(page.readingState.visibleOffset == 319)
                    let exportedPage = try await exportedGroup.queries.messagePage(sessionID: sessionID)
                    #expect(exportedPage.messages.contains { $0.summary.role == .assistant })
                    observer.cancel()
                    await observer.value
                    #expect(await library.close().isSettled)
                } catch {
                    observer.cancel()
                    await observer.value
                    _ = await library.close()
                    throw error
                }
            }
        }

        @Test
        func committedWorkspaceChangeReloadsBothWindowsWithoutManualRefresh() async throws {
            try await withDirectory { directory in
                let library = try await Self.openDemoLibrary(directory: directory, stress: false)
                let first = ConversationModel(library: library)
                let second = ConversationModel(library: library)
                let observers = [Task { await first.observe() }, Task { await second.observe() }]
                do {
                    try await eventually {
                        first.isReady && second.isReady && !first.routes.isEmpty && !second.routes.isEmpty
                    }
                    let group = try #require(first.workgroup)
                    let workspace = Workspace(id: .init(), name: "Shared workspace", revision: 1)
                    try await group.workspaces.save(workspace, expectedRevision: nil)
                    try await eventually {
                        first.workspaces.contains { $0.id == workspace.id }
                            && second.workspaces.contains { $0.id == workspace.id }
                    }
                    var changed = workspace
                    changed.name = "Updated from another window"
                    changed.revision = 2
                    try await group.workspaces.save(changed, expectedRevision: 1)
                    try await eventually {
                        first.workspaces.first { $0.id == workspace.id }?.revision == 2
                            && second.workspaces.first { $0.id == workspace.id }?.revision == 2
                    }
                    observers.forEach { $0.cancel() }
                    for observer in observers { await observer.value }
                    #expect(await library.close().isSettled)
                } catch {
                    observers.forEach { $0.cancel() }
                    for observer in observers { await observer.value }
                    _ = await library.close()
                    throw error
                }
            }
        }

        private static func openDemoLibrary(directory: URL, stress: Bool) async throws -> MacLibrary {
            let library = try await MacLibrary.open(embeddings: OfflineMemoryEmbedding(), directory: directory, notifications: CompositionNotifications(),
                credentials: CompositionCredentials(),
                modules: { [MacDemoModule(registry: $0, stress: stress)] })
            do {
                let group = try await library.workloads()
                try await MacDemoModule.seed(in: group)
                return library
            } catch {
                _ = await library.close()
                throw error
            }
        }

        private static func waitForExecution(
            _ group: MacLibraryWorkloads, sessionID: ConversationID
        ) async throws {
            try await eventually {
                guard let state = try? await group.application.sessionSnapshot(id: sessionID) else { return false }
                return !state.executionOrder.isEmpty
            }
            let state = try await group.application.sessionSnapshot(id: sessionID)
            let executionID = try #require(state.executionOrder.last)
            try committed(await group.application.waitForExecution(id: executionID, sessionID: sessionID))
        }
    }

    @Suite("Conversation model choice policy")
    @MainActor
    struct ConversationModelChoiceTests {
        @Test
        func fixedAndFollowLatestDefaultsPreserveJournalSelectionsAndPreferencePersistence() async throws {
            try await withDirectory { directory in
                let library = try await Self.openDemoLibrary(directory: directory)
                let suiteName = "mira-conversation-choice-" + UUID().uuidString
                let defaults = UserDefaults(suiteName: suiteName)!
                defer { defaults.removePersistentDomain(forName: suiteName) }
                let preferences = ConversationModelPreferences(defaults: defaults)
                let model = ConversationModel(library: library, modelPreferences: preferences)
                let observer = Task { await model.observe() }
                do {
                    try await eventually { model.isReady && model.routes.count == 1 }
                    let group = try #require(model.workgroup)
                    let original = try #require(model.routes.first)
                    let originalCandidate = original.candidate
                    let alternateModelID = ModelDescriptorID()
                    let alternateRouteID = RouteID(alternateModelID.rawValue)
                    let alternateModel = AgentConfiguredModel(
                        id: alternateModelID, revision: 1, authorizationRevision: 1,
                        reference: .init(connectionID: originalCandidate.model.connectionID, modelID: "mira-demo-alternate"),
                        displayName: "Mira Local Demo Alternate", isEnabled: true,
                        invocations: originalCandidate.model.invocations, facts: originalCandidate.model.facts)
                    let alternatePreset = AgentRoutePreset(
                        id: alternateRouteID, revision: 1, name: "Mira Local Demo Alternate",
                        modelDescriptorID: alternateModelID,
                        invocationID: originalCandidate.preset.invocationID,
                        maximumOutputTokens: originalCandidate.preset.maximumOutputTokens,
                        configuration: originalCandidate.preset.configuration)
                    try await group.modelSettings.savePoolModel(
                        alternateModel, preset: alternatePreset,
                        expectedModelRevision: nil, expectedPresetRevision: nil)
                    try await eventually { model.routes.contains { $0.id == alternateRouteID } }

                    preferences.setFollowing(false, libraryID: library.id, scope: .global)
                    await model.newConversation()
                    let page = model.activePage
                    try await eventually { page.selectedRouteID == original.id }
                    await model.selectModel(page, routeID: alternateRouteID)
                    #expect(page.selectedRouteID == alternateRouteID)
                    #expect(page.modelSelection == .inherit)
                    #expect(preferences.lastRoute(libraryID: library.id) == alternateRouteID)
                    page.composer = "Create a committed alternate-model session."
                    await model.send(page)
                    let sessionID = try #require(page.conversationID)
                    try await Self.waitForExecution(group, sessionID: sessionID)
                    let committedAlternate = try await group.application.sessionSnapshot(id: sessionID)
                    if case .selected(let committedReference) = committedAlternate.modelSelection {
                        #expect(committedReference.routeID == alternateRouteID)
                    } else {
                        Issue.record("First send did not commit the explicit model selection")
                    }

                    await model.selectConversation(sessionID)
                    let committedPage = model.activePage
                    try await eventually { committedPage.activeExecution == nil && committedPage.selectedRouteID == alternateRouteID }
                    await model.selectModel(committedPage, routeID: original.id)
                    let switchedToOriginal = try await group.application.sessionSnapshot(id: sessionID)
                    if case .selected(let originalReference) = switchedToOriginal.modelSelection {
                        #expect(originalReference.routeID == original.id)
                    } else {
                        Issue.record("Committed model selection was not journaled")
                    }
                    await model.selectModel(committedPage, routeID: alternateRouteID)
                    let switchedBack = try await group.application.sessionSnapshot(id: sessionID)
                    if case .selected(let alternateReference) = switchedBack.modelSelection {
                        #expect(alternateReference.routeID == alternateRouteID)
                    } else {
                        Issue.record("Committed model selection did not switch back")
                    }

                    await model.newConversation()
                    let fixedPage = model.activePage
                    try await eventually { fixedPage.selectedRouteID == original.id }
                    #expect(preferences.lastRoute(libraryID: library.id) == alternateRouteID)
                    let conversationBinding = try #require(try await group.modelSettings.bindings(scope: .global).first {
                        $0.purpose == AgentModelPurposeID.conversation
                    })
                    #expect(conversationBinding.routeID == original.id)

                    preferences.setFollowing(true, libraryID: library.id, scope: .global)
                    await model.newConversation()
                    let followingPage = model.activePage
                    try await eventually { followingPage.selectedRouteID == alternateRouteID }

                    await model.selectConversation(sessionID)
                    try await eventually { model.activePage.selectedRouteID == alternateRouteID }
                    preferences.setFollowing(false, libraryID: library.id, scope: .global)
                    await model.newConversation()
                    try await eventually { model.activePage.selectedRouteID == original.id }
                    #expect(try await group.application.sessionSnapshot(id: sessionID).modelSelection
                        != .inherit)

                    let restoredPreferences = ConversationModelPreferences(defaults: defaults)
                    #expect(restoredPreferences.followsLastSelection(libraryID: library.id, scope: .global) == false)
                    #expect(restoredPreferences.lastRoute(libraryID: library.id) == alternateRouteID)

                    let disabled = AgentConfiguredModel(
                        id: alternateModel.id, revision: 2, authorizationRevision: 2,
                        reference: alternateModel.reference, displayName: alternateModel.displayName,
                        isEnabled: false, invocations: alternateModel.invocations, facts: alternateModel.facts)
                    try await group.modelSettings.saveModel(disabled, expectedRevision: 1)
                    preferences.remember(original.id, libraryID: library.id)
                    let invalidPage = model.activePage
                    await model.selectModel(invalidPage, routeID: alternateRouteID)
                    #expect(preferences.lastRoute(libraryID: library.id) == original.id)

                    observer.cancel()
                    await observer.value
                    #expect(await library.close().isSettled)
                } catch {
                    observer.cancel()
                    await observer.value
                    _ = await library.close()
                    throw error
                }
            }
        }

        private static func openDemoLibrary(directory: URL) async throws -> MacLibrary {
            let library = try await MacLibrary.open(embeddings: OfflineMemoryEmbedding(), directory: directory, notifications: CompositionNotifications(),
                credentials: CompositionCredentials(),
                modules: { [MacDemoModule(registry: $0)] })
            do {
                try await MacDemoModule.seed(in: library.workloads())
                return library
            } catch {
                _ = await library.close()
                throw error
            }
        }

        private static func waitForExecution(
            _ group: MacLibraryWorkloads, sessionID: ConversationID
        ) async throws {
            try await eventually {
                guard let state = try? await group.application.sessionSnapshot(id: sessionID) else { return false }
                return !state.executionOrder.isEmpty
            }
            let state = try await group.application.sessionSnapshot(id: sessionID)
            let executionID = try #require(state.executionOrder.last)
            try committed(await group.application.waitForExecution(id: executionID, sessionID: sessionID))
        }
    }
#endif
