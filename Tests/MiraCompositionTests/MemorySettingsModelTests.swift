#if DEBUG
    import Foundation
    import MiraCore
    import Testing

    @Suite("Memory settings model", .timeLimit(.minutes(1)))
    @MainActor
    struct MemorySettingsModelTests {
        @Test
        func extractionRouteUsesCurrentGlobalAndWorkspaceBindings() async throws {
            try await withContainer { container, library in
                let group = try await library.workloads()
                let workspace = Workspace(id: .init(), name: "Memory settings workspace")
                try await group.workspaces.save(workspace, expectedRevision: nil)
                try await group.modelSettings.saveBinding(
                    .init(
                        scope: .workspace(workspace.id), purpose: AgentModelPurposeID.memoryExtraction,
                        routeID: MacDemoModule.routeID, revision: 1), expectedRevision: nil)

                let model = MemorySettingsModel(container: container)
                let observation = Task { @MainActor in await model.observe() }
                do {
                    try await eventually {
                        model.budget != nil && model.hasMemoryExtractionRoute
                            && model.workspaces.contains { $0.id == workspace.id }
                    }
                    #expect(model.hasMemoryExtractionRoute)
                    #expect(model.workspaces.contains { $0.id == workspace.id })
                    await model.stop()
                    observation.cancel()
                    await observation.value
                } catch {
                    observation.cancel()
                    await observation.value
                    await model.stop()
                    throw error
                }
            }
        }

        @Test
        func saveUsesCapturePolicyCASAndKeepsTheCurrentSettingsBaseline() async throws {
            try await withContainer { container, library in
                let model = MemorySettingsModel(container: container)
                let observation = Task { @MainActor in await model.observe() }
                do {
                    try await eventually { model.budget != nil }
                    model.mode = .candidateOnly
                    model.dailyTokenLimitText = "1200"
                    model.markDirty()
                    model.startSave()
                    try await eventually { !model.isSaving && model.statusKey != nil }

                    let group = try await library.workloads()
                    let policy = try await group.memories.capturePolicy()
                    #expect(policy.revision == 2)
                    #expect(policy.mode == .candidateOnly)
                    #expect(policy.dailyTokenLimit == 1200)
                    #expect(!model.isDirty)
                    #expect(model.statusKey == "Memory capture settings saved.")

                    await model.stop()
                    observation.cancel()
                    await observation.value
                } catch {
                    observation.cancel()
                    await observation.value
                    await model.stop()
                    throw error
                }
            }
        }

        @Test
        func stopAndRestartRetainsAnUnsavedDraft() async throws {
            try await withContainer { container, _ in
                let model = MemorySettingsModel(container: container)
                let observation = Task { @MainActor in await model.observe() }
                do {
                    try await eventually { model.budget != nil }
                    model.mode = .candidateOnly
                    model.dailyTokenLimitText = "1400"
                    model.markDirty()

                    await model.stop()
                    observation.cancel()
                    await observation.value
                    #expect(model.isDirty)
                    #expect(model.dailyTokenLimitText == "1400")

                    let restarted = Task { @MainActor in await model.observe() }
                    try await eventually { model.budget != nil && model.isDirty }
                    #expect(model.mode == .candidateOnly)
                    #expect(model.dailyTokenLimitText == "1400")
                    await model.stop()
                    restarted.cancel()
                    await restarted.value
                } catch {
                    observation.cancel()
                    await observation.value
                    await model.stop()
                    throw error
                }
            }
        }

        @Test
        func maintenanceReloadsMetadataWithoutReplacingADirtyDraft() async throws {
            try await withContainer { container, library in
                let model = MemorySettingsModel(container: container)
                let observation = Task { @MainActor in await model.observe() }
                do {
                    try await eventually { model.budget != nil }
                    model.mode = .automaticWithUndo
                    model.dailyTokenLimitText = "2300"
                    model.markDirty()
                    let oldGroup = try await library.workloads()
                    let request = AgentLibraryMaintenanceRequest(
                        id: UUID(), namespace: "knowledge.collect", revision: 1,
                        scope: .library, requestedAt: Date())

                    _ = try await library.maintain(request)
                    try await eventually {
                        container.status.phase == .ready && container.workgroup != nil
                            && container.workgroup !== oldGroup
                    }
                    try await eventually {
                        model.budget != nil && model.isDirty
                            && model.mode == .automaticWithUndo
                            && model.dailyTokenLimitText == "2300"
                    }
                    await model.stop()
                    observation.cancel()
                    await observation.value
                } catch {
                    observation.cancel()
                    await observation.value
                    await model.stop()
                    throw error
                }
            }
        }

        @Test
        func editsAfterSaveStartsRemainTheCurrentDraft() async throws {
            try await withContainer { container, library in
                let model = MemorySettingsModel(container: container)
                let observation = Task { @MainActor in await model.observe() }
                do {
                    try await eventually { model.budget != nil }
                    model.mode = .candidateOnly
                    model.dailyTokenLimitText = "1200"
                    model.markDirty()
                    model.startSave()

                    // startSave captures the submitted policy before this edit.
                    model.mode = .automaticWithUndo
                    model.dailyTokenLimitText = "1300"
                    model.markDirty()
                    try await eventually { !model.isSaving && model.statusKey != nil }

                    let group = try await library.workloads()
                    let policy = try await group.memories.capturePolicy()
                    #expect(policy.mode == .candidateOnly)
                    #expect(policy.dailyTokenLimit == 1200)
                    #expect(model.mode == .automaticWithUndo)
                    #expect(model.dailyTokenLimitText == "1300")
                    #expect(model.isDirty)

                    await model.stop()
                    observation.cancel()
                    await observation.value
                } catch {
                    observation.cancel()
                    await observation.value
                    await model.stop()
                    throw error
                }
            }
        }

        private func withContainer<T: Sendable>(
            _ body: @escaping @MainActor (AppContainer, MacLibrary) async throws -> T
        ) async throws -> T {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("mira-memory-settings-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let launch = MacLibraryLaunchConfiguration(directory: directory, isDemo: false, stress: false)
            let container = AppContainer(launch: launch) { launch in
                let library = try await MacLibrary.open(
                    directory: launch.directory, notifications: CompositionNotifications(),
                    credentials: CompositionCredentials(), modules: { [MacDemoModule(registry: $0)] })
                do {
                    try await MacDemoModule.seed(in: library.workloads())
                    return library
                } catch {
                    _ = await library.close()
                    throw error
                }
            }
            await container.start()
            do {
                let library = try #require(container.library)
                let result = try await body(container, library)
                #expect(await container.close().isSettled)
                return result
            } catch {
                _ = await container.close()
                throw error
            }
        }

        private func eventually(
            _ condition: @escaping @MainActor () -> Bool
        ) async throws {
            let deadline = ContinuousClock.now + .seconds(10)
            while !condition() {
                guard ContinuousClock.now < deadline else {
                    throw MiraError(.timeout, "The memory settings condition was not reached.")
                }
                try await Task.sleep(for: .milliseconds(5))
            }
        }
    }
#endif
