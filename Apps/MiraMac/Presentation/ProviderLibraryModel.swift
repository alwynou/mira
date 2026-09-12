import Foundation
import Observation
import MiraCore
import MiraProviders

@MainActor @Observable
final class ProviderLibraryModel {
    private(set) var configuration = ModelConfiguration(connections: [], models: [], routes: [], bindings: [])
    private(set) var workspaces: [Workspace] = []
    private(set) var conversations: [Conversation] = []
    var selectedConnectionID: ConnectionID? {
        didSet { if oldValue != selectedConnectionID { cancelDiscovery(); cancelProbe(); discoveredModels = []; statusKey = nil; error = nil } }
    }
    private(set) var discoveredModels: [DiscoveredModel] = []
    var error: MiraError?
    var statusKey: String?
    private(set) var isWorking = false
    private(set) var isDiscovering = false
    private(set) var isProbing = false
    @ObservationIgnored let container: AppContainer
    @ObservationIgnored private var discoveryTask: Task<Void, Never>?
    @ObservationIgnored private var probeTask: Task<Void, Never>?
    @ObservationIgnored private var probeGeneration = UUID()
    @ObservationIgnored private var probeSnapshot: ResolvedModelRouteSnapshot?
    @ObservationIgnored private var discoveryGeneration = UUID()
    @ObservationIgnored private var includesRoutingScopes = false
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshVersion = 0
    @ObservationIgnored private var refreshIncludesRoutingScopes = false

    init(container: AppContainer) { self.container = container }

    var selectedConnection: ProviderConnection? { configuration.connections.first { $0.id == selectedConnectionID } }
    var providerModels: [ModelDescriptor] { configuration.models.filter { $0.connectionID == selectedConnectionID } }
    var newDiscoveredModels: [DiscoveredModel] {
        let saved = Set(providerModels.map(\.modelID))
        return discoveredModels.filter { !saved.contains($0.id) }
    }

    var newCatalogModels: [CatalogModel] {
        guard let selectedConnection else { return [] }
        let existingIDs = Set(providerModels.map(\.modelID) + discoveredModels.map(\.id))
        return ProviderModelCatalog.bundled.models(for: selectedConnection).filter { !existingIDs.contains($0.id) }
    }

    func observe(includeRoutingScopes: Bool) async {
        guard let application = container.application else { return }
        includesRoutingScopes = includeRoutingScopes
        let events = await application.events()
        for await event in events {
            if Task.isCancelled { return }
            switch event {
            case .changed:
                await refresh()
            case .configurationChanged:
                await refresh(configurationOnly: true)
            case .conversationChanged, .conversationContentInvalidated:
                if includeRoutingScopes { await refresh() }
            default: break
            }
        }
    }

