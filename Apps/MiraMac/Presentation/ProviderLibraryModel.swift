import Foundation
import MiraCore
import MiraProviders
import Observation

@MainActor @Observable
final class ProviderLibraryModel {
    private(set) var connections: [AgentConfiguredConnection] = []
    private(set) var models: [AgentConfiguredModel] = []
    private(set) var presets: [AgentRoutePreset] = []
    private(set) var workspaces: [Workspace] = []
    private(set) var conversations: [SessionQueryItem] = []
    private(set) var revision: UInt64 = 0
    private(set) var probeDescriptors: [AgentModelProbeIdentity] = []
    private(set) var probeObservation: AgentModelProbeObservation?
    private(set) var catalog: ProviderModelCatalog = .bundled

    var selectedConnectionID: ConnectionID? {
        didSet {
            guard oldValue != selectedConnectionID else { return }
            cancelDiscovery()
            cancelProbe()
            discoveredModels = []
            statusKey = nil
            error = nil
            probeObservation = nil
        }
    }

    private(set) var discoveredModels: [AgentDiscoveredModel] = []
    var error: MiraError?
    var statusKey: String?
    private(set) var isWorking = false
    private(set) var isDiscovering = false
    private(set) var isProbing = false
    private(set) var isRefreshingMetadata = false
    private(set) var hasMoreConversations = false

    @ObservationIgnored let container: AppContainer
    @ObservationIgnored private var observationTask: Task<Void, Never>?
    @ObservationIgnored private var observationRetirement: Task<Void, Never>?
    @ObservationIgnored private var changesTask: Task<Void, Never>?
    @ObservationIgnored private var changesRetirement: Task<Void, Never>?
    @ObservationIgnored private var applicationTask: Task<Void, Never>?
    @ObservationIgnored private var applicationRetirement: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshRetirement: Task<Void, Never>?
    @ObservationIgnored private var discoveryTask: Task<Void, Never>?
    @ObservationIgnored private var discoveryRetirement: Task<Void, Never>?
    @ObservationIgnored private var probeTask: Task<Void, Never>?
    @ObservationIgnored private var probeRetirement: Task<Void, Never>?
    @ObservationIgnored private var writeTasks: [UUID: Task<Void, Error>] = [:]
    @ObservationIgnored private var observationID = UUID()
    @ObservationIgnored private var lifecycleID = UUID()
    @ObservationIgnored private var discoveryID = UUID()
    @ObservationIgnored private var probeRequestID = UUID()
    @ObservationIgnored private var refreshRequest = 0
    @ObservationIgnored private var includesRoutingScopes = false
    @ObservationIgnored private var boundGeneration: UInt64?
    @ObservationIgnored private var requestedConversationRows = pageSize

    private static let pageSize = 128
    private static let maximumConnections = 128
    private static let maximumModels = 4_096
    private static let maximumPresets = 8_192
    private static let maximumConversationRows = 4_096

    init(container: AppContainer) { self.container = container }

    var selectedConnection: AgentConfiguredConnection? {
        connections.first { $0.id == selectedConnectionID }
    }

    /// Resolves the saved connection that replaces a catalog-only destination.
    func configuredConnection(forCatalogProviderID providerID: String) -> AgentConfiguredConnection? {
        guard let provider = catalog.directoryProviders.first(where: { $0.id == providerID }) else { return nil }
        return connections.first { connection in
            let directoryProvider = catalog.matchingProvider(for: connection)
                ?? catalog.directoryProviders.first { $0.name == connection.name }
            return directoryProvider?.directoryID == provider.directoryID
        }
    }

    var providerModels: [AgentConfiguredModel] {
        models.filter { $0.connectionID == selectedConnectionID }
    }

    var newDiscoveredModels: [AgentDiscoveredModel] {
        let saved = Set(providerModels.map(\.modelID))
        return discoveredModels.filter { !saved.contains($0.id) }
    }

    var newCatalogModels: [CatalogModel] {
        guard let selectedConnection else { return [] }
        let existing = Set(providerModels.map(\.modelID) + discoveredModels.map(\.id))
        return catalog.models(for: selectedConnection)
            .filter { !existing.contains($0.id) }
    }

