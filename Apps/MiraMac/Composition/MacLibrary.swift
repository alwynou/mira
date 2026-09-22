import Foundation
import MiraCore
import MiraData
import MiraProviders

struct MacLibraryStatus: Sendable, Equatable {
    enum Phase: Sendable { case starting, ready, maintaining, failed, closing, closed }
    let phase: Phase
    let generation: UInt64
    let failure: MiraError?
}

struct MacLibraryCloseResult: Sendable {
    let executionsSettled: Bool
    let storageError: MiraError?
    var isSettled: Bool { executionsSettled && storageError == nil }
}

struct MacLibraryWorkgroupBinding: Sendable {
    let status: MacLibraryStatus
    let workgroup: MacLibraryWorkloads
}

/// The macOS composition owner. It replaces complete work groups around library maintenance.
/// It does not duplicate conversation commands, domain APIs or provider requests.
actor MacLibrary {
    typealias ModuleFactory = @Sendable (RuntimeRegistry<AgentCapability>) -> [any RuntimeModule]
    let directory: URL
    let id: UUID
    private let storage: MacLibraryStorage
    private let scope: RuntimeScope
    private let activation: RuntimeModuleActivation
    private let registry: RuntimeRegistry<AgentCapability>
    private let handlers: RuntimeRegistry<any AgentLibraryMaintenanceHandler>
    private let authorizer: JournalAgentSourceAuthorizer
    private let notifications: any LocalNotificationPort
    private let credentials: any MacCredentialStore
    private let environment: RuntimeEnvironment
    private var group: MacLibraryWorkloads?
    private var phase: MacLibraryStatus.Phase = .starting
    private var generation: UInt64 = 0
    private var failure: MiraError?
    private var operationDrain: (@Sendable () async -> Void)?
    private var closeTask: Task<MacLibraryCloseResult, Never>?
    private var deletionObservation: Task<Void, Never>?
    private var deletionExecutionObservation: Task<Void, Never>?
    private var deletionProcessing: Task<Void, Never>?
    private var deletionWakeup = false
    private var observers: [UUID: AsyncStream<MacLibraryStatus>.Continuation] = [:]

    private init(
        storage: MacLibraryStorage, scope: RuntimeScope, activation: RuntimeModuleActivation,
        registry: RuntimeRegistry<AgentCapability>, handlers: RuntimeRegistry<any AgentLibraryMaintenanceHandler>,
        authorizer: JournalAgentSourceAuthorizer, notifications: any LocalNotificationPort,
        credentials: any MacCredentialStore,
        environment: RuntimeEnvironment
    ) {
        self.storage = storage
        self.scope = scope
        self.activation = activation
        self.registry = registry
        self.handlers = handlers
        self.authorizer = authorizer
        self.notifications = notifications
        self.credentials = credentials
        self.environment = environment
        directory = storage.directory
        id = storage.authority.libraryID
    }

    static func open(
        embeddings: (any MemoryEmbeddingService)? = nil, directory: URL, expectedLibraryID: UUID? = nil,
        notifications: any LocalNotificationPort, credentials: any MacCredentialStore,
        modules: @escaping ModuleFactory, environment: RuntimeEnvironment = .init()
    ) async throws -> MacLibrary {
        let storage = try await MacLibraryStorage.open(
            embeddings: embeddings, directory: directory, expectedLibraryID: expectedLibraryID, environment: environment)
        let scope = RuntimeScope(kind: .library(storage.authority.libraryID))
        let registry = RuntimeRegistry<AgentCapability>()
        let domains = RuntimeRegistry<any AgentDomainSourceAuthority>()
        let handlers = RuntimeRegistry<any AgentLibraryMaintenanceHandler>()
        var activation: RuntimeModuleActivation?
        do {
            let host = try RuntimeModuleHost(
                modules: [
                    MacDriverModule(registry: registry),
                    MemoryModule(
                        registry: registry, store: storage.memories,
                        sourceAuthorities: domains, now: environment.now),
                    KnowledgeModule(
                        registry: registry, store: storage.knowledge, sourceAuthorities: domains, prefetch: true),
                    TaskModule(registry: registry, store: storage.tasks, sourceAuthorities: domains),
                ] + modules(registry))
            let active = try await host.activate(in: scope)
            activation = active
            let memory = MemoryForgetHandler(memories: storage.memories)
            try await handlers.register(id: memory.identity.namespace, value: memory, scope: scope)
            for action in [KnowledgePrivacyAction.revokeRemoteUse, .deleteSource] {
                let handler = KnowledgePrivacyHandler(
                    action: action, knowledge: storage.knowledge,
                    blobs: storage.knowledge)
                try await handlers.register(id: handler.identity.namespace, value: handler, scope: scope)
            }
            let blobs = KnowledgeBlobCollectionHandler(store: storage.knowledge)
            try await handlers.register(id: blobs.identity.namespace, value: blobs, scope: scope)
            let authorizer = JournalAgentSourceAuthorizer(
                reader: .init(journal: storage.sessions, payloads: storage.sessions),
                policy: storage.contextPolicy, domains: domains)
            let library = MacLibrary(
                storage: storage, scope: scope, activation: active,
                registry: registry, handlers: handlers, authorizer: authorizer,
                notifications: notifications, credentials: credentials, environment: environment)
            do { try await library.recoverAndStart() } catch {
                _ = await library.close()
                throw error
            }
            return library
        } catch {
            await activation?.dispose()
            await scope.dispose()
            _ = await storage.close()
            throw MiraError.safe(error)
        }
    }

    func status() -> MacLibraryStatus { .init(phase: phase, generation: generation, failure: failure) }

    func observe() -> AsyncStream<MacLibraryStatus> {
        let (stream, continuation) = AsyncStream<MacLibraryStatus>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation.yield(status())
        guard phase != .closed else {
            continuation.finish()
            return stream
        }
        let id = UUID()
        observers[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        return stream
    }

    func workloads() throws -> MacLibraryWorkloads {
        guard phase == .ready, let group, closeTask == nil else { throw Self.unavailable }
        return group
    }

    func diagnostics() async throws -> MacLibraryDiagnostics {
        guard phase == .ready, closeTask == nil else { throw Self.unavailable }
        return try await storage.diagnostics(scope: scope)
    }

    /// Capture the displayed generation and its services in one actor turn.
    func binding() throws -> MacLibraryWorkgroupBinding {
        .init(status: status(), workgroup: try workloads())
    }

    func pendingMaintenance() async -> AgentLibraryMaintenanceOperation? { await storage.access.snapshot().pending }

    func maintain(_ request: AgentLibraryMaintenanceRequest) async throws -> AgentLibraryMaintenanceOperation {
        try await owned { coordinator in
            let state = await self.storage.access.snapshot()
            let expected =
                state.pending.flatMap { $0.request == request ? $0.previousAuthorization : nil }
                ?? state.authorization
            return try await coordinator.perform(request, expected: expected)
        }
    }

    func exportArchive(to destination: URL) async throws -> LibraryArchiveManifest {
        try await owned { coordinator in
            let granted = destination.startAccessingSecurityScopedResource()
            defer { if granted { destination.stopAccessingSecurityScopedResource() } }
            let authorization = await self.storage.access.snapshot().authorization
            let storage = self.storage
            return try await coordinator.withQuiescentSnapshot(expected: authorization) { captured in
                let exporter = try SQLiteLibraryArchiveExporter(
                    database: storage.database,
                    sessions: storage.sessions, libraryID: storage.authority.libraryID,
                    attachmentDirectory: storage.directory, modules: storage.archiveModules)
                do {
                    let result = try await exporter.export(to: destination, authorization: captured)
                    await exporter.close()
                    return result
                } catch {
                    await exporter.close()
                    throw error
                }
            }
        }
    }

    /// Closing never abandons an admitted maintenance/export operation or its newly opened group.
    func close() async -> MacLibraryCloseResult {
        if let closeTask { return await closeTask.value }
        phase = .closing
        publish()
        deletionObservation?.cancel()
        deletionExecutionObservation?.cancel()
        deletionProcessing?.cancel()
        let drain = operationDrain
        let task = Task {
            await drain?()
            let settled = await group?.close().isSettled ?? true
            group = nil
            // Execution waits must be released by closing the workgroup before we
            // drain the library-owned deletion processor.
            await deletionProcessing?.value
            await deletionObservation?.value
            await deletionExecutionObservation?.value
            deletionProcessing = nil
            deletionObservation = nil
            deletionExecutionObservation = nil
            await activation.dispose()
            await scope.dispose()
            let storageError = await storage.close()
            phase = .closed
            publish()
            for observer in observers.values { observer.finish() }
            observers.removeAll()
            return MacLibraryCloseResult(executionsSettled: settled, storageError: storageError)
        }
        closeTask = task
        return await task.value
    }

    private func recoverAndStart() async throws {
        let pending = await storage.access.snapshot().pending
        if let pending {
            // Ordinary access remains closed. These read-only authorities are tied to
            // the exact pending operation and can validate only local recovery.
            let recoveryScope = RuntimeScope(kind: .application)
            let sources = RuntimeRegistry<any AgentDomainSourceAuthority>()
            do {
                let authorities =
                    [
                        storage.memories.pendingRecoveryAuthority(pending, now: environment.now),
                        storage.tasks.pendingRecoveryAuthority(pending),
                    ] + storage.knowledge.pendingRecoveryAuthorities(pending)
                for authority in authorities {
                    try await sources.register(id: authority.namespace, value: authority, scope: recoveryScope)
                }
                let recoveryAuthorizer = JournalAgentSourceAuthorizer(
                    reader: .init(journal: storage.sessions, payloads: storage.sessions),
                    policy: storage.contextPolicy.pendingRecoveryPolicy(pending), domains: sources)
                try await restoreLocally(authorizer: recoveryAuthorizer)
                await recoveryScope.dispose()
            } catch {
                await recoveryScope.dispose()
                throw error
            }
            let coordinator = try AgentLibraryMaintenanceCoordinator(
                access: storage.access,
                handlers: handlers, workOwners: [], now: environment.now)
            do {
                _ = try await coordinator.perform(pending.request, expected: pending.previousAuthorization)
                await coordinator.close()
            } catch {
                await coordinator.close()
                throw error
            }
        } else {
            try await restoreLocally(authorizer: authorizer)
        }
        let projection = try SessionProjectionCoordinator(journal: storage.sessions, projection: storage.projection)
        do {
            var cursor: ConversationID?
            while true {
                let sessionIDs = try await storage.sessions.sessions(after: cursor, limit: 128)
                guard !sessionIDs.isEmpty else { break }
                for sessionID in sessionIDs { _ = try await projection.catchUp(sessionID: sessionID) }
                cursor = sessionIDs.last
            }
            await projection.close()
        } catch {
            await projection.close()
            throw error
        }
        try await startWorkloads()
        try await observeDeletionRequests()
    }

    private func restoreLocally(authorizer: any AgentSourceAuthorizer) async throws {
        // Recovery cannot invoke models or tools; it handles both active executions and terminal outbox receipts.
        let recovery = AgentLibraryRestoration(
            journal: storage.sessions, payloads: storage.sessions,
            receipts: storage.business, authorizer: authorizer, environment: environment)
        do {
            _ = try await recovery.restore()
            await recovery.close()
        } catch {
            await recovery.close()
            throw error
        }
    }

    private func startWorkloads() async throws {
        guard closeTask == nil else { return }
        let next = try await MacLibraryWorkloads.open(
            storage: storage, registry: registry,
            authorizer: authorizer, notifications: notifications, credentials: credentials, environment: environment)
        // Close may begin while asynchronous opening is in flight.
        guard closeTask == nil else {
            _ = await next.close()
            return
        }
        group = next
        let previousObservation = deletionExecutionObservation
        previousObservation?.cancel()
        deletionExecutionObservation = Task { [weak self] in
            await previousObservation?.value
            guard !Task.isCancelled else { return }
            do {
                let executionChanges = try await next.application.observe()
                for await _ in executionChanges {
                    guard !Task.isCancelled else { break }
                    // A settlement retry can complete without a business write.
                    // Wake pending deletion requests on that runtime transition too.
                    await self?.scheduleDeletionProcessing()
                }
            } catch { /* A closing workgroup has no more settlement transitions. */ }
        }
        generation += 1
        phase = .ready
        failure = nil
        publish()
    }

    private func owned<Value: Sendable>(
        _ operation: @escaping @Sendable (AgentLibraryMaintenanceCoordinator) async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        guard closeTask == nil, operationDrain == nil, phase == .ready || phase == .failed else {
            throw Self.unavailable
        }
        let previous = group
        let owners: [AgentLibraryWorkOwner] =
            previous.map { group in
                [
                    .init(id: "mac.workloads") {
                        guard await group.close().isSettled else {
                            throw AgentLibraryMaintenanceError.unsettledWork(["mac.workloads"])
                        }
                    }
                ]
            } ?? []
        let coordinator = try AgentLibraryMaintenanceCoordinator(
            access: storage.access, handlers: handlers,
            workOwners: owners, now: environment.now)
        phase = .maintaining
        failure = nil
        publish()
        let task = Task {
            defer {
                self.operationDrain = nil
                self.scheduleDeletionProcessing()
            }
            let result: Result<Value, any Error>
            do { result = .success(try await operation(coordinator)) } catch { result = .failure(error) }
            await coordinator.close()
            if self.closeTask == nil {
                if await self.storage.access.snapshot().phase == .ready {
                    do {
                        if let previous, !(await previous.status().isClosed) {
                            self.phase = .ready
                        } else {
                            try await self.startWorkloads()
                        }
                    } catch {
                        self.phase = .failed
                        self.failure = MiraError.safe(error)
                    }
                } else {
                    self.phase = .failed
                }
                if case .failure(let error) = result { self.failure = MiraError.safe(error) }
                self.publish()
            }
            return try result.get()
        }
        operationDrain = { _ = await task.result }
        return try await task.value
    }

    /// This processor is library-owned, never a workgroup owner or an execution tool.
    /// A tool commits only a request; no execution can wait for its own maintenance drain.
    private func observeDeletionRequests() async throws {
        let changes = try await storage.changes.observe()
        deletionObservation = Task { [weak self] in
            for await change in changes {
                guard !Task.isCancelled, !change.isClosed else { break }
                await self?.scheduleDeletionProcessing()
            }
        }
    }

    private func scheduleDeletionProcessing() {
        deletionWakeup = true
        guard phase == .ready, closeTask == nil, operationDrain == nil,
              deletionProcessing == nil else { return }
        deletionProcessing = Task {
            defer { deletionProcessing = nil }
            while deletionWakeup, !Task.isCancelled, phase == .ready, closeTask == nil {
                deletionWakeup = false
                do {
                    let lease = try await storage.access.acquire(in: scope)
                    let requests: [MemoryDeletionRequest]
                    do { requests = try await lease.read { try await self.storage.memories.pendingMemoryDeletions(limit: 128) } }
                    catch { await lease.release(); throw error }
                    await lease.release()
                    for request in requests {
                        guard !Task.isCancelled, phase == .ready, closeTask == nil, operationDrain == nil else { return }
                        try await processDeletion(request)
                    }
                } catch {
                    // Durable requests remain pending on transient or uncertain failures.
                    // A later committed change or reopening the library retries them.
                    if !Task.isCancelled, closeTask == nil {
                        failure = MiraError.safe(error)
                        publish()
                    }
                    return
                }
            }
        }
    }

    private func processDeletion(_ request: MemoryDeletionRequest) async throws {
        if let operation = try await storage.authority.operation(id: request.id),
           operation.request == request.maintenanceRequest, operation.completedAt != nil {
            try await settleDeletion(request, state: .completed)
            return
        }
        guard let group else { throw Self.unavailable }
        let result = await group.application.waitForExecution(id: request.executionID, sessionID: request.source.sessionID)
        guard case .committed = result else { return }
        try Task.checkCancellation()
        guard phase == .ready, closeTask == nil, operationDrain == nil else { throw Self.unavailable }
        do {
            _ = try await maintain(request.maintenanceRequest)
        } catch {
            // Only a rejected, unadmitted exact-target request may be marked failed.
            // An admitted purge stays pending for maintenance recovery, even if its
            // caller observed an error after a durable completion commit.
            let code = MiraError.safe(error).code
            if (code == .conflict || code == .unauthorized || code == .notFound),
               phase == .ready, closeTask == nil,
               try await storage.authority.operation(id: request.id) == nil {
                try await settleDeletion(request, state: .failed)
                return
            }
            throw error
        }
        try Task.checkCancellation()
        try await settleDeletion(request, state: .completed)
    }

    private func settleDeletion(_ request: MemoryDeletionRequest, state: MemoryDeletionRequest.State) async throws {
        let lease = try await storage.access.acquire(in: scope)
        do {
            try await lease.check()
            try await storage.memories.settleMemoryDeletion(request, state: state, authorization: lease.authorization)
            await lease.release()
        } catch {
            await lease.release()
            throw error
        }
    }

    private func publish() { for observer in observers.values { observer.yield(status()) } }
    private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }
    private static var unavailable: MiraError { .init(.busy, "The library is not ready for new work.") }
}

