#if DEBUG
    import Foundation
    import MiraCore
    import Testing

    @Suite("Memory settings model", .timeLimit(.minutes(1)))
    @MainActor
    struct MemorySettingsModelTests {
        @Test
        func observesReadyLibraryAndStopsItsLocalStatusPolling() async throws {
            try await withContainer { container, _, embedding in
                let model = MemorySettingsModel(container: container)
                let observation = Task { @MainActor in await model.observe() }
                do {
                    try await eventuallyAsync {
                        guard container.status.phase == .ready, model.localModelStatus == .ready else { return false }
                        return await embedding.statusCallCount > 0
                    }
                    #expect(model.error == nil)

                    await model.stop()
                    #expect(model.localModelStatus == .unavailable)
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
        func maintenanceRebindsObservationWithoutStaleErrors() async throws {
            try await withContainer { container, library, embedding in
                let model = MemorySettingsModel(container: container)
                let observation = Task { @MainActor in await model.observe() }
                do {
                    try await eventuallyAsync {
                        container.status.phase == .ready && model.localModelStatus == .ready
                    }
                    let initialStatusCalls = await embedding.statusCallCount
                    let oldGroup = try await library.workloads()
                    let request = AgentLibraryMaintenanceRequest(
                        id: UUID(), namespace: "knowledge.collect", revision: 1,
                        scope: .library, requestedAt: Date())

                    _ = try await library.maintain(request)
                    try await eventually {
                        container.status.phase == .ready && container.workgroup != nil
                            && container.workgroup !== oldGroup
                    }
                    try await eventuallyAsync {
                        guard model.error == nil, model.localModelStatus == .ready else { return false }
                        return await embedding.statusCallCount > initialStatusCalls
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
        func preparingLocalModelDoesNotOutliveSettingsLifecycle() async throws {
            try await withContainer { container, _, embedding in
                let model = MemorySettingsModel(container: container)
                let observation = Task { @MainActor in await model.observe() }
                do {
                    try await eventuallyAsync {
                        container.status.phase == .ready && model.localModelStatus == .ready
                    }
                    model.prepareLocalModel()
                    try await eventuallyAsync { await embedding.prepareCallCount > 0 }
                    await model.stop()
                    #expect(model.localModelStatus == .unavailable)
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
            _ body: @escaping @MainActor (AppContainer, MacLibrary, SettingsTestEmbedding) async throws -> T
        ) async throws -> T {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("mira-memory-settings-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let launch = MacLibraryLaunchConfiguration(directory: directory, isDemo: false, stress: false)
            let embedding = SettingsTestEmbedding()
            let container = AppContainer(launch: launch) { launch in
                let library = try await MacLibrary.open(embeddings: embedding,
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
                let result = try await body(container, library, embedding)
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

        private func eventuallyAsync(
            _ condition: @escaping @MainActor () async -> Bool
        ) async throws {
            let deadline = ContinuousClock.now + .seconds(10)
            while !(await condition()) {
                guard ContinuousClock.now < deadline else {
                    throw MiraError(.timeout, "The memory settings condition was not reached.")
                }
                try await Task.sleep(for: .milliseconds(5))
            }
        }
    }

    private actor SettingsTestEmbedding: MemoryEmbeddingService {
        nonisolated let identity = MemoryEmbeddingIdentity(fingerprint: "settings-test", dimensions: 1)
        private(set) var statusCallCount = 0
        private(set) var prepareCallCount = 0

        func status() -> MemoryEmbeddingStatus {
            statusCallCount += 1
            return .ready
        }

        func prepare() async throws { prepareCallCount += 1 }

        func embed(_ input: MemoryEmbeddingInput) async throws -> [[Float]] {
            switch input {
            case .query: return [[1]]
            case .documents(let values): return Array(repeating: [1], count: values.count)
            }
        }

        func unload() async {}
        func close() async {}
    }
#endif