    func observe(includeRoutingScopes: Bool) async {
        let id = UUID()
        observationID = id
        self.includesRoutingScopes = includeRoutingScopes
        let previous = observationTask
        observationTask = nil
        previous?.cancel()
        let oldRetirement = observationRetirement
        observationRetirement = Task {
            await oldRetirement?.value
            await previous?.value
        }
        await observationRetirement?.value
        guard !Task.isCancelled, observationID == id, let library = container.library else { return }

        let task = Task { @MainActor [weak self, library] in
            guard let self else { return }
            defer {
                if observationID == id { boundGeneration = nil }
                let changes = changesTask
                changesTask = nil
                changes?.cancel()
                let previous = changesRetirement
                changesRetirement = Task {
                    await previous?.value
                    await changes?.value
                }
                let application = applicationTask
                applicationTask = nil
                application?.cancel()
                let applicationPrevious = applicationRetirement
                applicationRetirement = Task {
                    await applicationPrevious?.value
                    await application?.value
                }
            }
            for await status in await library.observe() {
                guard !Task.isCancelled, observationID == id, container.library === library else { return }
                guard status.phase == .ready else {
                    boundGeneration = nil
                    clearPublishedValues()
                    continue
                }
                boundGeneration = status.generation
                await bindChanges(library: library, generation: status.generation, observationID: id)
                await bindApplication(library: library, generation: status.generation, observationID: id)
                await refresh()
            }
        }
        observationTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if observationID == id { observationTask = nil }
    }

    func refresh(ifMissing savedConnection: AgentConfiguredConnection? = nil) async {
        if let savedConnection,
            connections.contains(where: {
                $0.id == savedConnection.id && $0.revision >= savedConnection.revision
            })
        {
            return
        }
        refreshRequest &+= 1
        if let refreshTask {
            await refreshTask.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            repeat {
                let request = refreshRequest
                await readCurrentWorkgroup(request: request)
                if request == refreshRequest || Task.isCancelled { break }
            } while true
            refreshTask = nil
        }
        refreshTask = task
        await task.value
    }

    func loadMoreConversations() async {
        guard includesRoutingScopes, hasMoreConversations, container.library != nil else { return }
        guard requestedConversationRows < Self.maximumConversationRows else { return }
        requestedConversationRows = min(
            requestedConversationRows + Self.pageSize, Self.maximumConversationRows)
        await refresh()
    }

    func stopRequests() async {
        lifecycleID = UUID()
        observationID = UUID()
        boundGeneration = nil
        let observation = observationTask
        observationTask = nil
        observation?.cancel()
        let changes = changesTask
        changesTask = nil
        changes?.cancel()
        let application = applicationTask
        applicationTask = nil
        application?.cancel()
        cancelDiscovery()
        cancelProbe()
        refreshTask?.cancel()
        let refresh = refreshTask
        let retirements = [
            observationRetirement, changesRetirement, refreshRetirement,
            applicationRetirement, discoveryRetirement, probeRetirement,
        ].compactMap { $0 }
        for retirement in retirements { await retirement.value }
        if let observation { await observation.value }
        if let changes { await changes.value }
        if let application { await application.value }
        if let refresh { await refresh.value }
        if let discoveryTask { await discoveryTask.value }
        if let probeTask { await probeTask.value }
        for task in writeTasks.values { _ = await task.result }
    }

    func addCatalogModel(_ item: CatalogModel, connection: AgentConfiguredConnection) async {
        guard !isWorking, !container.isDemo else { return }
        let entry: ProviderConnectionTestModel
        do { entry = try ProviderConnectionTestModel(catalog: item, connection: connection) } catch {
            self.error = MiraError.safe(error)
            return
        }
        guard let library = container.library else {
            error = unavailable
            return
        }
        isWorking = true
        error = nil
        statusKey = nil
        defer { isWorking = false }
        let lifecycle = lifecycleID
        do {
            let binding = try await library.binding()
            let current = try await binding.workgroup.modelSettings.connection(id: connection.id)
            guard current == connection, connection.isEnabled else {
                throw MiraError(.conflict, "The provider configuration changed. Discard this draft and try again.")
            }
            try await acceptedWrite {
                try await binding.workgroup.modelSettings.savePoolModel(
                    entry.model, preset: entry.preset,
                    expectedModelRevision: nil, expectedPresetRevision: nil)
            }
            guard await isCurrent(binding, library: library, lifecycleID: lifecycle) else { return }
            await refresh()
        } catch {
            guard lifecycleID == lifecycle else { return }
            self.error = MiraError.safe(error)
        }
    }

