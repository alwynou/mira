import Foundation
import MiraCore
import MiraData
import Testing

@Suite("macOS selected library activation", .timeLimit(.minutes(2)))
@MainActor
struct LibraryActivationTests {
    @Test func activatesRestoredLibraryPersistsSelectionAndReopensTheSelectedDirectory() async throws {
        try await withDirectory { root in
            let fixture = try await makeFixture(root: root)
            let retired = NotificationRetirement()
            let opened = LibraryOpenRecorder()
            let container = makeContainer(fixture: fixture, retired: retired, opened: opened)
            await container.start()
            do {
                try await eventually { container.status.phase == .ready && container.library != nil }
                let target = MacSelectedLibrary(directory: fixture.destination, libraryID: fixture.libraryID)
                try await container.activateRestoredLibrary(target)

                #expect(container.directory.standardizedFileURL == fixture.destination.standardizedFileURL)
                #expect(container.library?.id == fixture.libraryID)
                #expect(container.workgroup != nil)
                let page = try await container.library?.workloads().queries.messagePage(sessionID: fixture.sessionID)
                #expect(page?.session?.title.text == "Activation source")
                #expect(
                    await retired.namespaces == [
                        MacLibraryWorkloads.notificationNamespace(
                            directory: fixture.source, libraryID: fixture.libraryID)
                    ])
                let libraries = await opened.libraries
                #expect(libraries.count == 2)
                #expect(await libraries[0].status().phase == .closed)

                #expect(await container.close().isSettled)
                let selection = try MacLibrarySelectionStore(fileURL: fixture.selectionFile)
                #expect(
                    try await selection.state()
                        == .active(
                            .init(directory: fixture.destination, libraryID: fixture.libraryID)))
                await selection.close()

                let reopened = makeContainer(fixture: fixture, retired: retired, opened: opened)
                await reopened.start()
                do {
                    try await eventually {
                        reopened.status.phase == .ready
                            && reopened.directory.standardizedFileURL == fixture.destination.standardizedFileURL
                    }
                    #expect(reopened.library?.id == fixture.libraryID)
                    #expect(
                        try await reopened.library?.workloads().queries.messagePage(sessionID: fixture.sessionID)
                            .session?.title.text == "Activation source")
                    #expect(await reopened.close().isSettled)
                } catch {
                    _ = await reopened.close()
                    throw error
                }
            } catch {
                _ = await container.close()
                throw error
            }
        }
    }

    @Test func closeWaitsForGatedRetirementBeforeOpeningTheTarget() async throws {
        try await withDirectory { root in
            let fixture = try await makeFixture(root: root)
            let retired = NotificationRetirement()
            await retired.setGated(true)
            let opened = LibraryOpenRecorder()
            let container = makeContainer(fixture: fixture, retired: retired, opened: opened)
            await container.start()
            var activation: Task<Void, Error>?
            do {
                if let error = container.startupError { throw error }
                #expect(container.status.phase == .ready)
                let target = MacSelectedLibrary(directory: fixture.destination, libraryID: fixture.libraryID)
                activation = Task { try await container.activateRestoredLibrary(target) }
                await retired.waitUntilEntered()
                #expect(await opened.count == 1)
                #expect(await opened.contains(directory: fixture.destination) == false)

                let probe = CloseProbe()
                let closing = Task {
                    _ = await container.close()
                    await probe.finish()
                }
                try await eventually { container.status.phase == .closing }
                #expect(await probe.finished == false)
                #expect(await opened.contains(directory: fixture.destination) == false)

                await retired.release()
                if let activation { _ = try? await activation.value }
                await closing.value
                #expect(await probe.finished)
                #expect(await container.status.phase == .closed)
                #expect(container.library == nil)
                for library in await opened.libraries {
                    #expect(await library.status().phase == .closed)
                }
            } catch {
                await retired.release()
                _ = await activation?.result
                _ = await container.close()
                throw error
            }
        }
    }

    @Test func retirementFailureLeavesPendingSelectionAndRestartCompletesWithoutReopeningSource() async throws {
        try await withDirectory { root in
            let fixture = try await makeFixture(root: root)
            let retired = NotificationRetirement()
            await retired.setFailure(true)
            let opened = LibraryOpenRecorder()
            let container = makeContainer(fixture: fixture, retired: retired, opened: opened)
            await container.start()
            do {
                if let error = container.startupError { throw error }
                #expect(container.status.phase == .ready)
                let target = MacSelectedLibrary(directory: fixture.destination, libraryID: fixture.libraryID)
                await #expect(throws: MiraError.self) {
                    try await container.activateRestoredLibrary(target)
                }
                #expect(await container.status.phase == .failed)
                #expect(container.library == nil)
                #expect(await opened.count == 1)
                let libraries = await opened.libraries
                #expect(await libraries[0].status().phase == .closed)
                #expect(await container.close().isSettled)

                let selection = try MacLibrarySelectionStore(fileURL: fixture.selectionFile)
                #expect(
                    try await selection.state()
                        == .switching(
                            from: .init(directory: fixture.source, libraryID: fixture.libraryID), to: target))
                await selection.close()

                await retired.setFailure(false)
                let restarted = makeContainer(fixture: fixture, retired: retired, opened: opened)
                await restarted.start()
                do {
                    try await eventually {
                        restarted.status.phase == .ready
                            && restarted.directory.standardizedFileURL == fixture.destination.standardizedFileURL
                    }
                    #expect(restarted.library?.id == fixture.libraryID)
                    #expect(await opened.count == 2)
                    #expect(await opened.libraries[0].status().phase == .closed)
                    #expect(await restarted.close().isSettled)
                } catch {
                    _ = await restarted.close()
                    throw error
                }
            } catch {
                _ = await container.close()
                throw error
            }
        }
    }

    @Test func wrongExpectedLibraryIDFailsWithoutFallbackOrPublishedReplacement() async throws {
        try await withDirectory { root in
            let fixture = try await makeFixture(root: root)
            let retired = NotificationRetirement()
            let opened = LibraryOpenRecorder()
            let container = makeContainer(fixture: fixture, retired: retired, opened: opened)
            await container.start()
            do {
                if let error = container.startupError { throw error }
                #expect(container.status.phase == .ready)
                let wrong = MacSelectedLibrary(directory: fixture.destination, libraryID: UUID())
                await #expect(throws: MiraError.self) {
                    try await container.activateRestoredLibrary(wrong)
                }
                #expect(await container.status.phase == .failed)
                #expect(container.library == nil)
                #expect(container.workgroup == nil)
                // MacLibrary.open rejects the mismatched identity before returning a library.
                #expect(await opened.count == 1)
                let libraries = await opened.libraries
                for library in libraries {
                    #expect(await library.status().phase == .closed)
                }
                #expect(await container.close().isSettled)

                let selection = try MacLibrarySelectionStore(fileURL: fixture.selectionFile)
                #expect(
                    try await selection.state()
                        == .switching(
                            from: .init(directory: fixture.source, libraryID: fixture.libraryID), to: wrong))
                await selection.close()
            } catch {
                _ = await container.close()
                throw error
            }
        }
    }

    private func makeContainer(
        fixture: ActivationFixture, retired: NotificationRetirement, opened: LibraryOpenRecorder
    ) -> AppContainer {
        let launch = MacLibraryLaunchConfiguration(
            directory: fixture.source, isDemo: false, stress: false, selectionFile: fixture.selectionFile)
        return AppContainer(
            launch: launch,
            retireNotifications: { namespace in try await retired.retire(namespace) },
            opener: { launch in
                let library = try await MacLibrary.open(embeddings: OfflineMemoryEmbedding(),
                    directory: launch.directory, expectedLibraryID: launch.expectedLibraryID,
                    notifications: CompositionNotifications(), credentials: CompositionCredentials(),
                    modules: { _ in [] })
                await opened.record(library)
                return library
            })
    }

    private func makeFixture(root: URL) async throws -> ActivationFixture {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let source = root.appendingPathComponent("Source", isDirectory: true)
        let archive = root.appendingPathComponent("Archive", isDirectory: true)
        let destination = root.appendingPathComponent("Restored", isDirectory: true)
        let selectionFile = root.appendingPathComponent("Host/selection.json")
        let sourceLibrary = try await MacLibrary.open(embeddings: OfflineMemoryEmbedding(),
            directory: source, notifications: CompositionNotifications(),
            credentials: CompositionCredentials(), modules: { _ in [] })
        let sessionID = ConversationID()
        let libraryID = sourceLibrary.id
        do {
            let group = try await sourceLibrary.workloads()
            try committed(
                await group.application.createSession(
                    id: sessionID, commandID: UUID(), title: "Activation source", workspaceID: nil))
            _ = try await sourceLibrary.exportArchive(to: archive)
            #expect(await sourceLibrary.close().isSettled)
        } catch {
            _ = await sourceLibrary.close()
            throw error
        }

        let restoration = try MacLibraryRestoration()
        do {
            let result = try await restoration.restore(from: archive, to: destination)
            #expect(result.directory == destination)
            #expect(result.authorization.libraryID == libraryID)
            await restoration.close()
        } catch {
            await restoration.close()
            throw error
        }
        return .init(
            source: source, destination: destination, archive: archive,
            selectionFile: selectionFile, libraryID: libraryID, sessionID: sessionID)
    }
}

private struct ActivationFixture: Sendable {
    let source: URL
    let destination: URL
    let archive: URL
    let selectionFile: URL
    let libraryID: UUID
    let sessionID: ConversationID
}

private actor LibraryOpenRecorder {
    private(set) var libraries: [MacLibrary] = []

    var count: Int { libraries.count }

    func record(_ library: MacLibrary) { libraries.append(library) }

    func contains(directory: URL) -> Bool {
        libraries.contains { $0.directory.standardizedFileURL == directory.standardizedFileURL }
    }
}

private actor NotificationRetirement {
    private(set) var namespaces: [String] = []
    private var gated = false
    private var failure = false
    private var entered = false
    private var released = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func setGated(_ value: Bool) { gated = value }
    func setFailure(_ value: Bool) { failure = value }

    func retire(_ namespace: String) async throws {
        namespaces.append(namespace)
        entered = true
        for waiter in enteredWaiters { waiter.resume() }
        enteredWaiters.removeAll()
        if gated && !released {
            await withCheckedContinuation { releaseWaiter = $0 }
        }
        if failure { throw MiraError(.storage, "Synthetic notification retirement failed.") }
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

private actor CloseProbe {
    private(set) var finished = false
    func finish() { finished = true }
}
