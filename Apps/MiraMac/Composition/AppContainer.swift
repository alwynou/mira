import Foundation
import MiraCore
import Observation

/// Launch policy is resolved before any library or platform adapter is opened.
struct MacLibraryLaunchConfiguration: Sendable, Equatable {
    let directory: URL
    let isDemo: Bool
    let stress: Bool
    let benchmark: Bool
    let selectionFile: URL?
    let expectedLibraryID: UUID?

    init(
        directory: URL, isDemo: Bool, stress: Bool, benchmark: Bool = false,
        selectionFile: URL? = nil, expectedLibraryID: UUID? = nil
    ) {
        self.directory = directory
        self.isDemo = isDemo
        self.stress = stress
        self.benchmark = benchmark
        self.selectionFile = selectionFile
        self.expectedLibraryID = expectedLibraryID
    }

    static func resolve(
        arguments: [String], bundleID: String?,
        applicationSupport: URL, temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) throws -> Self {
        #if DEBUG
            let demo = arguments.contains("--demo")
        #else
            guard
                !arguments.contains(where: { ["--demo", "--demo-stress", "--native-rendering-benchmark"].contains($0) })
            else {
                throw MiraError(.configuration, "Demo mode is unavailable in this build. No library was opened.")
            }
            let demo = false
        #endif
        let explicitDirectory = try absoluteArgument("--data-directory", arguments: arguments)
        let directory =
            explicitDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? (demo
                ? temporaryDirectory.appendingPathComponent("Mira-Demo-\(UUID().uuidString)", isDirectory: true)
                : applicationSupport.appendingPathComponent("Mira", isDirectory: true))
        #if DEBUG
            if bundleID?.hasPrefix("com.alwynou.mira.performance-check") == true, !demo {
                throw MiraError(
                    .configuration, "The performance fixture requires explicit demo arguments. No library was opened.")
            }
            if arguments.contains("--demo-stress"), !demo {
                throw MiraError(
                    .configuration, "The rendering stress fixture requires demo mode. No library was opened.")
            }
            if arguments.contains("--native-rendering-benchmark") {
                let report = try absoluteArgument("--benchmark-report", arguments: arguments)
                guard demo, explicitDirectory != nil, let report,
                    !FileManager.default.fileExists(atPath: directory.path),
                    !FileManager.default.fileExists(atPath: report),
                    FileManager.default.isWritableFile(
                        atPath: URL(fileURLWithPath: report).deletingLastPathComponent().path)
                else {
                    throw MiraError(
                        .configuration,
                        "The rendering benchmark requires demo mode, absolute paths, and a new fixture directory. No library was opened."
                    )
                }
            }
        #endif
        return .init(
            directory: directory.standardizedFileURL, isDemo: demo, stress: demo && arguments.contains("--demo-stress"),
            benchmark: demo && arguments.contains("--native-rendering-benchmark"),
            selectionFile: explicitDirectory == nil && !demo
                ? applicationSupport.appendingPathComponent("MiraHost", isDirectory: true)
                    .appendingPathComponent("library-selection.json") : nil)
    }

    private static func absoluteArgument(_ flag: String, arguments: [String]) throws -> String? {
        let indices = arguments.indices.filter { arguments[$0] == flag }
        guard !indices.isEmpty else { return nil }
        guard indices.count == 1, let index = indices.first,
            arguments.indices.contains(index + 1), arguments[index + 1].hasPrefix("/")
        else {
            throw MiraError(.configuration, "Launch paths must be absolute and specified once. No library was opened.")
        }
        return arguments[index + 1]
    }
}

/// App-lifetime ownership only. Views use the current work group's domain services.
@MainActor @Observable
final class AppContainer {
    typealias LibraryOpener = @Sendable (MacLibraryLaunchConfiguration) async throws -> MacLibrary

