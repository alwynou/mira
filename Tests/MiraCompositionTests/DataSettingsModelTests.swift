import Foundation
import MiraCore
import MiraData
import Testing

@Suite("Data settings model", .timeLimit(.minutes(2)))
@MainActor
struct DataSettingsModelTests {
    @Test func exportsAndRestoresAnIndependentLibraryWhileSourceRemainsReady() async throws {
        try await withDirectory { root in
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            let source = root.appendingPathComponent("Source", isDirectory: true)
            let archive = root.appendingPathComponent("Archive", isDirectory: true)
            let destination = root.appendingPathComponent("Restored", isDirectory: true)
            let container = makeContainer(directory: source)
            await container.start()
            let model = DataSettingsModel(container: container)
            do {
                try await eventually { container.status.phase == .ready && container.library != nil }
                let sessionID = ConversationID()
                let group = try #require(container.workgroup)
                try committed(
                    await group.application.createSession(
                        id: sessionID, commandID: UUID(), title: "Data settings source", workspaceID: nil))

                model.startExport(to: archive)
                await model.waitForAction()
                #expect(model.statusKey == "Backup saved.")
                #expect(model.error == nil)
                #expect(container.status.phase == .ready)
                #expect(
                    try await container.library?.workloads().queries.messagePage(sessionID: sessionID).session?.title
                        .text
                        == "Data settings source")

                model.startRestore(from: archive, to: destination)
                await model.waitForAction()
                #expect(model.statusKey == "Backup verified and restored to a separate library.")
                #expect(model.restoredDirectory == destination)
                #expect(model.error == nil)
                #expect(container.status.phase == .ready)
                #expect(
                    try await container.library?.workloads().queries.messagePage(sessionID: sessionID).session?.title
                        .text
                        == "Data settings source")

                let restored = try await MacLibrary.open(embeddings: OfflineMemoryEmbedding(),
                    directory: destination, notifications: CompositionNotifications(),
                    credentials: CompositionCredentials(), modules: { _ in [] })
                do {
                    #expect(
                        try await restored.workloads().queries.messagePage(sessionID: sessionID).session?.title.text
                            == "Data settings source")
                    #expect(await restored.close().isSettled)
                } catch {
                    _ = await restored.close()
                    throw error
                }
                #expect(await container.close().isSettled)
            } catch {
                _ = await container.close()
                throw error
            }
        }
    }

    @Test func cleanupReplacesTheWorkgroupAndPublishesNoSyntheticCount() async throws {
        try await withDirectory { directory in
            let container = makeContainer(directory: directory)
            await container.start()
            let model = DataSettingsModel(container: container)
            let observing = Task { await model.observe() }
            do {
                try await eventually { container.status.phase == .ready && model.diagnostics != nil }
                let before = container.status.generation
                model.cleanupFiles()
                await model.waitForAction()
                try await eventually {
                    !model.isWorking && model.statusKey == "Unreferenced file cleanup completed."
                }
                try await eventually {
                    container.status.phase == .ready && container.status.generation > before
                        && model.diagnostics != nil
                }
                #expect(model.error == nil)
                #expect(model.statusKey == "Unreferenced file cleanup completed.")
                observing.cancel()
                await observing.value
                #expect(await container.close().isSettled)
            } catch {
                observing.cancel()
                await observing.value
                _ = await container.close()
                throw error
            }
        }
    }

    @Test func clearingTheWindowDoesNotCancelAcceptedRestoreAndCloseDrainsIt() async throws {
        try await withDirectory { directory in
            let backend = GatedRestorationBackend()
            let launch = MacLibraryLaunchConfiguration(directory: directory, isDemo: false, stress: false)
            let container = AppContainer(
                launch: launch,
                makeRestoration: { MacLibraryRestoration(backend: backend) },
                opener: { launch in
                    try await MacLibrary.open(embeddings: OfflineMemoryEmbedding(),
                        directory: launch.directory, notifications: CompositionNotifications(),
                        credentials: CompositionCredentials(), modules: { _ in [] })
                })
            await container.start()
            let model = DataSettingsModel(container: container)
            let archive = directory.appendingPathComponent("SyntheticArchive", isDirectory: true)
            try Data("accepted restore".utf8).write(to: archive)
            let destination = directory.deletingLastPathComponent().appendingPathComponent("SyntheticRestored")
            do {
                try await eventually { container.status.phase == .ready }
                model.startRestore(from: archive, to: destination)
                await backend.waitUntilEntered()
                #expect(await backend.calls == 1)

                model.clearResults()
                #expect(model.isWorking)
                model.startRestore(from: archive, to: destination)
                #expect(await backend.calls == 1)

                let closing = Task { await container.close() }
                try await eventually { container.status.phase == .closing }
                #expect(await backend.wasClosed == false)
                #expect(model.isWorking)

                await backend.release()
                await model.waitForAction()
                #expect(await closing.value.isSettled)
                #expect(await backend.wasClosed)
                #expect(container.status.phase == .closed)
            } catch {
                await backend.release()
                _ = await container.close()
                throw error
            }
        }
    }

    private func makeContainer(directory: URL) -> AppContainer {
        let launch = MacLibraryLaunchConfiguration(directory: directory, isDemo: false, stress: false)
        return AppContainer(
            launch: launch,
            opener: { launch in
                try await MacLibrary.open(embeddings: OfflineMemoryEmbedding(),
                    directory: launch.directory, notifications: CompositionNotifications(),
                    credentials: CompositionCredentials(), modules: { _ in [] })
            })
    }
}

private actor GatedRestorationBackend: MacLibraryRestorationBackend {
    private(set) var calls = 0
    private(set) var wasClosed = false
    private var entered = false
    private var released = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func restore(from archive: URL, to destination: URL) async throws -> SQLiteLibraryRestorationResult {
        calls += 1
        entered = true
        for waiter in enteredWaiters { waiter.resume() }
        enteredWaiters.removeAll()
        if !released {
            await withCheckedContinuation { releaseWaiter = $0 }
        }
        throw MiraError(.cancelled, "Synthetic restoration finished without publication.")
    }

    func close() {
        wasClosed = true
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}