    func setModelEnabled(_ enabled: Bool, model: AgentConfiguredModel) async {
        guard !isWorking, !container.isDemo, let library = container.library else { return }
        guard model.isEnabled != enabled else { return }
        guard model.revision < Int.max else {
            error = MiraError(.conflict, "The model revision cannot be advanced further.")
            return
        }
        let updated = AgentConfiguredModel(
            id: model.id, revision: model.revision + 1, authorizationRevision: model.authorizationRevision + 1,
            reference: model.reference, displayName: model.displayName, isEnabled: enabled,
            invocations: model.invocations, facts: model.facts)
        isWorking = true
        error = nil
        statusKey = nil
        defer { isWorking = false }
        let lifecycle = lifecycleID
        do {
            let binding = try await library.binding()
            try await acceptedWrite {
                try await binding.workgroup.modelSettings.saveModel(
                    updated, expectedRevision: model.revision)
            }
            guard await isCurrent(binding, library: library, lifecycleID: lifecycle) else { return }
            await refresh()
        } catch {
            guard lifecycleID == lifecycle else { return }
            self.error = MiraError.safe(error)
        }
    }

    func removeModel(_ model: AgentConfiguredModel) async {
        guard !isWorking, !container.isDemo, let library = container.library else { return }
        isWorking = true
        error = nil
        statusKey = nil
        defer { isWorking = false }
        let lifecycle = lifecycleID
        do {
            let binding = try await library.binding()
            try await acceptedWrite {
                try await binding.workgroup.modelSettings.deleteModel(
                    id: model.id, expectedRevision: model.revision)
            }
            guard await isCurrent(binding, library: library, lifecycleID: lifecycle) else { return }
            await refresh()
        } catch {
            guard lifecycleID == lifecycle else { return }
            self.error = MiraError.safe(error)
        }
    }

