#if DEBUG
    import Foundation
    import MiraCore
    import MiraProviders
    import Testing

    @Suite("macOS session read model", .timeLimit(.minutes(1)))
    @MainActor
    struct MacSessionReadModelTests {
        @Test
        func extractionStatusUsesBusinessCommitsAndRebindsAfterLibraryExport() async throws {
            try await withDirectory { directory in
                let credentials = CompositionCredentials()
                let library = try await MacLibrary.open(embeddings: OfflineMemoryEmbedding(), directory: directory, notifications: CompositionNotifications(),
                    credentials: credentials, modules: { [SyntheticCompositionModelModule(registry: $0)] })
                let reader = MacSessionReadModel<MemoryExtractionStatusPage>()
                var observer: Task<Void, Never>?
                do {
                    let group = try await library.workloads()
                    // Reuse only the debug demo's credential-free settings contract;
                    // the registered synthetic adapter returns bounded fixture output.
                    try await MacDemoModule.seed(in: group)
                    let route = try await group.modelSettings.resolve(purpose: AgentModelPurposeID.conversation,
                        explicitRouteID: nil, sessionSelection: .inherit, workspaceID: nil).route
                    let command = AgentSubmitCommand(id: UUID(), sessionID: .init(), executionID: .init(),
                        input: .message(id: .init(), text: "Synthetic extraction source", timeZoneIdentifier: "UTC"),
                        options: .init(instructions: "Respond with the local fixture.", route: route),
                        opening: .init(title: "Synthetic accounting", workspaceID: nil))
                    try committed(await group.application.submit(command))
                    observer = Task {
                        await reader.observe(library: library, sessionID: command.sessionID) { current in
                            try await current.memories.extractionStatus(sessionID: command.sessionID,
                                executionID: command.executionID, workspaceID: nil)
                        }
                    }
                    try committed(await group.application.waitForExecution(id: command.executionID, sessionID: command.sessionID))
                    for index in 1..<4 {
                        let next = AgentSubmitCommand(id: UUID(), sessionID: command.sessionID, executionID: .init(),
                            input: .message(id: .init(), text: "Synthetic extraction turn \(index)", timeZoneIdentifier: "UTC"),
                            options: .init(instructions: "Respond with the local fixture.", route: route))
                        try committed(await group.application.submit(next))
                        try committed(await group.application.waitForExecution(id: next.executionID, sessionID: next.sessionID))
                    }
                    // Memory extraction reuses the conversation route and records its
                    // business attempt before the read model is rebound by export.
                    try await eventually {
                        guard let state = reader.value?.jobs.first?.state else { return false }
                        return state == .completed || state == .paused || state == .failed
                    }
                    let job = try #require(reader.value?.jobs.first)
                    #expect(job.state == .completed)
                    let report = try await group.memories.extractionReport(job.id, sessionID: command.sessionID,
                        executionID: command.executionID, workspaceID: nil)
                    #expect(!report.attempts.isEmpty && report.job.attemptCount == 1)
                    #expect(ModelCostSummary(extractionAttempts: report.attempts).callCount == 1)
                    await #expect(throws: MiraError.self) {
                        try await group.memories.extractionStatus(sessionID: command.sessionID,
                            executionID: .init(), workspaceID: nil)
                    }
                    await #expect(throws: MiraError.self) {
                        try await group.memories.extractionReport(job.id, sessionID: command.sessionID,
                            executionID: command.executionID, workspaceID: .init())
                    }
                    let originalGeneration = await library.status().generation
                    _ = try await library.exportArchive(to: directory.deletingLastPathComponent().appendingPathComponent("ExtractionExport"))
                    try await eventually {
                        await library.status().generation > originalGeneration && reader.value?.jobs.first?.id == job.id
                    }
                    await #expect(throws: MiraError.self) {
                        try await group.memories.extractionStatus(sessionID: command.sessionID,
                            executionID: command.executionID, workspaceID: nil)
                    }
                    observer?.cancel()
                    await observer?.value
                    #expect(reader.value == nil && !reader.isLoading)
                    #expect(credentials.enteredOperations.isEmpty)
                    #expect(await library.close().isSettled)
                } catch {
                    observer?.cancel(); await observer?.value
                    _ = await library.close(); throw error
                }
            }
        }

        @Test
        func cancellationDrainsOwnedReadAndDoesNotLeaveLateValue() async throws {
            try await withDirectory { directory in
                let library = try await MacLibrary.open(embeddings: OfflineMemoryEmbedding(),
                    directory: directory, notifications: CompositionNotifications(),
                    credentials: CompositionCredentials(), modules: { _ in [] })
                let sessionID = ConversationID()
                let probe = ControlledCitationRead()
                let model = MacSessionReadModel<String>()
                var observer: Task<Void, Never>?
                do {
                    let group = try await library.workloads()
                    try committed(
                        await group.application.createSession(
                            id: sessionID, commandID: UUID(), title: "Synthetic citation", workspaceID: nil))
                    observer = Task { @MainActor in
                        await model.observe(library: library, sessionID: sessionID) { _ in
                            await probe.read()
                        }
                    }
                    await probe.waitForFirstRead()
                    observer?.cancel()
                    await probe.releaseFirstRead()
                    if let observer { await observer.value }
                    #expect(model.value == nil)
                    #expect(!model.isLoading)
                    #expect(await probe.callCount() == 1)
                    #expect(await library.close().isSettled)
                } catch {
                    observer?.cancel()
                    await probe.releaseFirstRead()
                    if let observer { await observer.value }
                    _ = await library.close()
                    throw error
                }
            }
        }

        @Test
        func replacementRejectsLateReadFromRetiredGeneration() async throws {
            try await withDirectory { directory in
                let library = try await MacLibrary.open(embeddings: OfflineMemoryEmbedding(),
                    directory: directory, notifications: CompositionNotifications(),
                    credentials: CompositionCredentials(), modules: { _ in [] })
                let sessionID = ConversationID()
                let probe = ControlledCitationRead()
                let model = MacSessionReadModel<String>()
                var observer: Task<Void, Never>?
                do {
                    let group = try await library.workloads()
                    try committed(
                        await group.application.createSession(
                            id: sessionID, commandID: UUID(), title: "Synthetic citation", workspaceID: nil))
                    observer = Task { @MainActor in
                        await model.observe(library: library, sessionID: sessionID) { _ in
                            await probe.read()
                        }
                    }
                    await probe.waitForFirstRead()
                    let archive = directory.deletingLastPathComponent().appendingPathComponent("CitationExport")
                    _ = try await library.exportArchive(to: archive)
                    try await eventually {
                        let status = await library.status()
                        return status.phase == .ready && status.generation > 1
                    }
                    await probe.releaseFirstRead()
                    try await eventually {
                        let count = await probe.callCount()
                        return count >= 2 && model.value == "read-\(count)"
                    }
                    #expect(model.value != nil)
                    observer?.cancel()
                    if let observer { await observer.value }
                    #expect(await library.close().isSettled)
                } catch {
                    observer?.cancel()
                    await probe.releaseFirstRead()
                    if let observer { await observer.value }
                    _ = await library.close()
                    throw error
                }
            }
        }

        @Test
        func supersededNonCooperativeReadRerunsAfterTheCurrentReadDrains() async throws {
            try await withDirectory { directory in
                let library = try await MacLibrary.open(embeddings: OfflineMemoryEmbedding(),
                    directory: directory, notifications: CompositionNotifications(),
                    credentials: CompositionCredentials(), modules: { _ in [] })
                let sessionID = ConversationID()
                let probe = ControlledCitationRead()
                let model = MacSessionReadModel<String>()
                var observer: Task<Void, Never>?
                do {
                    let group = try await library.workloads()
                    try committed(
                        await group.application.createSession(
                            id: sessionID, commandID: UUID(), title: "Synthetic citation", workspaceID: nil))
                    observer = Task { @MainActor in
                        await model.observe(library: library, sessionID: sessionID) { _ in
                            await probe.read()
                        }
                    }
                    await probe.waitForFirstRead()
                    try committed(
                        await group.application.changeSession(
                            id: sessionID, commandID: UUID(), change: .rename(title: "Changed", expectedRevision: 1)))
                    await probe.releaseFirstRead()
                    try await eventually {
                        let count = await probe.callCount()
                        return count >= 2 && model.value == "read-\(count)"
                    }
                    #expect(model.value != nil)
                    observer?.cancel()
                    if let observer { await observer.value }
                    #expect(await library.close().isSettled)
                } catch {
                    observer?.cancel()
                    await probe.releaseFirstRead()
                    if let observer { await observer.value }
                    _ = await library.close()
                    throw error
                }
            }
        }

        @Test
        func endingOldObservationCannotClearTheNewBinding() async throws {
            try await withDirectory { directory in
                let library = try await MacLibrary.open(embeddings: OfflineMemoryEmbedding(),
                    directory: directory, notifications: CompositionNotifications(),
                    credentials: CompositionCredentials(), modules: { _ in [] })
                let sessionID = ConversationID()
                let probe = ControlledCitationRead()
                let model = MacSessionReadModel<String>()
                var oldObserver: Task<Void, Never>?
                var newObserver: Task<Void, Never>?
                do {
                    let group = try await library.workloads()
                    try committed(
                        await group.application.createSession(
                            id: sessionID, commandID: UUID(), title: "Synthetic citation", workspaceID: nil))
                    oldObserver = Task { @MainActor in
                        await model.observe(library: library, sessionID: sessionID) { _ in
                            await probe.read()
                        }
                    }
                    await probe.waitForFirstRead()
                    oldObserver?.cancel()
                    newObserver = Task { @MainActor in
                        await model.observe(library: library, sessionID: sessionID) { _ in "new" }
                    }
                    try await eventually { model.value == "new" }
                    await probe.releaseFirstRead()
                    if let oldObserver { await oldObserver.value }
                    #expect(model.value == "new")
                    newObserver?.cancel()
                    if let newObserver { await newObserver.value }
                    #expect(await library.close().isSettled)
                } catch {
                    oldObserver?.cancel()
                    newObserver?.cancel()
                    await probe.releaseFirstRead()
                    if let oldObserver { await oldObserver.value }
                    if let newObserver { await newObserver.value }
                    _ = await library.close()
                    throw error
                }
            }
        }

        @Test
        func dirtyReadNeverReappearsWhileReplacementReadWaits() async throws {
            try await withDirectory { directory in
                let library = try await MacLibrary.open(embeddings: OfflineMemoryEmbedding(),
                    directory: directory, notifications: CompositionNotifications(),
                    credentials: CompositionCredentials(), modules: { _ in [] })
                let sessionID = ConversationID()
                let gate = RepeatedCitationReadGate()
                let model = MacSessionReadModel<String>()
                var observer: Task<Void, Never>?
                do {
                    let group = try await library.workloads()
                    try committed(
                        await group.application.createSession(
                            id: sessionID, commandID: UUID(), title: "Citation", workspaceID: nil))
                    observer = Task {
                        await model.observe(library: library, sessionID: sessionID) { _ in await gate.read() }
                    }
                    try await eventually { model.value == "initial" }
                    await gate.beginBlocking()
                    try committed(
                        await group.application.changeSession(
                            id: sessionID, commandID: UUID(),
                            change: .rename(title: "First change", expectedRevision: 1)))
                    try await eventually { await gate.blockedCount == 1 }
                    #expect(model.value == nil)
                    try committed(
                        await group.application.changeSession(
                            id: sessionID, commandID: UUID(),
                            change: .rename(title: "Second change", expectedRevision: 2)))
                    // Give the stream consumer an opportunity to process the hint
                    // while the actual read remains blocked by the explicit gate.
                    for _ in 0..<100 { await Task.yield() }
                    await gate.releaseCurrent()
                    try await eventually { await gate.blockedCount == 2 }
                    #expect(
                        model.value == nil, "The invalidated result must not be published while the replacement waits.")
                    observer?.cancel()
                    await gate.releaseAll()
                    if let observer { await observer.value }
                    #expect(await library.close().isSettled)
                } catch {
                    observer?.cancel()
                    await gate.releaseAll()
                    if let observer { await observer.value }
                    _ = await library.close()
                    throw error
                }
            }
        }

        @Test
        func businessChangeClearsAndReloadsCitation() async throws {
            try await withDirectory { directory in
                let library = try await MacLibrary.open(embeddings: OfflineMemoryEmbedding(),
                    directory: directory, notifications: CompositionNotifications(),
                    credentials: CompositionCredentials(), modules: { _ in [] })
                let sessionID = ConversationID()
                let probe = ControlledCitationRead()
                let model = MacSessionReadModel<String>()
                var observer: Task<Void, Never>?
                do {
                    let group = try await library.workloads()
                    try committed(
                        await group.application.createSession(
                            id: sessionID, commandID: UUID(), title: "Synthetic citation", workspaceID: nil))
                    observer = Task { @MainActor in
                        await model.observe(library: library, sessionID: sessionID) { _ in
                            await probe.read()
                        }
                    }
                    await probe.waitForFirstRead()
                    await probe.releaseFirstRead()
                    try await eventually { model.value != nil }
                    let initialCount = await probe.callCount()
                    _ = try await group.memories.createMemory(
                        draft: .init(content: "Synthetic citation change", scope: .global),
                        source: .manualEntry(id: UUID(), statement: "Synthetic citation change"),
                        operationID: UUID())
                    try await eventually {
                        let count = await probe.callCount()
                        return count > initialCount && model.value == "read-\(count)"
                    }
                    #expect(model.value != nil)
                    observer?.cancel()
                    if let observer { await observer.value }
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

    private actor RepeatedCitationReadGate {
        private var blocking = false
        private var waiter: CheckedContinuation<Void, Never>?
        private(set) var blockedCount = 0
        func beginBlocking() { blocking = true }
        func read() async -> String {
            guard blocking else { return "initial" }
            blockedCount += 1
            let number = blockedCount
            await withCheckedContinuation { waiter = $0 }
            return "retired-\(number)"
        }
        func releaseCurrent() {
            waiter?.resume()
            waiter = nil
        }
        func releaseAll() {
            blocking = false
            releaseCurrent()
        }
    }

    private actor ControlledCitationRead {
        private var calls = 0
        private var firstReadStarted = false
        private var firstReadWaiter: CheckedContinuation<Void, Never>?
        private var firstReadRelease: CheckedContinuation<Void, Never>?

        func read() async -> String {
            calls += 1
            let call = calls
            if call == 1 {
                firstReadStarted = true
                firstReadWaiter?.resume()
                firstReadWaiter = nil
                await withCheckedContinuation { continuation in
                    firstReadRelease = continuation
                }
            }
            return "read-\(call)"
        }

        func waitForFirstRead() async {
            if firstReadStarted { return }
            await withCheckedContinuation { continuation in
                firstReadWaiter = continuation
            }
        }

        func releaseFirstRead() {
            firstReadRelease?.resume()
            firstReadRelease = nil
        }

        func callCount() -> Int { calls }
    }
#endif
