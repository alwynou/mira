import Foundation
import MiraCore
import MiraProviders
import Observation

/// Presentation state for one provider connection. Discovery and model pool
/// membership are independent: saving a connection never requires a test model
/// or a successful probe.
@MainActor @Observable
final class ProviderConnectionSettingsModel {
    var baseURL: String { didSet { if oldValue != baseURL { invalidateDraft() } } }
    var secret = "" {
        didSet { if oldValue != secret { invalidateDraft() }; if hasKey { requiresAPIKey = false } }
    }
    var protocolID: HTTPProtocolID { didSet { if oldValue != protocolID { invalidateDraft() } } }
    private(set) var baseline: AgentConfiguredConnection?
    private(set) var isWorking = false
    private(set) var isTesting = false
    private(set) var isLoadingCredentials = false
    private(set) var error: MiraError?
    private(set) var statusKey: String?
    private(set) var hasStoredKey = false
    private(set) var requiresAPIKey = false
    private var pendingEnabled: Bool?
    private var testModel: ProviderConnectionTestModel?

    @ObservationIgnored private let library: MacLibrary
    @ObservationIgnored private let isDemo: Bool
    @ObservationIgnored private let template: CatalogProvider?
    @ObservationIgnored private let draftID: ConnectionID
    @ObservationIgnored private var latest: AgentConfiguredConnection?
    @ObservationIgnored private var storedSecret = ""
    @ObservationIgnored private var credentialBaseline: AgentConfiguredConnection?
    @ObservationIgnored private var didLoadCredentials = false
    @ObservationIgnored private var credentialTask: Task<Void, Never>?
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var presentationID = UUID()
    @ObservationIgnored private var draftRevision: UInt64 = 0

    init(existing: AgentConfiguredConnection?, template: CatalogProvider?, library: MacLibrary, isDemo: Bool) {
        baseline = existing; latest = existing; self.template = template
        self.library = library; self.isDemo = isDemo; draftID = existing?.id ?? .init()
        baseURL = Self.endpoint(existing) ?? template?.baseURL ?? ""
        protocolID = Self.protocolID(for: existing) ?? template?.protocolID ?? .chatCompletions
    }

    var name: String { baseline?.name ?? template?.name ?? "Custom provider" }
    var displayName: String { baseline.map { ProviderModelCatalog.bundled.displayName(for: $0) } ?? name }
    func localizedDisplayName(locale: Locale) -> String {
        if let template, baseline?.definitionID == template.id || baseline == nil {
            return L10n.string(template.name, locale: locale)
        }
        if baseline?.definitionID == nil, name == "Custom provider" {
            return L10n.string("Custom provider", locale: locale)
        }
        return displayName
    }
    var providerID: String? { template?.id }
    var supportsEditing: Bool { true }
    var persistedBaseURL: String { Self.endpoint(baseline) ?? baseURL }
    var isEnabled: Bool { pendingEnabled ?? baseline?.isEnabled ?? false }
    var hasKey: Bool { !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || hasStoredKey }
    var hasChanges: Bool {
        baseURL.trimmingCharacters(in: .whitespacesAndNewlines) != (Self.endpoint(baseline) ?? template?.baseURL ?? "")
            || protocolID != (Self.protocolID(for: baseline) ?? template?.protocolID ?? .chatCompletions)
            || replacementSecret != nil
    }
    var canTest: Bool {
        guard !isDemo, !isWorking, !isTesting, !isLoadingCredentials, hasKey,
            let testModel,
            let draft = try? draftConnection(credential: baseline?.endpoints.first?.credential, enabled: true)
        else { return false }
        return testModel.canTest(with: draft)
    }
    var canSave: Bool {
        !isDemo && !isWorking && !isTesting && !isLoadingCredentials && hasKey && hasChanges
            && (try? draftConnection(credential: baseline?.endpoints.first?.credential)) != nil
    }

    func update(existing: AgentConfiguredConnection?, models: [AgentConfiguredModel], presets: [AgentRoutePreset]) {
        testModel = models
            .filter { $0.connectionID == existing?.id }
            .compactMap { value -> ProviderConnectionTestModel? in
                guard let preset = presets.first(where: { $0.modelDescriptorID == value.id }) else { return nil }
                return ProviderConnectionTestModel(model: value, preset: preset)
            }
            .first
        if let existing, let latest, existing.id == latest.id, existing.revision < latest.revision { return }
        if existing != latest { latest = existing; clearResult() }
        guard !isWorking else { return }
        if baseline != latest {
            if hasChanges { error = Self.conflict }
            else {
                baseline = latest; baseURL = Self.endpoint(latest) ?? template?.baseURL ?? ""
                protocolID = Self.protocolID(for: latest) ?? template?.protocolID ?? .chatCompletions
            }
        }
        loadCredentials()
    }