    func discoverModels() {
        guard !container.isDemo, !isDiscovering, let connection = selectedConnection,
            connection.isEnabled, let library = container.library
        else { return }
        guard let adapter = connection.discovery?.adapter else {
            error = MiraError(.configuration, "Model discovery is not configured for this connection.")
            return
        }
        cancelDiscovery()
        let token = UUID()
        discoveryID = token
        let lifecycle = lifecycleID
        isDiscovering = true
        error = nil
        statusKey = nil
        discoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if discoveryID == token {
                    isDiscovering = false
                    discoveryTask = nil
                }
            }
            do {
                let binding = try await library.binding()
                let result = try await binding.workgroup.discovery.discover(
                    connectionID: connection.id, adapter: adapter)
                guard !Task.isCancelled, discoveryID == token, self.lifecycleID == lifecycle,
                    container.library === library
                else { return }
                let current = try await library.binding()
                guard current.workgroup === binding.workgroup, self.lifecycleID == lifecycle else { return }
                discoveredModels = result.models
                statusKey =
                    result.models.isEmpty
                    ? "The provider returned no models. You can add a model manually." : nil
            } catch is CancellationError {
                return
            } catch {
                guard discoveryID == token, self.lifecycleID == lifecycle else { return }
                self.error = MiraError.safe(error)
            }
        }
    }

    /// Refreshes the advisory catalog only when the user asks for it. Startup reads
    /// the last complete snapshot from the local metadata cache.
    func refreshModelInformation() async {
        guard !isWorking, !isRefreshingMetadata, !container.isDemo, let library = container.library else { return }
        isRefreshingMetadata = true
        error = nil
        statusKey = nil
        let lifecycle = lifecycleID
        defer { isRefreshingMetadata = false }
        do {
            let binding = try await library.binding()
            let snapshot = try await binding.workgroup.modelMetadata.refresh(sourceID: ModelsDevMetadataSource.sourceID)
            let updated = try ProviderModelCatalog(data: SessionCodec.encode(snapshot.document.payload))
            guard lifecycleID == lifecycle, container.library === library,
                (try await library.binding()).workgroup === binding.workgroup else { return }
            catalog = updated
            statusKey = "Model information updated."
            await refresh()
        } catch is CancellationError {
        } catch {
            guard lifecycleID == lifecycle else { return }
            self.error = MiraError.safe(error)
        }
    }

    func cancelDiscovery() {
        discoveryID = UUID()
        isDiscovering = false
        guard let task = discoveryTask else { return }
        discoveryTask = nil
        task.cancel()
        let previous = discoveryRetirement
        discoveryRetirement = Task {
            await previous?.value
            await task.value
        }
    }

    func probe(_ model: AgentConfiguredModel, probeID: String) {
        guard !container.isDemo, !isProbing, let library = container.library,
            let preset = presets.first(where: { $0.modelDescriptorID == model.id }),
            let connection = connections.first(where: { $0.id == model.connectionID })
        else { return }
        cancelProbe()
        let token = UUID()
        probeRequestID = token
        let lifecycle = lifecycleID
        isProbing = true
        error = nil
        statusKey = "Testing with synthetic content only, without conversation history…"
        probeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if probeRequestID == token {
                    isProbing = false
                    probeTask = nil
                }
            }
            do {
                let binding = try await library.binding()
                let observation = try await binding.workgroup.probes.probe(
                    routeID: preset.id, probeID: probeID)
                guard !Task.isCancelled, probeRequestID == token, self.lifecycleID == lifecycle,
                    container.library === library
                else { return }
                let current = try await library.binding()
                guard current.workgroup === binding.workgroup, self.lifecycleID == lifecycle,
                    connection == connections.first(where: { $0.id == connection.id }),
                    model == models.first(where: { $0.id == model.id }),
                    preset == presets.first(where: { $0.id == preset.id }),
                    observation.candidate.connection == connection,
                    observation.candidate.preset == preset,
                    observation.candidate.model.id == model.id,
                    observation.candidate.model.revision == model.revision,
                    observation.candidate.model.connectionID == model.connectionID,
                    observation.candidate.model.reference == model.reference
                else {
                    probeObservation = nil
                    return
                }
                probeObservation = observation
                statusKey =
                    observation.outcome == .verified
                    ? "Capability test passed. Save the observation to keep it."
                    : "Capability test failed; save the observation to record it."
            } catch is CancellationError {
                return
            } catch {
                guard probeRequestID == token, self.lifecycleID == lifecycle else { return }
                self.error = MiraError.safe(error)
            }
        }
    }

    func saveProbeObservation() async {
        guard !isWorking, let observation = probeObservation, let library = container.library else { return }
        isWorking = true
        error = nil
        defer { isWorking = false }
        let lifecycle = lifecycleID
        do {
            let binding = try await library.binding()
            try await acceptedWrite { try await binding.workgroup.probes.save(observation) }
            let current = try await library.binding()
            guard lifecycleID == lifecycle, container.library === library, current.workgroup === binding.workgroup
            else {
                probeObservation = nil
                return
            }
            probeObservation = nil
            statusKey = "Capability test observation saved."
            await refresh()
        } catch {
            guard lifecycleID == lifecycle else { return }
            self.error = MiraError.safe(error)
        }
    }

    func cancelProbe() {
        probeRequestID = UUID()
        probeObservation = nil
        isProbing = false
        guard let task = probeTask else { return }
        probeTask = nil
        task.cancel()
        let previous = probeRetirement
        probeRetirement = Task {
            await previous?.value
            await task.value
        }
    }

    private func bindChanges(library: MacLibrary, generation: UInt64, observationID id: UUID) async {
        guard let binding = try? await library.binding(), binding.status.generation == generation else { return }
        guard changesTask == nil || changesTask?.isCancelled == true else { return }
        let previous = changesTask
        changesTask = nil
        previous?.cancel()
        let oldRetirement = changesRetirement
        changesRetirement = Task {
            await oldRetirement?.value
            await previous?.value
        }
        await changesRetirement?.value
        guard observationID == id, boundGeneration == generation, container.library === library else { return }
        let group = binding.workgroup
        guard let stream = try? await group.changes.observe() else { return }
        changesTask = Task { @MainActor [weak self, stream] in
            guard let self else { return }
            for await event in stream {
                guard !Task.isCancelled, observationID == id, boundGeneration == generation,
                    container.library === library
                else { return }
                if event.isClosed { return }
                await refresh()
            }
        }
    }

    private func bindApplication(
        library: MacLibrary, generation: UInt64, observationID id: UUID
    ) async {
        guard includesRoutingScopes else { return }
        guard applicationTask == nil || applicationTask?.isCancelled == true else { return }
        let previous = applicationTask
        applicationTask = nil
        previous?.cancel()
        let oldRetirement = applicationRetirement
        applicationRetirement = Task {
            await oldRetirement?.value
            await previous?.value
        }
        await applicationRetirement?.value
        guard observationID == id, boundGeneration == generation, container.library === library else { return }
        do {
            let binding = try await library.binding()
            guard binding.status.generation == generation else { return }
            let group = binding.workgroup
            let stream = try await group.application.observe()
            applicationTask = Task { @MainActor [weak self, stream] in
                guard let self else { return }
                for await snapshot in stream {
                    guard !Task.isCancelled, observationID == id, boundGeneration == generation,
                        container.library === library
                    else { return }
                    guard snapshot.phase == .ready else { continue }
                    await refresh()
                }
            }
        } catch {
            guard observationID == id, boundGeneration == generation else { return }
            self.error = MiraError.safe(error)
        }
    }

    private func readCurrentWorkgroup(request: Int) async {
        guard let library = container.library else { return }
        let lifecycle = lifecycleID
        let discoveryConnectionID = selectedConnectionID
        do {
            let binding = try await library.binding()
            let group = binding.workgroup
            let connections = try await readConnections(group.modelSettings)
            let models = try await readModels(group.modelSettings)
            let presets = try await readPresets(group.modelSettings)
            let workspaces = includesRoutingScopes ? try await group.workspaces.workspaces() : []
            let conversations: [SessionQueryItem]
            let nextHasMore: Bool
            if includesRoutingScopes {
                try await group.queries.synchronizeLibrary()
                var rows: [SessionQueryItem] = []
                var seen = Set<ConversationID>()
                var after: SessionListCursor?
                while rows.count < requestedConversationRows {
                    let page = try await group.queries.sessions(
                        includeArchived: true, after: after, limit: Self.pageSize)
                    try validateSessions(page)
                    for row in page {
                        guard seen.insert(row.id).inserted else { throw pageError }
                    }
                    rows.append(contentsOf: page)
                    guard page.count == Self.pageSize, let last = page.last else { break }
                    guard after?.sessionID != last.id else { throw pageError }
                    after = .init(updatedAt: last.summary.updatedAt, sessionID: last.id)
                }
                conversations = rows
                nextHasMore = rows.count >= requestedConversationRows
                    && rows.count < Self.maximumConversationRows
                    && rows.count % Self.pageSize == 0
            } else {
                conversations = []
                nextHasMore = false
            }
            let probes = try await group.probes.descriptors()
            let cachedCatalog: ProviderModelCatalog
            if let snapshot = try await group.modelMetadata.snapshot(sourceID: ModelsDevMetadataSource.sourceID),
               let value = try? ProviderModelCatalog(data: SessionCodec.encode(snapshot.document.payload)) {
                cachedCatalog = value
            } else {
                cachedCatalog = .bundled
            }
            let current = try await library.binding()
            guard !Task.isCancelled, lifecycleID == lifecycle, request == refreshRequest,
                container.library === library,
                current.status.generation == binding.status.generation,
                current.workgroup === group
            else { return }
            let settingsChanged = self.connections != connections || self.models != models || self.presets != presets
            if settingsChanged {
                cancelDiscovery()
                cancelProbe()
            }
            self.connections = connections
            self.models = models
            self.presets = presets
            self.workspaces = workspaces
            self.conversations = conversations
            self.probeDescriptors = probes
            self.catalog = cachedCatalog
            self.hasMoreConversations = nextHasMore
            if selectedConnectionID == nil || !connections.contains(where: { $0.id == selectedConnectionID }) {
                selectedConnectionID = connections.first?.id
            }
            if selectedConnectionID == discoveryConnectionID,
                let selectedConnectionID = discoveryConnectionID,
                let selectedConnection = connections.first(where: { $0.id == selectedConnectionID }),
                let snapshot = try? await group.modelSettings.discoverySnapshot(connectionID: selectedConnectionID),
                snapshot.connectionID == selectedConnection.id,
                snapshot.configurationRevision == selectedConnection.configurationRevision,
                snapshot.adapter == selectedConnection.discovery?.adapter {
                discoveredModels = snapshot.models
            } else {
                discoveredModels = []
            }
            revision &+= 1
            error = nil
        } catch is CancellationError {
            return
        } catch {
            guard lifecycleID == lifecycle else { return }
            self.error = MiraError.safe(error)
        }
    }

    private func acceptedWrite(_ operation: @escaping @Sendable () async throws -> Void) async throws {
        let id = UUID()
        let task = Task { try await operation() }
        writeTasks[id] = task
        defer { writeTasks[id] = nil }
        try await task.value
    }

    private func isCurrent(
        _ binding: MacLibraryWorkgroupBinding, library: MacLibrary, lifecycleID token: UUID
    ) async -> Bool {
        guard !Task.isCancelled, lifecycleID == token, container.library === library,
            let current = try? await library.binding()
        else { return false }
        return current.status.generation == binding.status.generation
            && current.workgroup === binding.workgroup
    }

    private func clearPublishedValues() {
        cancelDiscovery()
        cancelProbe()
        boundGeneration = nil
        retireChangesObserver()
        retireApplicationObserver()
        connections = []
        models = []
        presets = []
        workspaces = []
        conversations = []
        probeDescriptors = []
        catalog = .bundled
        probeObservation = nil
        discoveredModels = []
        requestedConversationRows = Self.pageSize
        hasMoreConversations = false
        revision &+= 1
    }

    private func retireChangesObserver() {
        let task = changesTask
        changesTask = nil
        task?.cancel()
        let previous = changesRetirement
        changesRetirement = Task {
            await previous?.value
            await task?.value
        }
    }

    private func retireApplicationObserver() {
        let task = applicationTask
        applicationTask = nil
        task?.cancel()
        let previous = applicationRetirement
        applicationRetirement = Task {
            await previous?.value
            await task?.value
        }
    }

    private func readConnections(_ settings: any MacModelSettings) async throws -> [AgentConfiguredConnection] {
        var result: [AgentConfiguredConnection] = []
        var after: ConnectionID?
        var seen = Set<ConnectionID>()
        while true {
            let page = try await settings.connections(after: after, limit: Self.pageSize)
            guard page.count <= Self.pageSize else { throw pageError }
            for value in page { guard seen.insert(value.id).inserted else { throw pageError } }
            result.append(contentsOf: page)
            guard result.count <= Self.maximumConnections else { throw pageError }
            guard page.count == Self.pageSize, let last = page.last else { break }
            guard after?.rawValue.uuidString != last.id.rawValue.uuidString else { throw pageError }
            after = last.id
        }
        return result
    }

    private func readModels(_ settings: any MacModelSettings) async throws -> [AgentConfiguredModel] {
        var result: [AgentConfiguredModel] = []
        var after: ModelDescriptorID?
        var seen = Set<ModelDescriptorID>()
        while true {
            let page = try await settings.models(connectionID: nil, after: after, limit: Self.pageSize)
            guard page.count <= Self.pageSize else { throw pageError }
            for value in page { guard seen.insert(value.id).inserted else { throw pageError } }
            result.append(contentsOf: page)
            guard result.count <= Self.maximumModels else { throw pageError }
            guard page.count == Self.pageSize, let last = page.last else { break }
            guard after?.rawValue.uuidString != last.id.rawValue.uuidString else { throw pageError }
            after = last.id
        }
        return result
    }

    private func readPresets(_ settings: any MacModelSettings) async throws -> [AgentRoutePreset] {
        var result: [AgentRoutePreset] = []
        var after: RouteID?
        var seen = Set<RouteID>()
        while true {
            let page = try await settings.presets(modelID: nil, after: after, limit: Self.pageSize)
            guard page.count <= Self.pageSize else { throw pageError }
            for value in page { guard seen.insert(value.id).inserted else { throw pageError } }
            result.append(contentsOf: page)
            guard result.count <= Self.maximumPresets else { throw pageError }
            guard page.count == Self.pageSize, let last = page.last else { break }
            guard after?.rawValue.uuidString != last.id.rawValue.uuidString else { throw pageError }
            after = last.id
        }
        return result
    }

    private func validateSessions(_ page: [SessionQueryItem]) throws {
        guard page.count <= Self.pageSize, Set(page.map(\.id)).count == page.count else { throw pageError }
    }

    private var pageError: MiraError { .init(.storage, "The settings page exceeded its bounded result contract.") }
    private var unavailable: MiraError { .init(.storage, "The library is not open.") }
}
