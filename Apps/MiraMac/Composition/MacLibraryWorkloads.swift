import CryptoKit
import Foundation
import MiraCore
import MiraData

struct MacWorkloadStatus: Sendable, Equatable {
    let isClosed: Bool
    let failures: [String: MiraError]
}

/// The ordinary host surface for model settings. Connection writes remain
/// owned by MacCredentialSettings so Keychain references and database commits
/// share one serialized workflow.
protocol MacModelSettings: Sendable {
    func connection(id: ConnectionID) async throws -> AgentConfiguredConnection?
    func discoverySnapshot(connectionID: ConnectionID) async throws -> AgentModelDiscoverySnapshot?
    func model(id: ModelDescriptorID) async throws -> AgentConfiguredModel?
    func preset(id: RouteID) async throws -> AgentRoutePreset?
    func connections(after: ConnectionID?, limit: Int) async throws -> [AgentConfiguredConnection]
    func models(connectionID: ConnectionID?, after: ModelDescriptorID?, limit: Int) async throws
        -> [AgentConfiguredModel]
    func presets(modelID: ModelDescriptorID?, after: RouteID?, limit: Int) async throws -> [AgentRoutePreset]
    func ensureConversationDefault() async throws -> AgentRouteBinding?
    func bindings(scope: AgentRouteScope) async throws -> [AgentRouteBinding]
    func candidate(routeID: RouteID) async throws -> AgentModelRouteCandidate
    func configurationDescriptors(for invocation: AgentModelInvocationSpec) async throws -> [AgentModelConfigurationDescriptor]
    func discoveryDescriptors() async throws -> [AgentModelDiscoveryDescriptor]
    func resolve(
        purpose: String, explicitRouteID: RouteID?, sessionSelection: AgentSessionModelSelection,
        workspaceID: WorkspaceID?,
        requiredCapabilities: Set<String>
    ) async throws -> AgentModelRouteResolution
    func saveModel(_ value: AgentConfiguredModel, expectedRevision: Int?) async throws
    func savePreset(_ value: AgentRoutePreset, expectedRevision: Int?) async throws
    func savePoolModel(
        _ model: AgentConfiguredModel, preset: AgentRoutePreset,
        expectedModelRevision: Int?, expectedPresetRevision: Int?
    ) async throws
    func saveBinding(_ value: AgentRouteBinding, expectedRevision: Int?) async throws
    func deleteModel(id: ModelDescriptorID, expectedRevision: Int) async throws
    func deletePreset(id: RouteID, expectedRevision: Int) async throws
    func deleteBinding(scope: AgentRouteScope, purpose: String, expectedRevision: Int) async throws
}

extension MacModelSettings {
    func resolve(
        purpose: String, explicitRouteID: RouteID?, sessionSelection: AgentSessionModelSelection = .inherit,
        workspaceID: WorkspaceID?
    ) async throws -> AgentModelRouteResolution {
        try await resolve(
            purpose: purpose, explicitRouteID: explicitRouteID, sessionSelection: sessionSelection,
            workspaceID: workspaceID, requiredCapabilities: [])
    }
}

extension AgentModelSettingsApplication: MacModelSettings {}

