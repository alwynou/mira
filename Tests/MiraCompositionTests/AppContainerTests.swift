import AppKit
import Foundation
import MiraCore
import Testing

@Suite("macOS app container", .timeLimit(.minutes(1)))
struct AppContainerTests {
    @Test @MainActor
    func appKitTerminationDrainsLateStartupAndRepliesOnce() async throws {
        try await withDirectory { directory in
            let gate = LibraryOpenGate()
            let returned = ReturnedLibrary()
            let launch = MacLibraryLaunchConfiguration(directory: directory, isDemo: true, stress: false)
            let container = AppContainer(launch: launch) { launch in
                await gate.wait()
                let library = try await Task { try await Self.openLibrary(launch) }.value
                await returned.record(library)
                return library
            }
            let delegate = MiraAppDelegate()
            delegate.container = container
            var confirmations = 0
            delegate.confirmUnsettledClose = { _ in
                confirmations += 1
                return false
            }
            var replies: [Bool] = []
            let startup = Task { await container.start() }
            do {
                try await eventually { await gate.entered }
                #expect(delegate.requestTermination { replies.append($0) } == .terminateLater)
                #expect(
                    delegate.requestTermination { _ in Issue.record("Duplicate termination replied.") }
                        == .terminateLater)
                try await eventually { container.status.phase == .closing }
                #expect(replies.isEmpty)
                await gate.release()
                await startup.value
                try await eventually { replies == [true] }
                #expect(confirmations == 0)
                let late = try #require(await returned.value)
                #expect(await late.status().phase == .closed)
                #expect(container.library == nil)
                let reopened = try await Self.openLibrary(launch)
                #expect(await reopened.close().isSettled)
            } catch {
                await gate.release()
                await startup.value
                _ = await container.close()
                throw error
            }
        }
    }

    @Test @MainActor
    func startOutlivesCallerCancellationAndDeduplicatesOpening() async throws {
        try await withDirectory { directory in
            let launch = MacLibraryLaunchConfiguration(directory: directory, isDemo: true, stress: false)
            let gate = LibraryOpenGate()
            let calls = OpenCallCounter()
            let container = AppContainer(launch: launch) { launch in
                await calls.record()
                await gate.wait()
                return try await Self.openLibrary(launch)
            }
            do {
                let first = Task { await container.start() }
                try await eventually { await gate.entered }
                let second = Task { await container.start() }
                first.cancel()
                await gate.release()
                await first.value
                await second.value

                #expect(await calls.value == 1)
                #expect(container.library != nil)
                #expect(container.workgroup != nil)
                #expect(container.status.phase == .ready)
                #expect(container.status.generation == 1)
                #expect(await container.close().isSettled)
            } catch {
                await gate.release()
                _ = await container.close()
                throw error
            }
        }
    }

    @Test @MainActor
    func closeDrainsOpeningAndDoesNotPublishAWorkgroupAfterCloseBegins() async throws {
        try await withDirectory { directory in
            let launch = MacLibraryLaunchConfiguration(directory: directory, isDemo: true, stress: false)
            let gate = LibraryOpenGate()
            let returned = ReturnedLibrary()
            let container = AppContainer(launch: launch) { launch in
                await gate.wait()
                // Keep the actual open independent of the cancelled opener task.
                let task = Task { try await Self.openLibrary(launch) }
                let library = try await task.value
                await returned.record(library)
                return library
            }
            do {
                let starting = Task { await container.start() }
                try await eventually { await gate.entered }
                let closing = Task { await container.close() }
                try await eventually { container.status.phase == .closing }
                #expect(container.workgroup == nil)
                #expect(container.status.phase != .closed)

                await gate.release()
                await starting.value
                let result = await closing.value
                #expect(result.isSettled)
                #expect(container.library == nil)
                #expect(container.workgroup == nil)
                #expect(container.status.phase == .closed)
                let lateLibrary = try #require(await returned.value)
                #expect((await lateLibrary.status()).phase == .closed)

                // The late opener must have released the database before a new owner opens it.
                let reopened = try await Self.openLibrary(launch)
                #expect(await reopened.close().isSettled)
            } catch {
                await gate.release()
                _ = await container.close()
                if let lateLibrary = await returned.value {
                    _ = await lateLibrary.close()
                }
                throw error
            }
        }
    }

    @Test @MainActor
    func maintenanceReplacesGenerationAndClosesTheOldWorkgroup() async throws {
        try await withDirectory { directory in
            let launch = MacLibraryLaunchConfiguration(directory: directory, isDemo: true, stress: false)
            let container = AppContainer(launch: launch) { launch in
                try await Self.openLibrary(launch)
            }
            do {
                await container.start()
                let library = try #require(container.library)
                let old = try #require(container.workgroup)
                let request = AgentLibraryMaintenanceRequest(
                    id: UUID(), namespace: "knowledge.collect", revision: 1,
                    scope: .library, requestedAt: Date())

                _ = try await library.maintain(request)
                try await eventually {
                    container.status.phase == .ready && container.status.generation == 2
                        && container.workgroup != nil
                }

                let replacement = try #require(container.workgroup)
                #expect(old !== replacement)
                #expect(await old.status().isClosed)
                await #expect(throws: MiraError.self) {
                    _ = try await old.queries.sessions()
                }
                #expect(container.library === library)
                #expect(await container.close().isSettled)
            } catch {
                _ = await container.close()
                throw error
            }
        }
    }

    @Test @MainActor
    func startupFailureIsPublishedWithoutAWorkgroup() async throws {
        let launch = MacLibraryLaunchConfiguration(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent(
                "mira-app-container-failure-\(UUID())"),
            isDemo: true, stress: false)
        let container = AppContainer(launch: launch) { _ in
            throw MiraError(.storage, "Synthetic opener failure.")
        }

        await container.start()
        #expect(container.library == nil)
        #expect(container.workgroup == nil)
        #expect(container.status.phase == .failed)
        #expect(container.startupError != nil)
        #expect(await container.close().isSettled)
    }

    @Test
    func launchResolutionRejectsUnsafeOrAmbiguousArguments() throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("mira-support-\(UUID())")
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("mira-demo-\(UUID())")
        let explicit = support.appendingPathComponent("Chosen")
        let resolved = try MacLibraryLaunchConfiguration.resolve(
            arguments: ["Mira", "--data-directory", explicit.path], bundleID: nil,
            applicationSupport: support, temporaryDirectory: temporary)
        #expect(resolved.directory.path == explicit.standardizedFileURL.path)
        #expect(!resolved.isDemo)

        let demo = try MacLibraryLaunchConfiguration.resolve(
            arguments: ["Mira", "--demo"], bundleID: nil,
            applicationSupport: support, temporaryDirectory: temporary)
        #expect(demo.isDemo)
        #expect(!demo.benchmark)
        #expect(demo.directory.path.hasPrefix(temporary.standardizedFileURL.path))

        #expect(throws: MiraError.self) {
            _ = try MacLibraryLaunchConfiguration.resolve(
                arguments: ["Mira", "--data-directory", "relative"], bundleID: nil,
                applicationSupport: support, temporaryDirectory: temporary)
        }
        #expect(throws: MiraError.self) {
            _ = try MacLibraryLaunchConfiguration.resolve(
                arguments: ["Mira", "--data-directory", "/tmp/one", "--data-directory", "/tmp/two"],
                bundleID: nil, applicationSupport: support, temporaryDirectory: temporary)
        }
        #expect(throws: MiraError.self) {
            _ = try MacLibraryLaunchConfiguration.resolve(
                arguments: ["Mira", "--demo-stress"], bundleID: nil,
                applicationSupport: support, temporaryDirectory: temporary)
        }
    }

    @Test
    func benchmarkRequiresExplicitDemoAndFreshAbsolutePaths() throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("mira-support-\(UUID())")
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("mira-demo-\(UUID())")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mira-benchmark-\(UUID())")
        let report = FileManager.default.temporaryDirectory.appendingPathComponent("mira-report-\(UUID()).json")
        let existingDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("mira-existing-\(UUID())")
        let existingReport = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mira-existing-report-\(UUID()).json")
        try FileManager.default.createDirectory(at: existingDirectory, withIntermediateDirectories: true)
        try Data("existing".utf8).write(to: existingReport)
        defer {
            try? FileManager.default.removeItem(at: existingDirectory)
            try? FileManager.default.removeItem(at: existingReport)
            try? FileManager.default.removeItem(at: report)
        }

        #expect(throws: MiraError.self) {
            _ = try MacLibraryLaunchConfiguration.resolve(
                arguments: [
                    "Mira", "--native-rendering-benchmark", "--data-directory", directory.path,
                    "--benchmark-report", report.path,
                ],
                bundleID: nil, applicationSupport: support, temporaryDirectory: temporary)
        }
        #expect(throws: MiraError.self) {
            _ = try MacLibraryLaunchConfiguration.resolve(
                arguments: ["Mira", "--demo", "--native-rendering-benchmark", "--data-directory", directory.path],
                bundleID: nil, applicationSupport: support, temporaryDirectory: temporary)
        }
        #expect(throws: MiraError.self) {
            _ = try MacLibraryLaunchConfiguration.resolve(
                arguments: [
                    "Mira", "--demo", "--native-rendering-benchmark", "--data-directory", existingDirectory.path,
                    "--benchmark-report", report.path,
                ],
                bundleID: nil, applicationSupport: support, temporaryDirectory: temporary)
        }
        #expect(throws: MiraError.self) {
            _ = try MacLibraryLaunchConfiguration.resolve(
                arguments: [
                    "Mira", "--demo", "--native-rendering-benchmark", "--data-directory", directory.path,
                    "--benchmark-report", existingReport.path,
                ],
                bundleID: nil, applicationSupport: support, temporaryDirectory: temporary)
        }
        #expect(throws: MiraError.self) {
            _ = try MacLibraryLaunchConfiguration.resolve(
                arguments: ["Mira"], bundleID: "com.alwynou.mira.performance-check",
                applicationSupport: support, temporaryDirectory: temporary)
        }
    }

    private static func openLibrary(_ launch: MacLibraryLaunchConfiguration) async throws -> MacLibrary {
        try await MacLibrary.open(embeddings: OfflineMemoryEmbedding(),
            directory: launch.directory, notifications: CompositionNotifications(),
            credentials: CompositionCredentials(), modules: { _ in [] })
    }
}

private actor LibraryOpenGate {
    private(set) var entered = false
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        entered = true
        guard !released else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        released = true
        let waiters = waiters
        self.waiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

private actor OpenCallCounter {
    private(set) var value = 0
    func record() { value += 1 }
}

private actor ReturnedLibrary {
    private var library: MacLibrary?

    func record(_ library: MacLibrary) { self.library = library }
    var value: MacLibrary? { library }
}