    private(set) var directory: URL
    let isDemo: Bool
    private(set) var status: MacLibraryStatus
    private(set) var library: MacLibrary?
    private(set) var workgroup: MacLibraryWorkloads?
    private(set) var restoration: MacLibraryRestoration?
    var startupError: MiraError? { status.failure }
    @ObservationIgnored private let launch: MacLibraryLaunchConfiguration?
    @ObservationIgnored private let opener: LibraryOpener
    @ObservationIgnored private let makeRestoration: @Sendable () throws -> MacLibraryRestoration
    @ObservationIgnored private let retireNotifications: @Sendable (String) async throws -> Void
    @ObservationIgnored private var selection: MacLibrarySelectionStore?
    @ObservationIgnored private var switching: Task<Void, any Error>?
    @ObservationIgnored private var unsettledClose: MacLibraryCloseResult?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var opening: Task<Void, Never>?
    @ObservationIgnored private var observation: Task<Void, Never>?
    @ObservationIgnored private var closing: Task<MacLibraryCloseResult, Never>?

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        do {
            let launch = try MacLibraryLaunchConfiguration.resolve(
                arguments: ProcessInfo.processInfo.arguments, bundleID: Bundle.main.bundleIdentifier,
                applicationSupport: support)
            self.launch = launch
            directory = launch.directory
            isDemo = launch.isDemo
            status = .init(phase: .starting, generation: 0, failure: nil)
        } catch {
            launch = nil
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("Mira-Invalid-Launch")
            isDemo = false
            status = .init(phase: .failed, generation: 0, failure: MiraError.safe(error))
        }
        opener = Self.openLibrary
        makeRestoration = { try MacLibraryRestoration() }
        retireNotifications = { try await MacLocalNotifications.retireNotificationNamespace($0) }
    }

    /// Tests explicitly inject the same production library with synthetic adapters.
    init(
        launch: MacLibraryLaunchConfiguration,
        makeRestoration: @escaping @Sendable () throws -> MacLibraryRestoration = { try MacLibraryRestoration() },
        retireNotifications: @escaping @Sendable (String) async throws -> Void = { _ in
            throw MiraError(.unsupported, "Notification retirement requires an explicit host adapter.")
        },
        opener: @escaping LibraryOpener
    ) {
        self.launch = launch
        self.opener = opener
        self.makeRestoration = makeRestoration
        self.retireNotifications = retireNotifications
        directory = launch.directory
        isDemo = launch.isDemo
        status = .init(phase: .starting, generation: 0, failure: nil)
    }

    /// Once accepted, startup outlives any individual window's task.
    func start() async {
        if let opening {
            await opening.value
            return
        }
        guard !started, closing == nil, let launch else { return }
        started = true
        let task = Task {
            defer { opening = nil }
            do {
                restoration = try makeRestoration()
                var requested = launch
                var pending: MacLibrarySelectionState?
                if let file = launch.selectionFile {
                    let store = try await Task.detached { try MacLibrarySelectionStore(fileURL: file) }.value
                    selection = store
                    switch try await store.state() {
                    case .active(let selected): requested = configuration(for: selected)
                    case .switching(let from, let to):
                        pending = .switching(from: from, to: to)
                        try await retireNotifications(Self.namespace(from))
                        requested = configuration(for: to)
                    case nil: break
                    }
                }
                let value = try await openVerified(requested)
                library = value
                directory = value.directory
                if let pending, case .switching(_, let to) = pending {
                    try await selection?.complete(expected: pending, state: .active(to))
                }
                // Close owns any library that finishes opening after close was requested.
                guard closing == nil else { return }
                await receive(await value.status(), from: value)
                guard closing == nil else { return }
                observation = Task { [weak self, value] in
                    for await state in await value.observe() {
                        guard !Task.isCancelled else { break }
                        await self?.receive(state, from: value)
                    }
                }
            } catch {
                await closeAndRecord(library)
                library = nil
                guard closing == nil else { return }
                status = .init(phase: .failed, generation: 0, failure: MiraError.safe(error))
            }
        }
        opening = task
        await task.value
    }

    func close() async -> MacLibraryCloseResult {
        if let closing { return await closing.value }
        status = .init(phase: .closing, generation: status.generation, failure: status.failure)
        workgroup = nil
        let opening = opening
        let switching = switching
        opening?.cancel()
        let task = Task {
            await opening?.value
            _ = await switching?.result
            observation?.cancel()
            await observation?.value
            observation = nil
            let current = library
            library = nil
            let libraryClose = Task { await current?.close() ?? .init(executionsSettled: true, storageError: nil) }
            await restoration?.close()
            restoration = nil
            let currentResult = await libraryClose.value
            let result = MacLibraryCloseResult(
                executionsSettled: currentResult.executionsSettled && (unsettledClose?.executionsSettled ?? true),
                storageError: unsettledClose?.storageError ?? currentResult.storageError)
            await selection?.close()
            selection = nil
            status = .init(phase: .closed, generation: status.generation, failure: result.storageError)
            return result
        }
        closing = task
        return await task.value
    }

    var canActivateRestoredLibrary: Bool {
        selection != nil && !isDemo && opening == nil && closing == nil && switching == nil && status.phase == .ready
    }

    /// The selection intent reaches disk before any old-library platform resource is retired.
    /// An accepted switch outlives its caller and is drained by application close.
    func activateRestoredLibrary(_ target: MacSelectedLibrary) async throws {
        try Task.checkCancellation()
        guard canActivateRestoredLibrary, let selection, let previous = library,
            previous.directory.standardizedFileURL != target.directory.standardizedFileURL
        else {
            throw MiraError(.busy, "The library cannot be switched right now.")
        }
        let source = MacSelectedLibrary(directory: previous.directory, libraryID: previous.id)
        status = .init(phase: .maintaining, generation: status.generation, failure: nil)
        workgroup = nil
        let oldObservation = observation
        observation = nil
        oldObservation?.cancel()
        let task = Task {
            defer { switching = nil }
            await oldObservation?.value
            do {
                let pending = try await selection.begin(from: source, to: target)
                let result = await previous.close()
                recordClose(result)
                library = nil
                guard result.isSettled else {
                    throw result.storageError
                        ?? MiraError(.storage, "Library executions did not settle before switching.")
                }
                try await retireNotifications(Self.namespace(source))
                let next = try await openVerified(configuration(for: target))
                library = next
                directory = next.directory
                try await selection.complete(expected: pending, state: .active(target))
                guard closing == nil else { return }
                await receive(await next.status(), from: next)
                guard closing == nil else { return }
                observation = Task { [weak self, next] in
                    for await state in await next.observe() {
                        guard !Task.isCancelled else { break }
                        await self?.receive(state, from: next)
                    }
                }
            } catch {
                await closeAndRecord(previous)
                await closeAndRecord(library)
                library = nil
                workgroup = nil
                let failure = MiraError.safe(error)
                if closing == nil {
                    status = .init(phase: .failed, generation: status.generation, failure: failure)
                }
                throw failure
            }
        }
        switching = task
        try await task.value
    }

    private func configuration(for selected: MacSelectedLibrary) -> MacLibraryLaunchConfiguration {
        .init(
            directory: selected.directory, isDemo: false, stress: false,
            selectionFile: launch?.selectionFile, expectedLibraryID: selected.libraryID)
    }

    private func openVerified(_ configuration: MacLibraryLaunchConfiguration) async throws -> MacLibrary {
        let opened = try await opener(configuration)
        if let expected = configuration.expectedLibraryID, opened.id != expected {
            await closeAndRecord(opened)
            throw MiraError(.storage, "The selected library identity does not match its saved selection.")
        }
        return opened
    }

    private func closeAndRecord(_ library: MacLibrary?) async {
        guard let library else { return }
        recordClose(await library.close())
    }

    private func recordClose(_ result: MacLibraryCloseResult) {
        guard !result.isSettled else { return }
        unsettledClose = .init(
            executionsSettled: result.executionsSettled && (unsettledClose?.executionsSettled ?? true),
            storageError: unsettledClose?.storageError ?? result.storageError)
    }

    private static func namespace(_ selected: MacSelectedLibrary) -> String {
        MacLibraryWorkloads.notificationNamespace(directory: selected.directory, libraryID: selected.libraryID)
    }

    private func receive(_ state: MacLibraryStatus, from library: MacLibrary) async {
        guard closing == nil, self.library === library else { return }
        if state.phase == .ready {
            do {
                let binding = try await library.binding()
                guard closing == nil, self.library === library else { return }
                workgroup = binding.workgroup
                status = binding.status
            } catch {
                guard closing == nil else { return }
                workgroup = nil
                let current = await library.status()
                guard closing == nil, self.library === library else { return }
                status =
                    current.phase == .ready
                    ? .init(phase: .failed, generation: current.generation, failure: MiraError.safe(error)) : current
            }
        } else {
            workgroup = nil
            status = state
        }
    }

    private nonisolated static func openLibrary(_ launch: MacLibraryLaunchConfiguration) async throws -> MacLibrary {
        #if DEBUG
            if launch.isDemo {
                let library = try await MacLibrary.open(
                    directory: launch.directory, expectedLibraryID: launch.expectedLibraryID,
                    notifications: DemoLocalNotifications(),
                    credentials: DemoCredentials(),
                    modules: { registry in
                        var modules: [any RuntimeModule] = [MacDemoModule(registry: registry, stress: launch.stress)]
                        if launch.benchmark {
                            modules.append(MacBenchmarkModule(registry: registry, stress: launch.stress))
                        }
                        return modules
                    })
                do {
                    try await MacDemoModule.seed(in: library.workloads())
                    return library
                } catch {
                    _ = await library.close()
                    throw error
                }
            }
        #endif
        let credentials = KeychainCredentials()
        return try await MacLibrary.open(
            directory: launch.directory, expectedLibraryID: launch.expectedLibraryID,
            notifications: MacLocalNotifications(), credentials: credentials,
            modules: { [MacHTTPModule(registry: $0, credentials: credentials)] })
    }
}

#if DEBUG
    /// Demo mode has no path to the system credential store.
    private struct DemoCredentials: MacCredentialStore {
        func read(reference: String, version: Int) throws -> String { throw Self.unavailable }
        func save(_ secret: String, reference: String, version: Int) throws { throw Self.unavailable }
        func delete(reference: String, version: Int) throws { throw Self.unavailable }
        private static var unavailable: MiraError {
            .init(.unsupported, "Credentials are unavailable in demo mode.")
        }
    }
#endif