    func discardChanges() {
        guard !isWorking else { return }
        baseline = latest; secret = ""; storedSecret = ""; hasStoredKey = false
        baseURL = Self.endpoint(baseline) ?? template?.baseURL ?? ""
        protocolID = Self.protocolID(for: baseline) ?? template?.protocolID ?? .chatCompletions
        didLoadCredentials = false; requiresAPIKey = false; clearResult(); loadCredentials()
    }

    func test() {
        guard canTest, let testModel else { return }
        let token = presentationID
        let revision = draftRevision
        let previous = baseline
        let draft: AgentConfiguredConnection
        do {
            draft = try draftConnection(credential: previous?.endpoints.first?.credential, enabled: true)
        } catch {
            self.error = MiraError.safe(error)
            return
        }
        let replacementSecret = self.replacementSecret
        isTesting = true
        error = nil
        statusKey = nil
        operation = Task {
            defer {
                if presentationID == token { isTesting = false; operation = nil }
            }
            do {
                let binding = try await library.binding()
                try await binding.workgroup.connectionTests.test(.init(
                    connectionID: draft.id, name: draft.name, connection: draft,
                    previous: previous,
                    model: testModel.model, preset: testModel.preset,
                    isSavedModel: testModel.isSaved, replacementSecret: replacementSecret))
                guard presentationID == token, draftRevision == revision,
                    !Task.isCancelled, await isCurrent(binding) else { return }
                statusKey = "Connection test succeeded."
            } catch is CancellationError {
            } catch {
                guard presentationID == token, draftRevision == revision, !Task.isCancelled else { return }
                self.error = MiraError.safe(error)
            }
        }
    }
    func save(onSaved: @escaping @MainActor (AgentConfiguredConnection) async -> Void) { perform(.save, onSaved: onSaved) }
    func setEnabled(_ enabled: Bool, onSaved: @escaping @MainActor (AgentConfiguredConnection) async -> Void) {
        guard !isWorking, !isDemo, enabled != isEnabled else { return }
        guard !enabled || hasKey else { requiresAPIKey = true; return }
        requiresAPIKey = false; perform(enabled ? .enable : .disable, onSaved: onSaved)
    }
    func cancel() { operation?.cancel() }
    func disappear() {
        presentationID = UUID(); credentialTask?.cancel(); operation?.cancel()
        secret = ""; storedSecret = ""; hasStoredKey = false; didLoadCredentials = false; requiresAPIKey = false
    }
    func stop() async { disappear(); let read = credentialTask; let action = operation; await read?.value; await action?.value }
    func waitForAction() async { await operation?.value }
    func waitForCredentials() async { await credentialTask?.value }

    private var replacementSecret: String? {
        let value = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || value == storedSecret ? nil : value
    }

    private func loadCredentials() {
        guard !isDemo, credentialTask == nil, !isWorking,
            !didLoadCredentials || credentialBaseline != baseline else { return }
        let previous = baseline; let token = presentationID
        isLoadingCredentials = true
        credentialTask = Task {
            defer { credentialTask = nil; isLoadingCredentials = false }
            guard let previous else { didLoadCredentials = true; return }
            do {
                let binding = try await library.binding()
                let endpointID = previous.endpoints.first?.id ?? "primary"
                let value = try await binding.workgroup.credentialSettings.credential(
                    for: previous, endpointID: endpointID)
                guard presentationID == token, baseline == previous, !Task.isCancelled, await isCurrent(binding) else { return }
                storedSecret = value ?? ""; hasStoredKey = !storedSecret.isEmpty
                credentialBaseline = previous; didLoadCredentials = true
                if secret.isEmpty { secret = storedSecret }
            } catch {
                guard presentationID == token, !Task.isCancelled else { return }
                self.error = MiraError.safe(error)
            }
        }
    }

