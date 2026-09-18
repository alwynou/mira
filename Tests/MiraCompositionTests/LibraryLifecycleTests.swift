import Foundation
import MiraCore
import MiraData
import MiraProviders
import Testing

@Suite("macOS library composition", .timeLimit(.minutes(1)))
struct LibraryLifecycleTests {
    @Test func allHTTPFamiliesRegisterWithoutReadingCredentials() async throws {
        try await withDirectory { directory in
            let credentials = CompositionCredentials()
            let library = try await MacLibrary.open(embeddings: OfflineMemoryEmbedding(), directory: directory, notifications: CompositionNotifications(),
                credentials: credentials,
                modules: { [MacHTTPModule(registry: $0, credentials: credentials)] })
            do {
                let group = try await library.workloads()
                let catalog = try await group.registry.freeze()
                let models = catalog.entries.compactMap { entry -> AgentAdapterIdentity? in
                    if case .model(let adapter) = entry.value { return adapter.identity }
                    return nil
                }
                #expect(Set(models) == Set([
                    HTTPAdapterIdentity.chatCompletions, HTTPAdapterIdentity.anthropicMessages,
                    HTTPAdapterIdentity.responses,
                ]))
                #expect(
                    catalog.entries.filter { if case .modelConfiguration = $0.value { true } else { false } }.count == 3
                )
                #expect(
                    catalog.entries.filter { if case .modelDiscovery = $0.value { true } else { false } }.count == 2)
                await catalog.release()
                #expect(await library.close().isSettled)
                #expect(credentials.enteredOperations.isEmpty)
            } catch {
                _ = await library.close()
                throw error
            }
        }
    }

    @Test func copiedLibraryDoesNotReplaceOriginalPlatformNotifications() async throws {
        try await withDirectory { directory in
            let notifications = CompositionNotifications()
            let original = try await MacLibrary.open(embeddings: OfflineMemoryEmbedding(), directory: directory, notifications: notifications, credentials: CompositionCredentials(), modules: { _ in [] })
            do {
                let group = try await original.workloads()
                _ = try await group.tasks.save(
                    id: .init(), workspaceID: nil,
                    draft: .init(title: "Synthetic delivery", reminderAt: Date().addingTimeInterval(3_600)),
                    status: .open, expectedRevision: nil, operationID: UUID())
                await group.wake()
                #expect(await notifications.pending().count == 1)
                #expect(await original.close().isSettled)
            } catch {
                _ = await original.close()
                throw error
            }
            let originalID = try #require(await notifications.pending().first?.identifier)
            let copy = directory.deletingLastPathComponent().appendingPathComponent("Copy")
            try FileManager.default.copyItem(at: directory, to: copy)
            let copied = try await MacLibrary.open(embeddings: OfflineMemoryEmbedding(), directory: copy, notifications: notifications, credentials: CompositionCredentials(), modules: { _ in [] })
            #expect(copied.id == original.id)
            #expect(await notifications.pending().count == 2)
            #expect(await notifications.pending().contains { $0.identifier == originalID })
            #expect(await copied.close().isSettled)
        }
    }

    @Test func reopenPreservesJournalAndBusinessDataAndRejectsConcurrentWriter() async throws {
        try await withDirectory { directory in
            let notifications = CompositionNotifications()
            let first = try await MacLibrary.open(embeddings: OfflineMemoryEmbedding(), directory: directory, notifications: notifications, credentials: CompositionCredentials(), modules: { _ in [] })
            let session = ConversationID()
            let taskID = MiraTaskID()
            let connection = AgentConfiguredConnection(
                id: .init(), revision: 1, configurationRevision: 1, name: "Synthetic settings", isEnabled: false,
                definitionID: nil,
                endpoints: [.init(id: "primary", configuration: .init(
                    schema: .init(id: "tests.settings", revision: 1), value: .object([:])), credential: nil)],
                discovery: nil, defaultInvocation: nil)
            do {
                let group = try await first.workloads()
                try committed(
                    await group.application.createSession(
                        id: session, commandID: UUID(), title: "Synthetic session", workspaceID: nil))
                let savedConnection = try await group.credentialSettings.saveConnection(
                    id: connection.id, name: connection.name, isEnabled: connection.isEnabled,
                    definitionID: connection.definitionID, endpoints: connection.endpoints,
                    discovery: connection.discovery, defaultInvocation: connection.defaultInvocation,
                    previous: nil, credentialEndpointID: connection.endpoints[0].id, credential: .keep).connection
                #expect(savedConnection == connection)
                let workspace = Workspace(id: .init(), name: "Synthetic workspace", background: "Initial")
                try await group.workspaces.save(workspace, expectedRevision: nil)
                #expect(try await group.workspaces.workspace(workspace.id) == workspace)
                var revisedWorkspace = workspace
                revisedWorkspace.background = "Updated"
                revisedWorkspace.revision = 2
                try await group.workspaces.save(revisedWorkspace, expectedRevision: workspace.revision)
                await #expect(throws: MiraError.self) {
                    try await group.workspaces.save(revisedWorkspace, expectedRevision: workspace.revision)
                }
                #expect(try await group.workspaces.workspace(workspace.id) == revisedWorkspace)
                _ = try await group.tasks.save(
                    id: taskID, workspaceID: nil, draft: .init(title: "Synthetic task"),
                    status: .open, expectedRevision: nil, operationID: UUID())
                await #expect(throws: MiraError.self) {
                    _ = try await MacLibrary.open(embeddings: OfflineMemoryEmbedding(), directory: directory, notifications: notifications, credentials: CompositionCredentials(), modules: { _ in [] })
                }
                #expect(await first.status().phase == .ready)
                #expect(try await group.tasks.tasks(workspaceID: nil).map(\.id) == [taskID])
                #expect(await first.close().isSettled)
                await #expect(throws: MiraError.self) { _ = try await group.tasks.tasks(workspaceID: nil) }
                await #expect(throws: MiraError.self) { _ = try await group.queries.sessions() }
                await #expect(throws: MiraError.self) { _ = try await group.workspaces.workspaces() }
                await #expect(throws: MiraError.self) { _ = try await group.modelSettings.connections(after: nil, limit: 128) }
                await #expect(throws: MiraError.self) { _ = try await group.credentialSettings.retryCleanup() }
            } catch {
                _ = await first.close()
                throw error
            }
            let second = try await MacLibrary.open(embeddings: OfflineMemoryEmbedding(), directory: directory, notifications: notifications, credentials: CompositionCredentials(), modules: { _ in [] })
            do {
                #expect(second.id == first.id)
                let group = try await second.workloads()
                #expect(try await group.modelSettings.connection(id: connection.id) == connection)
                #expect(try await group.application.sessionSnapshot(id: session).header?.title != nil)
                #expect(try await group.tasks.tasks(workspaceID: nil).map(\.id) == [taskID])
                #expect(await notifications.permissionRequests == 0)
                #expect(await second.close().isSettled)
            } catch {
                _ = await second.close()
                throw error
            }
        }
    }

    @Test func exportAndMaintenanceReplaceWorkGroupsAndPreserveCanonicalData() async throws {
        try await withDirectory { directory in
            let library = try await MacLibrary.open(embeddings: OfflineMemoryEmbedding(), directory: directory, notifications: CompositionNotifications(), credentials: CompositionCredentials(), modules: { _ in [] })
            do {
                let group = try await library.workloads()
                let session = ConversationID()
                try committed(
                    await group.application.createSession(
                        id: session, commandID: UUID(), title: "Archive evidence", workspaceID: nil))
                let archive = directory.deletingLastPathComponent().appendingPathComponent("Export")
                let manifest = try await library.exportArchive(to: archive)
                #expect(manifest.authorization.libraryID == library.id)
                #expect(await group.status().isClosed)
                await #expect(throws: MiraError.self) { _ = try await group.queries.sessions() }
                await #expect(throws: MiraError.self) { _ = try await group.workspaces.workspaces() }
                await #expect(throws: MiraError.self) { _ = try await group.modelSettings.connections(after: nil, limit: 128) }
                await #expect(throws: MiraError.self) { _ = try await group.credentialSettings.retryCleanup() }
                #expect(await library.status().phase == .ready)
                #expect(await library.status().generation == 2)
                let replacement = try await library.workloads()
                #expect(try await replacement.application.sessionSnapshot(id: session).header?.title != nil)
                let request = AgentLibraryMaintenanceRequest(
                    id: UUID(), namespace: "knowledge.collect", revision: 1,
                    scope: .library, requestedAt: Date())
                #expect(try await library.maintain(request).completedAt != nil)
                #expect(await replacement.status().isClosed)
                await #expect(throws: MiraError.self) { _ = try await replacement.queries.sessions() }
                await #expect(throws: MiraError.self) { _ = try await replacement.workspaces.workspaces() }
                await #expect(throws: MiraError.self) { _ = try await replacement.modelSettings.connections(after: nil, limit: 128) }
                await #expect(throws: MiraError.self) { _ = try await replacement.credentialSettings.retryCleanup() }
                #expect(await library.status().generation == 3)
                #expect(await library.pendingMaintenance() == nil)
                #expect(await library.close().isSettled)
            } catch {
                _ = await library.close()
                throw error
            }
        }
    }

    @Test func failedExportReopensReadyWorkGroupAndDoesNotOverwriteDestination() async throws {
        try await withDirectory { directory in
            let library = try await MacLibrary.open(embeddings: OfflineMemoryEmbedding(), directory: directory, notifications: CompositionNotifications(), credentials: CompositionCredentials(), modules: { _ in [] })
            do {
                let before = try await library.workloads()
                let destination = directory.deletingLastPathComponent().appendingPathComponent("Existing")
                try Data("Preserve this file".utf8).write(to: destination)
                await #expect(throws: MiraError.self) { _ = try await library.exportArchive(to: destination) }
                #expect(try Data(contentsOf: destination) == Data("Preserve this file".utf8))
                #expect(await before.status().isClosed)
                #expect(await library.status().phase == .ready)
                let next = try await library.workloads()
                #expect(try await next.tasks.tasks(workspaceID: nil).isEmpty)
                #expect(await library.close().isSettled)
            } catch {
                _ = await library.close()
                throw error
            }
        }
    }

    @Test func closeDrainsActualNotificationRequestBeforeReleasingLibraryLock() async throws {
        try await withDirectory { directory in
            let notifications = CompositionNotifications()
            let library = try await MacLibrary.open(embeddings: OfflineMemoryEmbedding(), directory: directory, notifications: notifications, credentials: CompositionCredentials(), modules: { _ in [] })
            let group = try await library.workloads()
            await notifications.gateNextPermissionRequest()
            let request = Task { try await group.reminders.requestPermission() }
            var closing: Task<MacLibraryCloseResult, Never>?
            do {
                try await eventually { await notifications.requestEntered }
                closing = Task { await library.close() }
                try await eventually { await library.status().phase == .closing }
                await #expect(throws: MiraError.self) {
                    _ = try await MacLibrary.open(embeddings: OfflineMemoryEmbedding(), directory: directory, notifications: CompositionNotifications(), credentials: CompositionCredentials(), modules: { _ in [] })
                }
                #expect(await library.status().phase == .closing)
                await notifications.releasePermission()
                _ = await request.result
                #expect(await closing!.value.isSettled)
                let reopened = try await MacLibrary.open(embeddings: OfflineMemoryEmbedding(), directory: directory, notifications: CompositionNotifications(), credentials: CompositionCredentials(), modules: { _ in [] })
                #expect(await reopened.close().isSettled)
            } catch {
                await notifications.releasePermission()
                _ = await request.result
                _ = await closing?.value
                _ = await library.close()
                throw error
            }
        }
    }

    @Test func invalidStorageInitializationReleasesWriterLockForRepair() async throws {
        try await withDirectory { directory in
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let database = directory.appendingPathComponent("Business.sqlite")
            let invalid = Data("Not a SQLite database".utf8)
            try invalid.write(to: database)
            await #expect(throws: MiraError.self) {
                _ = try await MacLibrary.open(embeddings: OfflineMemoryEmbedding(), directory: directory, notifications: CompositionNotifications(), credentials: CompositionCredentials(), modules: { _ in [] })
            }
            #expect(try Data(contentsOf: database) == invalid)
            try FileManager.default.removeItem(at: database)
            let repaired = try await MacLibrary.open(embeddings: OfflineMemoryEmbedding(), directory: directory, notifications: CompositionNotifications(), credentials: CompositionCredentials(), modules: { _ in [] })
            #expect(await repaired.close().isSettled)
        }
    }

    @Test func failedModuleActivationReleasesPartialLibraryForRetry() async throws {
        try await withDirectory { directory in
            await #expect(throws: MiraError.self) {
                _ = try await MacLibrary.open(embeddings: OfflineMemoryEmbedding(), directory: directory, notifications: CompositionNotifications(),
                    credentials: CompositionCredentials(), modules: { _ in [FailingCompositionModule()] })
            }
            let repaired = try await MacLibrary.open(embeddings: OfflineMemoryEmbedding(), directory: directory, notifications: CompositionNotifications(), credentials: CompositionCredentials(), modules: { _ in [] })
            #expect(await repaired.close().isSettled)
        }
    }

    @Test func closeOwnsCancelledMaintenanceWaiterAndDoesNotRestartWorkloads() async throws {
        try await withDirectory { directory in
            let notifications = CompositionNotifications()
            let library = try await MacLibrary.open(embeddings: OfflineMemoryEmbedding(), directory: directory, notifications: notifications, credentials: CompositionCredentials(), modules: { _ in [] })
            let group = try await library.workloads()
            await notifications.gateNextPermissionRequest()
            let permission = Task { try await group.reminders.requestPermission() }
            var maintenance: Task<AgentLibraryMaintenanceOperation, any Error>?
            var closing: Task<MacLibraryCloseResult, Never>?
            do {
                try await eventually { await notifications.requestEntered }
                maintenance = Task {
                    try await library.maintain(
                        .init(
                            id: UUID(), namespace: "knowledge.collect", revision: 1,
                            scope: .library, requestedAt: Date()))
                }
                try await eventually { await group.status().isClosed }
                maintenance?.cancel()
                closing = Task { await library.close() }
                try await eventually { await library.status().phase == .closing }
                await notifications.releasePermission()
                _ = await permission.result
                #expect(try await maintenance!.value.completedAt != nil)
                #expect(await closing!.value.isSettled)
                #expect(await library.status().phase == .closed)
                #expect(await library.status().generation == 1)
                let reopened = try await MacLibrary.open(embeddings: OfflineMemoryEmbedding(), directory: directory, notifications: CompositionNotifications(), credentials: CompositionCredentials(), modules: { _ in [] })
                #expect(await reopened.pendingMaintenance() == nil)
                #expect(await reopened.close().isSettled)
            } catch {
                await notifications.releasePermission()
                _ = await permission.result
                _ = await maintenance?.result
                _ = await closing?.value
                _ = await library.close()
                throw error
            }
        }
    }

    @Test func unsupportedDevelopmentLibraryIsRejectedWithoutChangingItsContents() async throws {
        try await withDirectory { directory in
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let obsolete = directory.appendingPathComponent("Mira.sqlite")
            try Data("Synthetic obsolete library".utf8).write(to: obsolete)
            await #expect(throws: MiraError.self) {
                _ = try await MacLibrary.open(embeddings: OfflineMemoryEmbedding(), directory: directory, notifications: CompositionNotifications(), credentials: CompositionCredentials(), modules: { _ in [] })
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["Mira.sqlite"])
            #expect(try Data(contentsOf: obsolete) == Data("Synthetic obsolete library".utf8))
        }
    }

    @Test func symbolicAndHardLinkedBusinessDatabasesAreRejected() async throws {
        for symbolic in [true, false] {
            try await withDirectory { directory in
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                let external = directory.deletingLastPathComponent().appendingPathComponent("External")
                try Data("External sentinel".utf8).write(to: external)
                let path = directory.appendingPathComponent("Business.sqlite")
                if symbolic {
                    try FileManager.default.createSymbolicLink(at: path, withDestinationURL: external)
                } else {
                    try FileManager.default.linkItem(at: external, to: path)
                }
                await #expect(throws: MiraError.self) {
                    _ = try await MacLibrary.open(embeddings: OfflineMemoryEmbedding(), directory: directory, notifications: CompositionNotifications(), credentials: CompositionCredentials(), modules: { _ in [] })
                }
                #expect(try Data(contentsOf: external) == Data("External sentinel".utf8))
            }
        }
    }
}

