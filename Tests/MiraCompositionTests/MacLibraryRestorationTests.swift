import Foundation
import MiraCore
import MiraData
import Testing

@Suite("macOS library restoration", .timeLimit(.minutes(2)))
struct MacLibraryRestorationTests {
    @Test
    func restoresAClosedCopyWithoutChangingTheCurrentLibrary() async throws {
        try await withRestorationDirectory { root in
            let sourceDirectory = root.appendingPathComponent("Source", isDirectory: true)
            let archive = root.appendingPathComponent("Archive", isDirectory: true)
            let destination = root.appendingPathComponent("Restored", isDirectory: true)
            let library = try await MacLibrary.open(embeddings: OfflineMemoryEmbedding(),
                directory: sourceDirectory, notifications: CompositionNotifications(),
                credentials: CompositionCredentials(), modules: { _ in [] })
            do {
                let sessionID = ConversationID()
                let group = try await library.workloads()
                try committed(
                    await group.application.createSession(
                        id: sessionID, commandID: UUID(), title: "Restoration source", workspaceID: nil))

                _ = try await library.exportArchive(to: archive)
                let current = try await library.workloads()
                #expect(await library.status().phase == .ready)
                #expect(
                    try await current.queries.messagePage(sessionID: sessionID).session?.title.text
                        == "Restoration source")

                let restoration = try MacLibraryRestoration()
                let result = try await restoration.restore(from: archive, to: destination)
                await restoration.close()
                #expect(result.directory == destination)
                #expect(await library.status().phase == .ready)
                let currentAfterRestore = try await library.workloads()
                #expect(
                    try await currentAfterRestore.queries.messagePage(sessionID: sessionID).session?.title.text
                        == "Restoration source")

                let restored = try await MacLibrary.open(embeddings: OfflineMemoryEmbedding(),
                    directory: destination, notifications: CompositionNotifications(),
                    credentials: CompositionCredentials(), modules: { _ in [] })
                do {
                    let restoredGroup = try await restored.workloads()
                    #expect(
                        try await restoredGroup.queries.messagePage(sessionID: sessionID).session?.title.text
                            == "Restoration source")
                    #expect(await restored.close().isSettled)
                } catch {
                    _ = await restored.close()
                    throw error
                }
                _ = await library.close()
            } catch {
                _ = await library.close()
                throw error
            }
        }
    }

    @Test
    func rejectsExistingDestinationAndMalformedArchiveWithoutPublishing() async throws {
        try await withRestorationDirectory { root in
            let archive = root.appendingPathComponent("Malformed", isDirectory: true)
            let existing = root.appendingPathComponent("Existing", isDirectory: true)
            let absent = root.appendingPathComponent("Absent", isDirectory: true)
            try Data("not an archive".utf8).write(to: archive)
            try Data("keep this".utf8).write(to: existing)

            let restoration = try MacLibraryRestoration()
            await #expect(throws: MiraError.self) {
                _ = try await restoration.restore(from: archive, to: existing)
            }
            #expect(try Data(contentsOf: existing) == Data("keep this".utf8))
            await #expect(throws: MiraError.self) {
                _ = try await restoration.restore(from: archive, to: absent)
            }
            #expect(!FileManager.default.fileExists(atPath: absent.path))
            await restoration.close()
            await #expect(throws: MiraError.self) {
                _ = try await restoration.restore(from: archive, to: root.appendingPathComponent("AfterClose"))
            }
        }
    }

    @Test
    func cancellationDoesNotReleaseAnAcceptedRestoreBeforeCoalescedClose() async throws {
        try await withRestorationDirectory { root in
            let sourceDirectory = root.appendingPathComponent("Source", isDirectory: true)
            let archive = root.appendingPathComponent("Archive", isDirectory: true)
            let destination = root.appendingPathComponent("Restored", isDirectory: true)
            let library = try await MacLibrary.open(embeddings: OfflineMemoryEmbedding(),
                directory: sourceDirectory, notifications: CompositionNotifications(),
                credentials: CompositionCredentials(), modules: { _ in [] })
            var gate: RestorationSourceGate?
            var restoring: Task<SQLiteLibraryRestorationResult, Error>?
            var closing: Task<Void, Never>?
            var closingAgain: Task<Void, Never>?
            do {
                let group = try await library.workloads()
                try committed(
                    await group.application.createSession(
                        id: ConversationID(), commandID: UUID(), title: "Gated restoration", workspaceID: nil))
                _ = try await library.exportArchive(to: archive)
                _ = await library.close()

                let sourceGate = RestorationSourceGate()
                gate = sourceGate
                let backend = try SQLiteLibraryRestorer(
                    modules: MacLibraryStorage.archiveModules(),
                    sourceFactory: { context in
                        await sourceGate.enter()
                        return try await MacLibraryRestoration.makeSources(context)
                    })
                let restoration = MacLibraryRestoration(backend: backend)
                restoring = Task {
                    try await restoration.restore(from: archive, to: destination)
                }
                await sourceGate.waitUntilEntered()
                restoring?.cancel()

                let probe = RestorationCloseProbe()
                closing = Task {
                    await restoration.close()
                    await probe.markFinished()
                }
                closingAgain = Task { await restoration.close() }
                await Task.yield()
                #expect(!(await probe.isFinished))
                await sourceGate.release()
                _ = try await restoring!.value
                await closing!.value
                await closingAgain!.value
                #expect(await probe.isFinished)

                await restoration.close()
                await #expect(throws: MiraError.self) {
                    _ = try await restoration.restore(from: archive, to: root.appendingPathComponent("AfterClose"))
                }
            } catch {
                await gate?.release()
                _ = await restoring?.result
                _ = await closing?.result
                _ = await closingAgain?.result
                _ = await library.close()
                throw error
            }
        }
    }

    private func withRestorationDirectory(
        _ operation: (URL) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mira-restoration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try await operation(root)
    }
}

private actor RestorationSourceGate {
    private var entered = false
    private var released = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func enter() async {
        entered = true
        for waiter in enteredWaiters { waiter.resume() }
        enteredWaiters.removeAll()
        if !released {
            await withCheckedContinuation { releaseWaiter = $0 }
        }
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

private actor RestorationCloseProbe {
    private(set) var isFinished = false
    func markFinished() { isFinished = true }
}