    func refresh(ifMissing savedConnection: ProviderConnection? = nil, configurationOnly: Bool = false) async {
        if let savedConnection, configuration.connections.contains(where: {
            $0.id == savedConnection.id && $0.revision >= savedConnection.revision
        }) { return }
        // Events can arrive while a query is suspended. Keep one reader and repeat
        // only when another refresh was requested before its result was installed.
        refreshVersion &+= 1
        refreshIncludesRoutingScopes = refreshIncludesRoutingScopes || (includesRoutingScopes && !configurationOnly && savedConnection == nil)
        if let refreshTask { await refreshTask.value; return }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { refreshTask = nil; refreshIncludesRoutingScopes = false }
            repeat {
                let version = refreshVersion
                await loadConfiguration(includeRoutingScopes: refreshIncludesRoutingScopes)
                if version == refreshVersion { break }
            } while !Task.isCancelled
        }
        refreshTask = task
        await task.value
    }

    private func loadConfiguration(includeRoutingScopes: Bool) async {
        guard let application = container.application else { return }
        do {
            let previous = selectedConnection
            if includeRoutingScopes {
                let library = try await application.library(includeArchived: true)
                if configuration != library.configuration { configuration = library.configuration }
                if workspaces != library.workspaces { workspaces = library.workspaces }
                if conversations != library.conversations { conversations = library.conversations }
            } else {
                let updated = try await application.modelConfiguration()
                if configuration != updated { configuration = updated }
            }
            if let probeSnapshot, (try? configuration.snapshot(routeID: probeSnapshot.id)) != probeSnapshot {
                cancelProbe()
            }
            if selectedConnectionID == nil || selectedConnection == nil {
                selectedConnectionID = configuration.connections.first?.id
            } else if previous != selectedConnection {
                cancelDiscovery(); discoveredModels = []
            }
        } catch { self.error = MiraError.safe(error) }
    }

    func addCatalogModel(_ item: CatalogModel, connection: ProviderConnection) async {
        guard let application = container.application, !isWorking, !container.isDemo else { return }
        cancelProbe()
        isWorking = true; error = nil; statusKey = nil
        defer { isWorking = false }
        do {
            let current = try await application.modelConfiguration()
            guard current.connections.first(where: { $0.id == connection.id }) == connection, connection.isEnabled else {
                throw MiraError(.conflict, "The provider configuration changed. Discard your draft and try again.")
            }
            let entry = ProviderConnectionTestModel(catalog: item, connection: connection)
            try entry.snapshot(for: connection).validateForSending()
            try await application.savePoolModel(entry.model, route: entry.route, expectedModelRevision: nil, expectedRouteRevision: nil)
            await refresh()
        } catch { self.error = MiraError.safe(error) }
    }

    func setModelEnabled(_ enabled: Bool, model: ModelDescriptor) async {
        guard let application = container.application, !isWorking, !container.isDemo else { return }
        cancelProbe()
        isWorking = true; error = nil; statusKey = nil
        defer { isWorking = false }
        do {
            var updated = model
            updated.isEnabled = enabled; updated.revision += 1
            try await application.saveModel(updated, expectedRevision: model.revision)
            await refresh()
        } catch { self.error = MiraError.safe(error) }
    }

    func removeModel(_ model: ModelDescriptor) async {
        guard let application = container.application, !isWorking, !container.isDemo else { return }
        cancelProbe()
        isWorking = true; error = nil
        defer { isWorking = false }
        do { try await application.removeModel(model.id); await refresh() }
        catch { self.error = MiraError.safe(error) }
    }

    func discoverModels() {
        guard let connection = selectedConnection, connection.isEnabled, !container.isDemo else { return }
        cancelDiscovery()
        let generation = UUID()
        discoveryGeneration = generation; isDiscovering = true; error = nil; statusKey = nil
        discoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if discoveryGeneration == generation { isDiscovering = false; discoveryTask = nil }
            }
            do {
                let models = try await container.discoverModels(for: connection)
                guard !Task.isCancelled, discoveryGeneration == generation, selectedConnection == connection else { return }
                discoveredModels = models
                statusKey = models.isEmpty ? "The provider returned no models. You can add a model manually." : nil
            } catch {
                guard !Task.isCancelled, discoveryGeneration == generation else { return }
                self.error = MiraError.safe(error)
            }
        }
    }

    func cancelDiscovery() {
        discoveryGeneration = UUID(); discoveryTask?.cancel(); discoveryTask = nil; isDiscovering = false
    }

    func stopRequests() { cancelDiscovery(); cancelProbe() }

    func probe(_ model: ModelDescriptor, kind: CapabilityProbeKind) {
        guard !container.isDemo, !isProbing else { return }
        do {
            let snapshot = try configuration.snapshot(routeID: model.poolRouteID)
            let generation = UUID()
            probeGeneration = generation; probeSnapshot = snapshot
            isProbing = true; error = nil
            statusKey = "Testing with synthetic content only, without conversation history…"
            probeTask = Task { @MainActor [weak self] in
                guard let self else { return }
                defer { if probeGeneration == generation { isProbing = false; probeTask = nil; probeSnapshot = nil } }
                let observation = await container.probe(snapshot, kind: kind)
                guard !Task.isCancelled, probeGeneration == generation else { return }
                guard observation.state != .unknown else {
                    error = observation.error ?? MiraError(.configuration, "Capability test failed."); return
                }
                do {
                    probeSnapshot = nil
                    try await container.saveProbe(observation, for: snapshot)
                    guard probeGeneration == generation, !Task.isCancelled else { return }
                    statusKey = observation.state == .verified ? "Capability test passed and was saved." : "Capability test failed; status was recorded."
                    await refresh()
                } catch { if probeGeneration == generation, !Task.isCancelled { self.error = MiraError.safe(error) } }
            }
        } catch { self.error = MiraError.safe(error) }
    }

    func cancelProbe() {
        probeGeneration = UUID(); probeSnapshot = nil
        probeTask?.cancel(); probeTask = nil
        if isProbing { statusKey = "Test cancelled." }
        isProbing = false
    }
}