    private enum Action { case save, enable, disable }
    private func perform(_ action: Action, onSaved: @escaping @MainActor (AgentConfiguredConnection) async -> Void) {
        guard operation == nil, !isLoadingCredentials, !isDemo else { return }
        guard action == .disable || hasKey else { requiresAPIKey = true; return }
        guard baseline == latest else { error = Self.conflict; return }
        let previous = baseline
        let token = presentationID
        let revision = draftRevision
        let frozen: AgentConfiguredConnection
        let credentialChange: MacCredentialChange
        do {
            if action == .disable, let previous {
                // Disabling is an authorization change only. Keep the persisted
                // endpoint set and its per-endpoint credentials; an unsaved URL
                // or secret in the editor must not be committed by this action.
                frozen = AgentConfiguredConnection(
                    id: previous.id, revision: previous.revision + 1,
                    configurationRevision: previous.configurationRevision,
                    name: previous.name, isEnabled: false, definitionID: previous.definitionID,
                    endpoints: previous.endpoints, discovery: previous.discovery,
                    defaultInvocation: previous.defaultInvocation)
                credentialChange = .keep
            } else {
                frozen = try draftConnection(
                    credential: previous?.endpoints.first?.credential,
                    enabled: action == .enable ? true : isEnabled)
                credentialChange = replacementSecret.map(MacCredentialChange.replace) ?? .keep
            }
        } catch {
            self.error = MiraError.safe(error)
            return
        }
        let frozenName = frozen.name
        let frozenCredentialEndpointID = frozen.endpoints.first?.id ?? "primary"
        let draftBaseURL = baseURL
        let draftSecret = secret
        isWorking = true; pendingEnabled = action == .enable ? true : action == .disable ? false : nil
        error = nil; statusKey = nil
        operation = Task {
            defer { operation = nil; isWorking = false; pendingEnabled = nil; if presentationID == token { loadCredentials() } }
            do {
                let binding = try await library.binding()
                let result = try await binding.workgroup.credentialSettings.saveConnection(
                    id: draftID, name: frozenName, isEnabled: frozen.isEnabled, definitionID: frozen.definitionID,
                    endpoints: frozen.endpoints, discovery: frozen.discovery,
                    defaultInvocation: frozen.defaultInvocation, previous: previous,
                    credentialEndpointID: frozenCredentialEndpointID, credential: credentialChange)
                guard presentationID == token, draftRevision == revision, await isCurrent(binding) else { return }
                baseline = result.connection; latest = result.connection
                if action == .disable {
                    // Keep an unsaved draft visible while reflecting the new
                    // persisted baseline in the editor state.
                    baseURL = draftBaseURL
                    secret = draftSecret
                } else {
                    baseURL = Self.endpoint(result.connection) ?? baseURL
                    if case .replace(let replacement) = credentialChange {
                        storedSecret = replacement
                    }
                    secret = storedSecret
                }
                hasStoredKey = !storedSecret.isEmpty
                credentialBaseline = result.connection; didLoadCredentials = true
                if case .pending(let cleanupError) = result.cleanup { error = cleanupError }
                await onSaved(result.connection)
            } catch {
                guard presentationID == token, draftRevision == revision, !Task.isCancelled else { return }
                self.error = MiraError.safe(error)
            }
        }
    }