private struct MacDriverModule: RuntimeModule {
    let id = "mac.drivers"
    let dependencies: Set<String> = []
    let registry: RuntimeRegistry<AgentCapability>
    func activate(in scope: RuntimeScope) async throws {
        try await registry.register(id: "mac.default-driver", value: .driver(DefaultAgentDriver()), scope: scope)
    }
}

/// HTTP support is one explicit host module; the core never enumerates these families.
struct MacHTTPModule: RuntimeModule {
    let id = "mac.http"
    let dependencies: Set<String> = []
    let registry: RuntimeRegistry<AgentCapability>
    let credentials: any CredentialReader
    func activate(in scope: RuntimeScope) async throws {
        try await registry.register(
            id: "mac.model.\(HTTPAdapterIdentity.chatCompletions.id)",
            value: .model(ChatCompletionsAdapter(credentials: credentials)), scope: scope)
        try await registry.register(
            id: "mac.configuration.\(HTTPAdapterIdentity.chatCompletions.id)",
            value: .modelConfiguration(HTTPModelConfigurationProvider(adapter: HTTPAdapterIdentity.chatCompletions)), scope: scope)
        try await registry.register(
            id: "mac.model.\(HTTPAdapterIdentity.anthropicMessages.id)",
            value: .model(try AnthropicMessagesAdapter(credentials: credentials)), scope: scope)
        try await registry.register(
            id: "mac.configuration.\(HTTPAdapterIdentity.anthropicMessages.id)",
            value: .modelConfiguration(HTTPModelConfigurationProvider(adapter: HTTPAdapterIdentity.anthropicMessages, protocolID: .anthropicMessages)), scope: scope)
        try await registry.register(
            id: "mac.model.\(HTTPAdapterIdentity.responses.id)",
            value: .model(OpenAIResponsesAdapter(credentials: credentials)), scope: scope)
        try await registry.register(
            id: "mac.configuration.\(HTTPAdapterIdentity.responses.id)",
            value: .modelConfiguration(HTTPModelConfigurationProvider(adapter: HTTPAdapterIdentity.responses, protocolID: .responses)), scope: scope)
        try await registry.register(
            id: "mac.metadata.\(ModelsDevMetadataSource.sourceID)",
            value: .modelMetadata(ModelsDevMetadataSource()), scope: scope)
        try await registry.register(
            id: "mac.probes.http", value: .modelProbe(HTTPModelProbeProvider()), scope: scope)
        for kind in HTTPModelDiscoveryProtocol.allCases {
            try await registry.register(
                id: "mac.discovery.\(kind.identity.id)",
                value: .modelDiscovery(HTTPModelDiscovery(protocolKind: kind, credentials: credentials)), scope: scope)
        }
    }
}
