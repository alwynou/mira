import Foundation
import Observation
import MiraCore
import MiraProviders

@MainActor
protocol ProviderConnectionSettingsStore: AnyObject {
    var isDemo: Bool { get }
    func credential(for connection: ProviderConnection) -> String?
    func testConnection(_ connection: ProviderConnection, previous: ProviderConnection?, secret: String,
                        model: ProviderConnectionTestModel) async throws
    func saveConnection(_ route: ProviderConnection, previous: ProviderConnection?, secret: String,
                        testModel: ProviderConnectionTestModel?) async throws -> ProviderConnection
}

@MainActor @Observable
final class ProviderConnectionSettingsModel {
    var baseURL: String { didSet { if oldValue != baseURL { invalidateDraftResult() } } }
    var secret = "" { didSet { if oldValue != secret { invalidateDraftResult() } } }
    var selectedModelID = "" { didSet { if oldValue != selectedModelID { invalidateDraftResult() } } }
    private(set) var baseline: ProviderConnection?
    private(set) var testModels: [ProviderConnectionTestModel] = []
    private(set) var isWorking = false
    private(set) var isTesting = false
    private(set) var error: MiraError?
    private(set) var statusKey: String?
    private(set) var hasStoredKey = false
    @ObservationIgnored private let container: any ProviderConnectionSettingsStore
    @ObservationIgnored private let template: CatalogProvider?
    @ObservationIgnored private let draftID: ConnectionID
    @ObservationIgnored private var latest: ProviderConnection?
    @ObservationIgnored private var didLoadCredentials = false
    @ObservationIgnored private var storedSecret = ""
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var draftRevision = 0
    @ObservationIgnored private var optionsConnection: ProviderConnection?
    @ObservationIgnored private var optionsConfiguration: ModelConfiguration?

    init(existing: ProviderConnection?, template: CatalogProvider?, container: any ProviderConnectionSettingsStore) {
        baseline = existing; latest = existing; self.template = template; self.container = container
        draftID = existing?.id ?? .init()
        baseURL = existing?.baseURL ?? template?.baseURL ?? ""
    }

    var name: String { baseline?.name ?? template?.name ?? "" }
    var displayName: String {
        baseline.map { ProviderModelCatalog.bundled.displayName(for: $0) } ?? name
    }
    var providerID: String? { template?.id }
    var isEnabled: Bool { baseline?.isEnabled ?? false }
    var hasKey: Bool { !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || hasStoredKey }
    var hasChanges: Bool {
        baseURL.trimmingCharacters(in: .whitespacesAndNewlines) != (baseline?.baseURL ?? template?.baseURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines) ||
        replacementSecret != nil
    }
    private var replacementSecret: String? {
        let value = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        return !value.isEmpty && value != storedSecret ? value : nil
    }
    var selectedModel: ProviderConnectionTestModel? { testModels.first { $0.id == selectedModelID } }
    var canTest: Bool { !container.isDemo && !isWorking && hasKey && selectedModel != nil && (try? candidate(enabled: false).validate()) != nil }
    var canSave: Bool { !container.isDemo && !isWorking && hasKey && hasChanges }

    func update(existing: ProviderConnection?, configuration: ModelConfiguration) {
        if !didLoadCredentials { refreshKeyAvailability(); didLoadCredentials = true }
        if existing != latest {
            latest = existing
            invalidateDraftResult()
            if !isWorking, !hasChanges {
                baseline = existing
                baseURL = existing?.baseURL ?? template?.baseURL ?? ""
                refreshKeyAvailability()
            }
        }
        let connection = candidate(enabled: false)
        if optionsConnection != connection || optionsConfiguration != configuration {
            updateTestModels(connection: connection, configuration: configuration)
            optionsConnection = connection
            optionsConfiguration = configuration
        }
        if !isWorking, baseline != latest, hasChanges {
            error = MiraError(.conflict, "The provider configuration changed. Discard your draft and try again.")
        }
    }

    private func updateTestModels(connection: ProviderConnection, configuration: ModelConfiguration) {
        let routes = Dictionary(uniqueKeysWithValues: configuration.routes.map { ($0.id, $0) })
        let saved = configuration.models.filter { $0.connectionID == draftID }.compactMap { model in
            routes[model.poolRouteID].map { ProviderConnectionTestModel(model: model, route: $0) }
        }
        let savedIDs = Set(saved.map(\.id))
        let provider = ProviderModelCatalog.bundled.matchingProvider(for: connection) ?? template
        let catalog = provider?.models ?? []
        let options = saved + catalog.filter { !savedIDs.contains($0.id) }.map { ProviderConnectionTestModel(catalog: $0, connection: connection) }
        let eligible = options.filter { $0.canTest(with: connection) }
        if !isWorking, let previous = selectedModel, previous.isSaved,
           eligible.first(where: { $0.id == previous.id }) != previous { cancel(); clearResult() }
        testModels = eligible
        if !testModels.contains(where: { $0.id == selectedModelID }) {
            selectedModelID = testModels.first(where: { $0.id == provider?.defaultTestModelID })?.id ?? testModels.first?.id ?? ""
        }
    }