func withDirectory(isolation: isolated (any Actor)? = #isolation, _ operation: (URL) async throws -> Void) async throws {
    let parent = FileManager.default.temporaryDirectory.appendingPathComponent("mira-composition-\(UUID())")
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: parent) }
    try await operation(parent.appendingPathComponent("Library"))
}

func committed(_ result: SessionCommitResult) throws {
    switch result {
    case .committed: return
    case .notCommitted(let error), .indeterminate(_, let error): throw error
    }
}

func eventually(isolation: isolated (any Actor)? = #isolation, _ condition: () async -> Bool) async throws {
    // Cold macOS host tests may initialize the SQLite and Swift runtime modules
    // concurrently; keep the synthetic polling bound generous without making a
    // genuinely stalled operation unbounded.
    let deadline = ContinuousClock.now + .seconds(15)
    while !(await condition()) {
        guard ContinuousClock.now < deadline else {
            throw MiraError(.timeout, "The synthetic condition was not reached.")
        }
        try await Task.sleep(for: .milliseconds(1))
    }
}

actor CompositionNotifications: LocalNotificationPort {
    var permissionRequests = 0
    var requestEntered = false
    private var gated = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var scheduled: [String: ReminderNotification] = [:]
    func permission() -> NotificationPermission { .allowed }
    func requestPermission() async throws -> Bool {
        permissionRequests += 1
        requestEntered = true
        if gated { await withCheckedContinuation { continuation = $0 } }
        return true
    }
    func pending() -> [ReminderNotification] { Array(scheduled.values) }
    func install(_ notification: ReminderNotification) { scheduled[notification.identifier] = notification }
    func remove(_ identifier: String) { scheduled[identifier] = nil }
    func gateNextPermissionRequest() { gated = true }
    func releasePermission() {
        gated = false
        continuation?.resume()
        continuation = nil
    }
}

private struct FailingCompositionModule: RuntimeModule {
    let id = "tests.failure"
    let dependencies: Set<String> = []

    func activate(in scope: RuntimeScope) async throws {
        throw MiraError(.configuration, "Synthetic module activation failed.")
    }
}
