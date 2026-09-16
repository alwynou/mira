#if DEBUG
    import Foundation
    import MiraCore
    import Testing

    @Suite("memory editor model", .timeLimit(.minutes(1)))
    @MainActor
    struct MemoryEditorModelTests {
        @Test
        func manualWriteKeepsOperationIdentityAcrossRetry() async throws {
            try await withDirectory { directory in
                let library = try await MacLibrary.open(embeddings: OfflineMemoryEmbedding(),
                    directory: directory, notifications: CompositionNotifications(),
                    credentials: CompositionCredentials(), modules: { _ in [] })
                do {
                    let model = MemoryEditorModel(library: library, workspaces: [])
                    model.content = "User prefers tea."
                    let operationID = model.operationID
                    await model.save()
                    let first = try #require(model.receipt)
                    #expect(model.saved)
                    #expect(first.disposition == .created || first.disposition == .existing)

                    await model.retrySaving()
                    let retried = try #require(model.receipt)
                    #expect(model.operationID == operationID)
                    #expect(retried.memory.id == first.memory.id)
                    #expect(retried.disposition == .existing || retried.disposition == first.disposition)
                    model.content = ""
                    await model.save()
                    #expect(!model.saved)
                    #expect(model.receipt == nil)
                    #expect(model.error != nil)
                    #expect(await library.close().isSettled)
                } catch {
                    _ = await library.close()
                    throw error
                }
            }
        }

        @Test
        func staleRevisionIsRejectedWithoutCreatingAnotherMemory() async throws {
            try await withDirectory { directory in
                let library = try await MacLibrary.open(embeddings: OfflineMemoryEmbedding(),
                    directory: directory, notifications: CompositionNotifications(),
                    credentials: CompositionCredentials(), modules: { _ in [] })
                do {
                    let creator = MemoryEditorModel(library: library, workspaces: [])
                    creator.content = "Original memory"
                    await creator.save()
                    let original = try #require(creator.receipt?.memory)
                    let group = try await library.workloads()
                    _ = try await group.memories.reviseMemory(
                        original.id, workspaceID: nil,
                        draft: .init(content: "Concurrent revision", scope: .global),
                        expectedRevision: original.revision, operationID: UUID())

                    let editor = MemoryEditorModel(library: library, workspaces: [], existing: original)
                    editor.content = "Stale editor revision"
                    await editor.save()
                    #expect(editor.error?.code == .conflict)
                    #expect(!editor.saved)
                    let detail = try await group.memories.detail(original.id, workspaceID: nil)
                    #expect(detail.memory.revision == original.revision + 1)
                    #expect(detail.memory.draft?.content == "Concurrent revision")
                    #expect(await library.close().isSettled)
                } catch {
                    _ = await library.close()
                    throw error
                }
            }
        }

        @Test
        func editedDraftStartsANewOperationAfterTheOriginalSettles() async throws {
            try await withDirectory { directory in
                let library = try await MacLibrary.open(embeddings: OfflineMemoryEmbedding(),
                    directory: directory, notifications: CompositionNotifications(),
                    credentials: CompositionCredentials(), modules: { _ in [] })
                do {
                    let model = MemoryEditorModel(library: library, workspaces: [])
                    model.content = "First durable draft"
                    let firstOperation = model.operationID
                    await model.save()
                    let firstID = try #require(model.receipt?.memory.id)

                    model.content = "Second durable draft"
                    await model.save()
                    let secondID = try #require(model.receipt?.memory.id)
                    #expect(model.operationID != firstOperation)
                    #expect(secondID != firstID)
                    #expect(await library.close().isSettled)
                } catch {
                    _ = await library.close()
                    throw error
                }
            }
        }

        @Test
        func missingSourcePageStopsLoadingAndCloseClearsCachedSource() async throws {
            try await withDirectory { directory in
                let library = try await MacLibrary.open(embeddings: OfflineMemoryEmbedding(),
                    directory: directory, notifications: CompositionNotifications(),
                    credentials: CompositionCredentials(), modules: { _ in [] })
                var observer: Task<Void, Never>?
                do {
                    let sessionID = ConversationID()
                    let summary = SessionMessageSummary(
                        id: MessageID(), sessionID: sessionID, executionID: ExecutionID(),
                        role: .user, sequence: 1, occurredAt: .now,
                        body: nil, thinking: nil, bodyInvalidated: false,
                        thinkingInvalidated: false, isExcludedFromContext: false)
                    let source = SessionQueryMessage(
                        summary: summary, body: .available("cached source"), thinking: .absent)
                    let model = MemoryEditorModel(
                        library: library, workspaces: [], sourceMessage: source)
                    observer = Task { @MainActor in await model.observeLibrary() }
                    try await eventually { !model.sourceLoading && model.sourceText == nil }
                    #expect(model.sourceText == nil)
                    await model.close()
                    #expect(model.sourceText == nil)
                    observer?.cancel()
                    if let observer { await observer.value }
                    #expect(model.sourceText == nil)
                    #expect(!model.saved)
                    #expect(model.receipt == nil)
                    #expect(await library.close().isSettled)
                } catch {
                    observer?.cancel()
                    if let observer { await observer.value }
                    _ = await library.close()
                    throw error
                }
            }
        }

        @Test
        func sourceIsRevalidatedAcrossLibraryGenerationBeforeWriting() async throws {
            try await withDirectory { directory in
                let library = try await MacLibrary.open(embeddings: OfflineMemoryEmbedding(),
                    directory: directory, notifications: CompositionNotifications(),
                    credentials: CompositionCredentials(),
                    modules: { [MacDemoModule(registry: $0)] })
                var observer: Task<Void, Never>?
                do {
                    let group = try await library.workloads()
                    try await MacDemoModule.seed(in: group)
                    let route = try await group.modelSettings.resolve(
                        purpose: AgentModelPurposeID.conversation, explicitRouteID: nil,
                        sessionSelection: .inherit, workspaceID: nil)
                    let text = "I prefer tea in the morning."
                    let command = AgentSubmitCommand(
                        id: UUID(), sessionID: .init(), executionID: .init(),
                        input: .message(id: .init(), text: text, timeZoneIdentifier: "UTC"),
                        options: .init(instructions: "Use the local fixture.", route: route.route),
                        opening: .init(title: "Memory source", workspaceID: nil))
                    try committed(await group.application.submit(command))
                    try committed(
                        await group.application.waitForExecution(
                            id: command.executionID, sessionID: command.sessionID))
                    let page = try await group.queries.messagePage(sessionID: command.sessionID)
                    let source = try #require(page.messages.first { $0.summary.role == .user })
                    let model = MemoryEditorModel(
                        library: library, workspaces: [], sourceMessage: source)
                    observer = Task { @MainActor in await model.observeLibrary() }
                    try await eventually { model.sourceText == text }

                    let archive = directory.deletingLastPathComponent().appendingPathComponent("MemoryEditorExport")
                    _ = try await library.exportArchive(to: archive)
                    try await eventually {
                        let status = await library.status()
                        return status.phase == .ready && status.generation > 1 && model.sourceText == text
                    }

                    model.content = "The user prefers tea in the morning."
                    model.evidenceExcerpt = "I prefer tea in the morning."
                    await model.save()
                    #expect(model.saved)
                    #expect(model.receipt?.memory.draft?.content == model.content)
                    observer?.cancel()
                    if let observer { await observer.value }
                    #expect(model.sourceText == nil)
                    #expect(!model.saved)
                    #expect(model.receipt == nil)
                    #expect(await library.close().isSettled)
                } catch {
                    observer?.cancel()
                    if let observer { await observer.value }
                    _ = await library.close()
                    throw error
                }
            }
        }
    }
#endif