    func discardChanges() {
        cancel(); baseline = latest; secret = ""; baseURL = baseline?.baseURL ?? template?.baseURL ?? ""
        refreshKeyAvailability(); clearResult()
    }

    func test() { perform(.test) { _ in } }
    func save(onSaved: @escaping @MainActor (ConnectionID) async -> Void) { perform(.save, onSaved: onSaved) }
    func setEnabled(_ enabled: Bool, onSaved: @escaping @MainActor (ConnectionID) async -> Void) {
        perform(enabled ? .enable : .disable, onSaved: onSaved)
    }

    func cancel() {
        generation = UUID(); operation?.cancel(); operation = nil
        if isWorking { statusKey = nil }
        isWorking = false; isTesting = false
    }

    func disappear() {
        cancel(); secret = ""; storedSecret = ""; hasStoredKey = false; didLoadCredentials = false
    }

    private enum Action { case test, save, enable, disable }

    private func perform(_ action: Action, onSaved: @escaping @MainActor (ConnectionID) async -> Void) {
        guard !isWorking, !container.isDemo else { return }
        if action != .disable, !hasKey { return }
        let previous = baseline
        var connection = candidate(enabled: action == .enable || (action == .save && isEnabled))
        if action == .disable {
            guard var existing = previous else { return }
            existing.isEnabled = false; existing.revision += 1; connection = existing
        }
        let frozenConnection = connection
        let testModel = selectedModel
        let frozenSecret = action == .disable ? "" : (replacementSecret ?? "")
        let token = UUID(); generation = token
        let frozenDraftRevision = draftRevision
        isWorking = true; isTesting = action == .test || action == .enable
        error = nil; statusKey = isTesting ? "Testing connection…" : nil
        operation = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if generation == token { isWorking = false; isTesting = false; operation = nil }
            }
            do {
                if action == .test {
                    guard let testModel else { throw MiraError(.configuration, "Select a configured text model to test this provider.") }
                    try await container.testConnection(frozenConnection, previous: previous, secret: frozenSecret, model: testModel)
                    guard isCurrent(token: token, draftRevision: frozenDraftRevision) else { return }
                    statusKey = "Connection successful"
                } else {
                    let updated = try await container.saveConnection(frozenConnection, previous: previous, secret: frozenSecret, testModel: testModel)
                    guard isCurrent(token: token, draftRevision: frozenDraftRevision) else { return }
                    baseline = updated; latest = updated
                    if action != .disable { secret = ""; baseURL = updated.baseURL }
                    refreshKeyAvailability(updateDraft: action != .disable)
                    statusKey = action == .enable ? "Connection successful" : nil
                    await onSaved(updated.id)
                }
            } catch {
                guard isCurrent(token: token, draftRevision: frozenDraftRevision) else { return }
                statusKey = nil; self.error = MiraError.safe(error)
            }
        }
    }

    private func candidate(enabled: Bool) -> ProviderConnection {
        ProviderConnection(id: draftID, revision: (baseline?.revision ?? 0) + 1, name: name,
                           providerKind: baseline?.providerKind ?? template?.providerKind ?? .openAICompatible,
                           baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
                           credentialReference: baseline?.credentialReference ?? draftID.rawValue.uuidString,
                           credentialVersion: baseline?.credentialVersion ?? 1,
                           allowsLoopbackHTTP: baseline?.allowsLoopbackHTTP ?? false, isEnabled: enabled)
    }

    private func refreshKeyAvailability(updateDraft: Bool = true) {
        storedSecret = baseline.flatMap { container.isDemo ? nil : container.credential(for: $0) } ?? ""
        hasStoredKey = !storedSecret.isEmpty
        if updateDraft { secret = storedSecret }
    }

    private func invalidateDraftResult() {
        draftRevision &+= 1
        clearResult()
    }

    private func isCurrent(token: UUID, draftRevision: Int) -> Bool {
        !Task.isCancelled && generation == token && self.draftRevision == draftRevision
    }

    private func clearResult() { statusKey = nil; error = nil }
}