/// Replaceable producer group. All durable adapters and domain registrations outlive it.
actor MacLibraryWorkloads {
    let application: AgentApplicationRuntime
    let queries: SessionQueryService
    let search: SessionSearchService
    let changes: any AgentBusinessChangeSource
    let workspaces: WorkspaceApplication
    let modelSettings: any MacModelSettings
    let credentialSettings: MacCredentialSettings
    let connectionTests: MacConnectionTestService
    let memories: MemoryApplication
    let knowledge: KnowledgeApplication
    let tasks: TaskApplication
    let reminders: ReminderScheduler
    let discovery: AgentModelDiscoveryService
    let probes: AgentModelProbeService
    let modelMetadata: AgentModelMetadataService
    let approvals: RuntimeApprovalService
    let scope: RuntimeScope
    let registry: RuntimeRegistry<AgentCapability>
    private let scheduler: RuntimeScheduler
    private let settingsOwner: AgentModelSettingsApplication
    private let extraction: MemoryExtractionWorker
    private let memoryIndex: MemoryIndexWorker
    private let consumers: AgentSessionConsumerService
    private let consumer: SQLiteSessionConsumer
    private let catalog: AgentRuntimeCatalog
    private let clock: any RuntimeClock
    private var watchers: [Task<Void, Never>] = []
    private var closeTask: Task<AgentApplicationShutdownReport, Never>?
    private var failures: [String: MiraError] = [:]
    private var observers: [UUID: AsyncStream<MacWorkloadStatus>.Continuation] = [:]

    private init(
        application: AgentApplicationRuntime, queries: SessionQueryService, search: SessionSearchService,
        changes: any AgentBusinessChangeSource,
        workspaces: WorkspaceApplication,
        modelSettings: AgentModelSettingsApplication, credentialSettings: MacCredentialSettings,
        connectionTests: MacConnectionTestService, memories: MemoryApplication, knowledge: KnowledgeApplication,
        tasks: TaskApplication, reminders: ReminderScheduler, discovery: AgentModelDiscoveryService,
        probes: AgentModelProbeService, modelMetadata: AgentModelMetadataService,
        approvals: RuntimeApprovalService, scheduler: RuntimeScheduler, extraction: MemoryExtractionWorker,
        memoryIndex: MemoryIndexWorker,
        consumers: AgentSessionConsumerService, consumer: SQLiteSessionConsumer, catalog: AgentRuntimeCatalog,
        scope: RuntimeScope, registry: RuntimeRegistry<AgentCapability>, clock: any RuntimeClock
    ) {
        self.application = application
        self.queries = queries
        self.search = search
        self.changes = changes
        self.workspaces = workspaces
        self.modelSettings = modelSettings
        self.credentialSettings = credentialSettings
        self.connectionTests = connectionTests
        self.memories = memories
        self.knowledge = knowledge
        self.tasks = tasks
        self.reminders = reminders
        self.discovery = discovery
        self.probes = probes
        self.modelMetadata = modelMetadata
        self.approvals = approvals
        self.scheduler = scheduler
        self.settingsOwner = modelSettings
        self.extraction = extraction
        self.memoryIndex = memoryIndex
        self.consumers = consumers
        self.consumer = consumer
        self.catalog = catalog
        self.scope = scope
        self.registry = registry
        self.clock = clock
    }

    static func open(
        storage: MacLibraryStorage, registry: RuntimeRegistry<AgentCapability>,
        authorizer: any AgentSourceAuthorizer, notifications: any LocalNotificationPort,
        credentials: any MacCredentialStore,
        environment: RuntimeEnvironment = .init()
    ) async throws -> MacLibraryWorkloads {
        try Task.checkCancellation()
        let scope = RuntimeScope(kind: .application)
        let scheduler = RuntimeScheduler()
        let approvals = RuntimeApprovalService(environment: environment)
        var cleanups: [@Sendable () async -> Void] = [
            { await scope.dispose() }, { await scheduler.shutdown() }, { await approvals.shutdown() },
        ]
        do {
            let access = storage.access
            try await access.checkReady()
            let authorization = await access.snapshot().authorization
            try await storage.extraction.recoverMemoryExtraction(authorization: authorization, at: environment.now())
            let reader = JournalSessionReader(journal: storage.sessions, payloads: storage.sessions)
            let queries = try SessionQueryService(
                journal: storage.sessions, payloads: storage.sessions, projection: storage.projection,
                access: access, scope: scope)
            cleanups.append { await queries.close() }
            let search = try SessionSearchService(
                journal: storage.sessions, payloads: storage.sessions, index: storage.searchIndex,
                access: access, scope: scope)
            cleanups.append { await search.close() }
            let workspaces = WorkspaceApplication(store: storage.workspaces, access: access, scope: scope)
            cleanups.append { await workspaces.close() }
            let modelSettings = try AgentModelSettingsApplication(
                store: storage.settings, registry: registry, access: access, scope: scope)
            cleanups.append { await modelSettings.close() }
            let credentialSettings = MacCredentialSettings(
                settings: modelSettings, access: access, scope: scope,
                directory: storage.directory, credentials: credentials)
            cleanups.append { await credentialSettings.close() }
            let connectionTests = MacConnectionTestService(
                settings: modelSettings, credentials: credentialSettings, access: access, scope: scope)
            cleanups.append { await connectionTests.close() }
            let consumer = try SQLiteSessionConsumer(
                database: storage.database, identity: SQLiteMemoryExtractionConsumer.identity,
                handler: SQLiteMemoryExtractionConsumer(
                    journal: storage.sessions, payloads: storage.sessions,
                    access: access, scope: scope, now: environment.now))
            cleanups.append { await consumer.close() }
            try await registry.register(id: "mac.memory-extraction", value: .consumer(consumer), scope: scope)
            let app = try await AgentApplicationRuntime.open(
                journal: storage.sessions, payloads: storage.sessions, libraryAccess: access,
                registry: registry, modules: [], policy: MacToolPolicy(), authority: storage.business,
                business: storage.business, authorizer: authorizer, approvals: approvals,
                scheduler: scheduler, environment: environment)
            cleanups.append { _ = await app.shutdown() }
            let frozen = try await registry.freeze()
            let catalog: AgentRuntimeCatalog
            do { catalog = try AgentRuntimeCatalog(snapshot: frozen) } catch {
                await frozen.release()
                throw error
            }
            cleanups.append { await catalog.release() }
            let extraction = MemoryExtractionWorker(
                store: storage.extraction, reader: reader, settings: storage.settings, catalog: catalog,
                scheduler: scheduler, access: access, scope: scope, environment: environment)
            cleanups.append { await extraction.close() }
            let memoryIndex = MemoryIndexWorker(store: storage.memories, embeddings: storage.embeddings,
                                               access: access, scope: scope)
            cleanups.append { await memoryIndex.close() }
            let memories = MemoryApplication(
                store: storage.memories, extractionStatusReader: storage.extraction,
                reader: reader, privacyHistory: storage.privacyPlans, access: access, scope: scope, now: environment.now)
            cleanups.append { await memories.close() }
            let knowledge = KnowledgeApplication(
                store: storage.knowledge, reader: reader,
                access: access, scope: scope, now: environment.now)
            cleanups.append { await knowledge.close() }
            let tasks = TaskApplication(
                store: storage.tasks, reader: reader,
                access: access, scope: scope, now: environment.now)
            cleanups.append { await tasks.close() }
            let reminders = ReminderScheduler(
                store: storage.tasks, notifications: notifications,
                namespace: notificationNamespace(directory: storage.directory, libraryID: storage.authority.libraryID),
                access: access, scope: scope, now: environment.now)
            cleanups.append { await reminders.close() }
            let discovery = try AgentModelDiscoveryService(
                settings: storage.settings, registry: registry,
                access: access, scope: scope)
            cleanups.append { await discovery.close() }
            let probes = try AgentModelProbeService(
                probeStore: SQLiteAgentModelProbeStore(
                    database: storage.database, libraryID: storage.authority.libraryID),
                registry: registry, access: access, scope: scope, environment: environment)
            cleanups.append { await probes.close() }
            let modelMetadata = try AgentModelMetadataService(
                settings: storage.settings, store: storage.modelMetadata,
                registry: registry, access: access, scope: scope)
            cleanups.append { await modelMetadata.close() }
            let consumers = try await AgentSessionConsumerService.open(
                journal: storage.sessions, registry: registry, access: access, scope: scope,
                environment: environment)
            cleanups.append { await consumers.close() }
            let group = MacLibraryWorkloads(
                application: app, queries: queries, search: search, changes: storage.changes,
                workspaces: workspaces, modelSettings: modelSettings,
                credentialSettings: credentialSettings, connectionTests: connectionTests,
                memories: memories, knowledge: knowledge,
                tasks: tasks, reminders: reminders, discovery: discovery, probes: probes,
                modelMetadata: modelMetadata, approvals: approvals,
                scheduler: scheduler, extraction: extraction, memoryIndex: memoryIndex, consumers: consumers, consumer: consumer,
                catalog: catalog, scope: scope, registry: registry, clock: environment.clock)
            do { try await group.start() } catch {
                _ = await group.close()
                throw error
            }
            return group
        } catch {
            for cleanup in cleanups.reversed() { await cleanup() }
            throw MiraError.safe(error)
        }
    }

    func status() -> MacWorkloadStatus { .init(isClosed: closeTask != nil, failures: failures) }

    func localMemoryModelStatus() async -> MemoryEmbeddingStatus { await memoryIndex.embeddingStatus() }
    func prepareLocalMemoryModel() async {
        guard closeTask == nil else { return }
        await memoryIndex.prepareModel()
    }

    func observe() -> AsyncStream<MacWorkloadStatus> {
        let (stream, continuation) = AsyncStream<MacWorkloadStatus>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation.yield(status())
        guard closeTask == nil else {
            continuation.finish()
            return stream
        }
        let id = UUID()
        observers[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        return stream
    }

    /// Also called after explicit task edits, extraction policy changes and settings changes.
    func wake() async {
        guard closeTask == nil else { return }
        await consumers.wake()
        await extraction.wake()
        await wakeMemoryIndex()
        do {
            try await reminders.reconcile()
            clearFailure("reminders")
        } catch is CancellationError {} catch { recordFailure("reminders", error: error) }
    }

    func close() async -> AgentApplicationShutdownReport {
        if let closeTask { return await closeTask.value }
        let watchers = watchers
        let task = Task {
            for watcher in watchers { watcher.cancel() }
            // Stop new domain jobs before draining their workers and foreground executions.
            await consumers.close()
            await discovery.close()
            await probes.close()
            await modelMetadata.close()
            await extraction.close()
            await memoryIndex.close()
            await reminders.close()
            await memories.close()
            await knowledge.close()
            await tasks.close()
            await queries.close()
            await search.close()
            await workspaces.close()
            await connectionTests.close()
            await credentialSettings.close()
            await settingsOwner.close()
            let report = await application.shutdown()
            await approvals.shutdown()
            for watcher in watchers { await watcher.value }
            await consumer.close()
            await catalog.release()
            await scheduler.shutdown()
            await scope.dispose()
            finishObservers()
            return report
        }
        closeTask = task
        return await task.value
    }

    private func start() async throws {
        await credentialSettings.start()
        let applicationEvents = try await application.observe()
        let consumerEvents = try await consumers.events()
        let extractionEvents = await extraction.events()
        let businessEvents = try await changes.observe()
        watchers.append(try await scope.ownTask { [weak self] in
            for await event in businessEvents {
                guard !Task.isCancelled, !event.isClosed else { break }
                await self?.wakeMemoryIndex()
            }
        })
        watchers.append(
            try await scope.ownTask { [weak self] in
                for await _ in applicationEvents {
                    guard !Task.isCancelled else { break }
                    await self?.wake()
                }
            })
        watchers.append(
            try await scope.ownTask { [weak self] in
                for await event in consumerEvents {
                    guard !Task.isCancelled else { break }
                    switch event {
                    case .advanced, .reconciled:
                        await self?.clearFailure("consumers")
                        await self?.extraction.wake()
                    case .failure(_, _, let error): await self?.recordFailure("consumers", error: error)
                    }
                }
            })
        watchers.append(
            try await scope.ownTask { [weak self] in
                for await event in extractionEvents {
                    guard !Task.isCancelled else { break }
                    switch event {
                    case .changed: await self?.clearFailure("extraction")
                    case .failure(let error): await self?.recordFailure("extraction", error: error)
                    }
                }
            })
        let clock = clock
        watchers.append(
            try await scope.ownTask { [weak self] in
                do {
                    while !Task.isCancelled {
                        try await clock.sleep(for: .seconds(30))
                        try Task.checkCancellation()
                        await self?.wake()
                    }
                } catch is CancellationError {} catch {
                    await self?.recordFailure("background", error: error)
                }
            })
        await wake()
    }

    private func recordFailure(_ source: String, error: any Error) {
        guard closeTask == nil else { return }
        failures[source] = MiraError.safe(error)
        for observer in observers.values { observer.yield(status()) }
    }
    private func wakeMemoryIndex() async {
        guard closeTask == nil else { return }
        let state = await application.snapshot()
        await memoryIndex.wake(isIdle: state.pendingAdmissions.isEmpty && state.ownedExecutions.isEmpty)
    }
    private func clearFailure(_ source: String) {
        guard failures.removeValue(forKey: source) != nil else { return }
        for observer in observers.values { observer.yield(status()) }
    }
    private func finishObservers() {
        for observer in observers.values {
            observer.yield(status())
            observer.finish()
        }
        observers.removeAll()
    }
    private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }

    /// A restored library retains its canonical ID but owns separate platform deliveries.
    static func notificationNamespace(directory: URL, libraryID: UUID) -> String {
        let identity = libraryID.uuidString.lowercased() + "\n" + directory.standardizedFileURL.path
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Domain modules may add stricter requirements. This host exposes only read and local business tools.
private struct MacToolPolicy: AgentToolPolicy {
    func evaluate(_ proposal: AgentToolProposal, context: AgentToolContext) async throws -> AgentToolPolicyDecision {
        try validate(proposal, context: context)
        return .allow
    }
    func validate(_ proposal: AgentToolProposal, context: AgentToolContext) throws {
        guard proposal.effect == .read || proposal.effect == .localWrite else {
            throw MiraError(.unauthorized, "The tool effect is not enabled in this host.")
        }
    }
}