    private func draftConnection(credential: AgentCredentialReference?, enabled: Bool? = nil) throws -> AgentConfiguredConnection {
        let value: AgentConfiguredConnection
        if let provider = template {
            if let previous = baseline {
                value = try replacingPrimaryEndpoint(
                    in: previous, credential: credential,
                    adapter: try protocolID.adapterIdentity)
            } else {
                value = try provider.makeConnection(id: draftID, name: name, credential: credential,
                    baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        } else {
            if let previous = baseline {
                value = try replacingPrimaryEndpoint(
                    in: previous, credential: credential,
                    adapter: try protocolID.adapterIdentity)
            } else {
                let settings = HTTPConnectionSettings(baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines))
                let endpoint = AgentModelEndpoint(id: "primary",
                    configuration: .init(schema: HTTPConnectionSettings.schema.identity,
                        value: try SessionCodec.decode(JSONValue.self, from: SessionCodec.encode(settings))),
                    credential: credential)
                let adapter = try protocolID.adapterIdentity
                let invocation = try Self.invocationTemplate(protocolID: protocolID, endpointID: endpoint.id)
                value = AgentConfiguredConnection(id: draftID, revision: 1, configurationRevision: 1,
                    name: name.isEmpty ? "Custom provider" : name, isEnabled: true, definitionID: nil,
                    endpoints: [endpoint], discovery: .init(adapter: adapter, endpointID: endpoint.id),
                    defaultInvocation: invocation)
            }
        }
        guard let enabled else { return value }
        return AgentConfiguredConnection(id: value.id, revision: max(value.revision, baseline?.revision ?? 0) + 1,
            configurationRevision: max(value.configurationRevision, baseline?.configurationRevision ?? 0),
            name: value.name, isEnabled: enabled, definitionID: value.definitionID, endpoints: value.endpoints,
            discovery: value.discovery, defaultInvocation: value.defaultInvocation)
    }

    private func replacingPrimaryEndpoint(
        in previous: AgentConfiguredConnection, credential: AgentCredentialReference?, adapter: AgentAdapterIdentity
    ) throws -> AgentConfiguredConnection {
        guard let old = previous.endpoints.first else { throw MiraError(.configuration, "The provider has no endpoint.") }
        let oldSettings = try? SessionCodec.decode(
            HTTPConnectionSettings.self, from: SessionCodec.encode(old.configuration.value))
        let settings = HTTPConnectionSettings(
            baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            allowsLoopbackHTTP: oldSettings?.allowsLoopbackHTTP ?? false)
        let endpoint = AgentModelEndpoint(
            id: old.id,
            configuration: .init(schema: old.configuration.schema,
                value: try SessionCodec.decode(JSONValue.self, from: SessionCodec.encode(settings))),
            credential: credential)
        var endpoints = previous.endpoints
        endpoints[0] = endpoint
        let protocolChanged = Self.protocolID(for: previous) != protocolID
        let discovery = protocolChanged
            ? .init(
                adapter: (protocolID == .anthropicMessages
                    ? HTTPModelDiscoveryProtocol.anthropic
                    : HTTPModelDiscoveryProtocol.openAI).identity,
                endpointID: endpoint.id)
            : previous.discovery
        let invocation = try protocolChanged
            ? Self.invocationTemplate(protocolID: protocolID, endpointID: endpoint.id)
            : previous.defaultInvocation
        return AgentConfiguredConnection(
            id: previous.id, revision: previous.revision + 1,
            configurationRevision: previous.configurationRevision,
            name: previous.name, isEnabled: true, definitionID: previous.definitionID,
            endpoints: endpoints, discovery: discovery, defaultInvocation: invocation)
    }

    private static func invocationTemplate(protocolID: HTTPProtocolID, endpointID: String) throws -> AgentModelInvocationTemplate {
        let dialect: HTTPDialectProfileID = protocolID == .anthropicMessages ? .anthropic
            : protocolID == .responses ? .openAI : .generic
        let controls = HTTPInvocationSettings(protocolID: protocolID, dialectProfileID: dialect)
        return .init(adapter: try protocolID.adapterIdentity,
            endpointID: endpointID,
            configuration: .init(schema: .init(id: "mira.http.invocation", revision: 2),
                value: try SessionCodec.decode(JSONValue.self, from: SessionCodec.encode(controls))))
    }

    private func isCurrent(_ binding: MacLibraryWorkgroupBinding) async -> Bool {
        guard let current = try? await library.binding() else { return false }
        return current.status.generation == binding.status.generation && current.workgroup === binding.workgroup
    }
    private static func endpoint(_ connection: AgentConfiguredConnection?) -> String? {
        guard let endpoint = connection?.endpoints.first, case .object(let value) = endpoint.configuration.value,
            case .string(let url) = value["baseURL"] else { return nil }
        return url
    }
    private static func protocolID(for adapter: AgentAdapterIdentity?) -> HTTPProtocolID? {
        guard let adapter else { return nil }
        if adapter == HTTPAdapterIdentity.anthropicMessages { return .anthropicMessages }
        if adapter == HTTPAdapterIdentity.responses { return .responses }
        if adapter == HTTPAdapterIdentity.chatCompletions { return .chatCompletions }
        return nil
    }
    private static func protocolID(for connection: AgentConfiguredConnection?) -> HTTPProtocolID? {
        if let invocation = connection?.defaultInvocation,
            let settings = try? SessionCodec.decode(
                HTTPInvocationSettings.self, from: SessionCodec.encode(invocation.configuration.value)) {
            return settings.protocolID
        }
        return protocolID(for: connection?.defaultInvocation?.adapter)
    }
    private func invalidateDraft() { draftRevision &+= 1; clearResult() }
    private func clearResult() { statusKey = nil; error = nil }
    private static var conflict: MiraError { .init(.conflict, "The provider configuration changed. Discard your draft and try again.") }
}
