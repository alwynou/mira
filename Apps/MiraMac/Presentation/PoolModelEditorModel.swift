import Foundation
import MiraCore
import MiraProviders
import Observation

@MainActor @Observable
final class PoolModelEditorModel {
    @ObservationIgnored let existing: AgentConfiguredModel?
    @ObservationIgnored let connection: AgentConfiguredConnection
    @ObservationIgnored let initialModelID: String
    @ObservationIgnored let library: MacLibrary
    @ObservationIgnored let isDemo: Bool
    @ObservationIgnored private let onSaved: @MainActor () async -> Void

    var modelID: String
    var contextWindowText: String { didSet { if !isApplyingDraft { contextEdited = true } } }
    var maxOutputTokensText: String { didSet { if !isApplyingDraft { outputEdited = true } } }
    var requestsUsage = true { didSet { if !isApplyingDraft { requestsUsageEdited = true } } }
    var storeResponses = false { didSet { if !isApplyingDraft { storeResponsesEdited = true } } }
    var thinkingMode = "providerDefault" { didSet { if !isApplyingDraft { thinkingModeEdited = true } } }
    var thinkingEffort = "" { didSet { if !isApplyingDraft { thinkingEffortEdited = true } } }
    var thinkingBudgetText = "" { didSet { if !isApplyingDraft { thinkingBudgetEdited = true } } }
    var isEnabled: Bool
    var textDeclared: Bool { didSet { if !isApplyingDraft { capabilitiesEdited = true } } }
    var toolsDeclared: Bool { didSet { if !isApplyingDraft { capabilitiesEdited = true } } }
    var jsonDeclared: Bool { didSet { if !isApplyingDraft { capabilitiesEdited = true } } }
    var advancedOptions = false
    private(set) var invocation: AgentModelInvocationSpec?
    private(set) var invocationChoices: [AgentModelInvocationSpec] = []
    private(set) var descriptors: [AgentModelConfigurationDescriptor] = []
    private(set) var catalogMetadata: CatalogModelMetadata?
    private(set) var unsupportedError: MiraError?
    private(set) var isLoading = false
    private(set) var isSaving = false
    private(set) var statusKey: String?
    private(set) var error: MiraError?
    private(set) var saveConfirmation = 0
    private(set) var isStopped = false

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var baselineModel: AgentConfiguredModel?
    @ObservationIgnored private var baselinePreset: AgentRoutePreset?
    @ObservationIgnored private var draftFacts: [AgentModelMetadataFact] = []
    @ObservationIgnored private var rawInvocation: AgentModelInvocationSpec?
    @ObservationIgnored private var isApplyingDraft = true
    @ObservationIgnored private var contextEdited = false
    @ObservationIgnored private var outputEdited = false
    @ObservationIgnored private var capabilitiesEdited = false
    @ObservationIgnored private var requestsUsageEdited = false
    @ObservationIgnored private var storeResponsesEdited = false
    @ObservationIgnored private var thinkingModeEdited = false
    @ObservationIgnored private var thinkingEffortEdited = false
    @ObservationIgnored private var thinkingBudgetEdited = false
    @ObservationIgnored private var reloadID = UUID()

    init(existing: AgentConfiguredModel?, connection: AgentConfiguredConnection, preset: AgentRoutePreset?,
         initialModelID: String, library: MacLibrary, isDemo: Bool,
         onSaved: @MainActor @escaping () async -> Void) {
        self.existing = existing; self.connection = connection; self.initialModelID = initialModelID
        self.library = library; self.isDemo = isDemo; self.onSaved = onSaved
        modelID = existing?.modelID ?? initialModelID
        contextWindowText = ""; maxOutputTokensText = preset.map { String($0.maximumOutputTokens) } ?? "4096"
        isEnabled = existing?.isEnabled ?? true
        textDeclared = existing?.invocations.contains(where: { $0.supports(AgentModelCapabilityID.streamingText) }) ?? false
        toolsDeclared = existing?.invocations.contains(where: { $0.supports(AgentModelCapabilityID.toolCalls) }) ?? false
        jsonDeclared = existing?.invocations.contains(where: { $0.supports(AgentModelCapabilityID.jsonOutput) }) ?? false
        baselineModel = existing; baselinePreset = preset
        isApplyingDraft = false
    }

    var unsupportedMessage: String? { unsupportedError?.message }
    var canSave: Bool {
        !isStopped && !isDemo && !isSaving && !isLoading && unsupportedError == nil
            && !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && invocation != nil
            && hasValidNumericLimits && hasValidThinkingBudget
    }
    var isUnsupported: Bool { unsupportedMessage != nil }
    var invocationTitle: String { invocation.map { $0.adapter.id } ?? "" }
    var selectedInvocationID: String { invocation?.id ?? "" }
    func selectInvocation(_ id: String) {
        guard let selected = invocationChoices.first(where: { $0.id == id }) else { return }
        reloadID = UUID()
        rawInvocation = selected
        let resolved = try? AgentModelMetadataResolver.resolve(selected, facts: draftFacts)
        isApplyingDraft = true
        invocation = resolved
        contextWindowText = resolved?.contextWindow.map(String.init) ?? ""
        textDeclared = resolved?.supports(AgentModelCapabilityID.streamingText) == true
        toolsDeclared = resolved?.supports(AgentModelCapabilityID.toolCalls) == true
        jsonDeclared = resolved?.supports(AgentModelCapabilityID.jsonOutput) == true
        if let resolved {
            let maximum = min(
                resolved.maximumOutputTokens ?? Int.max,
                resolved.contextWindow.map { max(1, $0 - 1) } ?? Int.max)
            if let output = Int(maxOutputTokensText), maximum < output {
                maxOutputTokensText = String(maximum)
            }
        }
        isApplyingDraft = false
        task?.cancel()
        let token = reloadID
        task = Task { await reloadDescriptor(token: token, invocationID: selected.id) }
    }
    var contextWindowValue: Int? { Int(contextWindowText.trimmingCharacters(in: .whitespacesAndNewlines)) }
    var outputValue: Int { Int(maxOutputTokensText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 }
    var hasValidNumericLimits: Bool {
        let context = contextWindowText.trimmingCharacters(in: .whitespacesAndNewlines)
        let output = maxOutputTokensText.trimmingCharacters(in: .whitespacesAndNewlines)
        return (context.isEmpty || Int(context).map { (1...10_000_000).contains($0) } == true)
            && Int(output).map { (1...10_000_000).contains($0) } == true
    }
    private var hasValidThinkingBudget: Bool {
        let value = thinkingBudgetText.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || Int(value).map { (1...10_000_000).contains($0) } == true
    }
    var descriptorControlKeys: [String] {
        guard let descriptor = descriptors.first, case .object(let properties) = descriptor.route.schema["properties"] else { return [] }
        return properties.keys.filter { $0 != "protocolID" && $0 != "dialectProfileID" }.sorted()
    }
    var thinkingModes: [String] {
        guard let schema = descriptors.first?.route.schema,
              case .object(let properties) = schema["properties"],
              case .object(let thinking) = properties["thinking"],
              case .object(let values) = thinking["properties"],
              case .object(let mode) = values["mode"],
              case .array(let options) = mode["enum"] else { return [] }
        return options.compactMap { if case .string(let value) = $0 { return value }; return nil }
    }
    var thinkingEfforts: [String] {
        guard let schema = descriptors.first?.route.schema,
              case .object(let properties) = schema["properties"],
              case .object(let thinking) = properties["thinking"],
              case .object(let values) = thinking["properties"],
              case .object(let effort) = values["effort"],
              case .array(let options) = effort["enum"] else { return [] }
        return options.compactMap { if case .string(let value) = $0 { return value }; return nil }
    }
    var thinkingBudgetSupported: Bool {
        guard let schema = descriptors.first?.route.schema,
              case .object(let properties) = schema["properties"],
              case .object(let thinking) = properties["thinking"],
              case .object(let values) = thinking["properties"] else { return false }
        return values["budgetTokens"] != nil
    }

    func observe() async {
        isStopped = false
        guard !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            invocation = nil
            rawInvocation = nil
            invocationChoices = []
            descriptors = []
            unsupportedError = nil
            isLoading = false
            return
        }
        await reload()
    }
    func stop() async {
        isStopped = true; reloadID = UUID(); task?.cancel()
        let read = task
        let save = saveTask
        await read?.value
        // A save accepted by the editor owns its write through the commit
        // barrier. Drain it without propagating view cancellation; the
        // completion guard below suppresses stale presentation callbacks.
        await save?.value
        isLoading = false; isSaving = false
    }
    func modelIDChanged(_ value: String) {
        guard value != modelID else { return }
        modelID = value; invocation = nil; rawInvocation = nil; draftFacts = []
        reloadID = UUID()
        descriptors = []; unsupportedError = nil; catalogMetadata = nil
        contextEdited = false; outputEdited = false; capabilitiesEdited = false
        requestsUsageEdited = false; storeResponsesEdited = false
        thinkingModeEdited = false; thinkingEffortEdited = false; thinkingBudgetEdited = false
        isApplyingDraft = true
        contextWindowText = ""; textDeclared = false; toolsDeclared = false; jsonDeclared = false
        isApplyingDraft = false
        task?.cancel(); task = Task { await reload() }
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            task?.cancel()
            task = nil
        }
    }
    func setContextWindowText(_ value: String) { contextWindowText = value }
    func setMaxOutputTokensText(_ value: String) { maxOutputTokensText = value }
    func startSave() {
        guard canSave, saveTask == nil else { return }
        let modelID = self.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let spec = rawInvocation ?? invocation; let baseline = baselineModel; let preset = baselinePreset
        let values: (model: AgentConfiguredModel, preset: AgentRoutePreset)
        do {
            guard let spec else { throw MiraError(.configuration, "Choose a supported invocation.") }
            values = try makeSaveValues(spec: spec, modelID: modelID, baseline: baseline, preset: preset)
        } catch {
            self.error = MiraError.safe(error)
            return
        }
        isSaving = true; error = nil
        saveTask = Task { @MainActor in
            defer { saveTask = nil; isSaving = false }
            do {
                let binding = try await library.binding()
                try await binding.workgroup.modelSettings.savePoolModel(
                    values.model, preset: values.preset, expectedModelRevision: baseline?.revision,
                    expectedPresetRevision: preset?.revision)
                guard !isStopped, await isCurrent(binding) else { return }
                baselineModel = values.model; baselinePreset = values.preset; saveConfirmation &+= 1
                await onSaved()
            } catch let caught { if !Task.isCancelled && !isStopped { self.error = MiraError.safe(caught) } }
        }
    }

    private func reload() async {
        guard !isStopped, !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let token = reloadID
        let requestedModelID = modelID
        isLoading = true; defer { isLoading = false }
        do {
            let binding = try await library.binding()
            guard !Task.isCancelled, !isStopped, reloadID == token, modelID == requestedModelID else { return }
            let settings = binding.workgroup.modelSettings
            let snapshot = try? await binding.workgroup.modelMetadata.snapshot(
                sourceID: ModelsDevMetadataSource.sourceID)
            guard !Task.isCancelled, !isStopped, reloadID == token, modelID == requestedModelID,
                let current = try? await library.binding(),
                current.status.generation == binding.status.generation,
                current.workgroup === binding.workgroup else { return }
            let cachedCatalog = snapshot.flatMap { try? ProviderModelCatalog(
                data: SessionCodec.encode($0.document.payload)) } ?? .bundled
            if let existing {
                draftFacts = existing.facts
                invocationChoices = existing.invocations
                let preferred = baselinePreset?.invocationID ?? existing.invocations.first?.id
                rawInvocation = existing.invocations.first(where: { $0.id == preferred })
                invocation = try rawInvocation.map { try AgentModelMetadataResolver.resolve($0, facts: draftFacts) }
            } else if let catalog = cachedCatalog.model(for: connection, modelID: modelID) {
                catalogMetadata = catalog.metadata
                rawInvocation = try catalog.invocation(connection: connection)
                invocationChoices = [rawInvocation].compactMap { $0 }
                draftFacts = try catalog.metadataFacts(invocationID: rawInvocation?.id ?? "default")
                invocation = try rawInvocation.map { try AgentModelMetadataResolver.resolve($0, facts: draftFacts) }
            } else {
                let snapshot = try await settings.discoverySnapshot(connectionID: connection.id)
                let discovered = snapshot?.models.first(where: { $0.id == modelID })
                let resolved = try cachedCatalog.configuration(
                    connection: connection, modelID: modelID, displayName: discovered?.displayName,
                    discoveredFacts: discovered?.facts ?? [], isEnabled: true)
                rawInvocation = resolved.model.invocations.first
                invocationChoices = resolved.model.invocations
                draftFacts = resolved.model.facts
                invocation = try rawInvocation.map { try AgentModelMetadataResolver.resolve($0, facts: draftFacts) }
            }
            guard let invocation else { throw MiraError(.unsupported, "No invocation is configured for this model.") }
            isApplyingDraft = true
            if contextWindowText.isEmpty { contextWindowText = invocation.contextWindow.map(String.init) ?? "" }
            if textDeclared == false { textDeclared = invocation.supports(AgentModelCapabilityID.streamingText) }
            if toolsDeclared == false { toolsDeclared = invocation.supports(AgentModelCapabilityID.toolCalls) }
            if jsonDeclared == false { jsonDeclared = invocation.supports(AgentModelCapabilityID.jsonOutput) }
            isApplyingDraft = false
            descriptors = try await settings.configurationDescriptors(for: invocation)
            guard !Task.isCancelled, !isStopped, reloadID == token, modelID == requestedModelID,
                let current = try? await library.binding(),
                current.status.generation == binding.status.generation,
                current.workgroup === binding.workgroup else { return }
            loadPresetControls(baselinePreset)
            unsupportedError = nil
        } catch {
            guard !Task.isCancelled, !isStopped, reloadID == token, modelID == requestedModelID else { return }
            unsupportedError = MiraError.safe(error)
        }
    }

    private func reloadDescriptor(token: UUID, invocationID: String) async {
        guard let invocation, let binding = try? await library.binding(), !isStopped,
            reloadID == token, invocation.id == invocationID else { return }
        let values = try? await binding.workgroup.modelSettings.configurationDescriptors(for: invocation)
        guard !Task.isCancelled, !isStopped, reloadID == token, self.invocation?.id == invocationID,
            let current = try? await library.binding(),
            current.status.generation == binding.status.generation,
            current.workgroup === binding.workgroup else { return }
        descriptors = values ?? []
    }

    private func adjusted(_ value: AgentModelInvocationSpec) throws -> AgentModelInvocationSpec {
        let context = contextWindowValue
        guard hasValidNumericLimits, outputValue > 0,
              context == nil || context! > outputValue else {
            throw MiraError(.configuration, "The context window must exceed the output limit.")
        }
        guard hasValidThinkingBudget else {
            throw MiraError(.configuration, "Thinking budget must be a positive number.")
        }
        return value
    }
    private func userFacts(baseline: AgentConfiguredModel?, invocationID: String) -> [AgentModelMetadataFact] {
        var facts = baseline?.facts ?? draftFacts
        let now = Date()
        func replace(_ field: String, _ value: JSONValue) {
            facts.removeAll { $0.source == .user && $0.field == field && $0.invocationID == invocationID }
            facts.append(.init(field: field, value: value, source: .user,
                sourceID: "mira.mac.settings", sourceRevision: "1", observedAt: now, invocationID: invocationID))
        }
        if contextEdited {
            // An explicit clear removes the local override and returns resolution to
            // the cached catalog (or to the unknown/unspecified state).
            facts.removeAll { $0.source == .user && $0.field == AgentModelMetadataField.contextWindow && $0.invocationID == invocationID }
            if let context = contextWindowValue {
                replace(AgentModelMetadataField.contextWindow, .number(Double(context)))
            }
        }
        if outputEdited { replace(AgentModelMetadataField.outputTokens, .number(Double(outputValue))) }
        if capabilitiesEdited {
            replace(AgentModelMetadataField.capability(AgentModelCapabilityID.streamingText), .bool(textDeclared))
            replace(AgentModelMetadataField.capability(AgentModelCapabilityID.toolCalls), .bool(toolsDeclared))
            replace(AgentModelMetadataField.capability(AgentModelCapabilityID.jsonOutput), .bool(jsonDeclared))
        }
        return facts
    }
    private func makeSaveValues(spec: AgentModelInvocationSpec, modelID: String,
                                baseline: AgentConfiguredModel?, preset: AgentRoutePreset?)
        throws -> (model: AgentConfiguredModel, preset: AgentRoutePreset) {
        let updatedSpec = try adjusted(spec)
        if let baseline, baseline.modelID != modelID {
            throw MiraError(.conflict, "The saved model ID cannot be changed from this editor.")
        }
        let facts = userFacts(baseline: baseline, invocationID: updatedSpec.id)
        var invocations = baseline?.invocations ?? []
        if baseline == nil {
            invocations = [updatedSpec]
        } else if let index = invocations.firstIndex(where: { $0.id == updatedSpec.id }) {
            invocations[index] = updatedSpec
        } else {
            throw MiraError(.conflict, "The selected model invocation is no longer available.")
        }
        let provisional = AgentConfiguredModel(
            id: baseline?.id ?? .init(), revision: (baseline?.revision ?? 0) + 1,
            authorizationRevision: baseline?.authorizationRevision ?? 1,
            reference: .init(connectionID: connection.id, modelID: modelID),
            displayName: catalogMetadata?.displayName ?? baseline?.displayName, isEnabled: isEnabled,
            invocations: invocations, facts: facts)
        let value = AgentConfiguredModel(
            id: provisional.id, revision: provisional.revision,
            authorizationRevision: try baseline.map { try provisional.authorizationRevision(replacing: $0) } ?? 1,
            reference: provisional.reference, displayName: provisional.displayName,
            isEnabled: provisional.isEnabled, invocations: provisional.invocations, facts: provisional.facts)
        let routeID = preset?.id ?? RouteID(value.id.rawValue)
        let route = AgentRoutePreset(
            id: routeID, revision: (preset?.revision ?? 0) + 1,
            name: String((catalogMetadata?.displayName ?? modelID).prefix(256)),
            modelDescriptorID: value.id, invocationID: updatedSpec.id,
            maximumOutputTokens: outputValue,
            configuration: routeConfiguration())
        return (value, route)
    }
    private func routeConfiguration() -> AgentConfigurationValue {
        let schema = descriptors.first?.route.identity ?? baselinePreset?.configuration.schema
            ?? AgentConfigurationIdentity(id: "mira.http.invocation", revision: 2)
        var values: [String: JSONValue] = [:]
        if let baseline = baselinePreset?.configuration.value, case .object(let existing) = baseline {
            values = existing
        }
        let isNew = baselinePreset == nil
        if isNew || requestsUsageEdited, descriptorControlKeys.contains("requestsUsage") {
            values["requestsUsage"] = .bool(requestsUsage)
        }
        if (isNew || storeResponsesEdited), descriptorControlKeys.contains("storeResponses"), updatedProtocolID != .responses {
            values["storeResponses"] = .bool(storeResponses)
        }
        if (isNew || thinkingModeEdited || thinkingEffortEdited || thinkingBudgetEdited),
            descriptorControlKeys.contains("thinking") {
            var thinking: [String: JSONValue] = [:]
            if case .object(let existing) = values["thinking"] { thinking = existing }
            if isNew || thinkingModeEdited { thinking["mode"] = .string(thinkingMode) }
            if isNew || thinkingEffortEdited {
                if thinkingEffort.isEmpty { thinking["effort"] = nil }
                else { thinking["effort"] = .string(thinkingEffort) }
            }
            if isNew || thinkingBudgetEdited {
                if let budget = Int(thinkingBudgetText), budget > 0 { thinking["budgetTokens"] = .number(Double(budget)) }
                else if thinkingBudgetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { thinking["budgetTokens"] = nil }
            }
            if !thinking.isEmpty { values["thinking"] = .object(thinking) }
        }
        if updatedProtocolID == .responses { values["storeResponses"] = nil }
        return .init(schema: schema, value: .object(values))
    }
    private var updatedProtocolID: HTTPProtocolID {
        guard let spec = rawInvocation,
              let settings = try? SessionCodec.decode(HTTPInvocationSettings.self, from: SessionCodec.encode(spec.configuration.value))
        else { return .chatCompletions }
        return settings.protocolID
    }
    private func loadPresetControls(_ preset: AgentRoutePreset?) {
        guard let preset, case .object(let values) = preset.configuration.value else { return }
        isApplyingDraft = true
        if case .bool(let value) = values["requestsUsage"] { requestsUsage = value }
        if case .bool(let value) = values["storeResponses"] { storeResponses = value }
        if case .object(let thinking) = values["thinking"] {
            if case .string(let value) = thinking["mode"] { thinkingMode = value }
            if case .string(let value) = thinking["effort"] { thinkingEffort = value }
            if case .number(let value) = thinking["budgetTokens"] {
                thinkingBudgetText = Int(exactly: value).map(String.init) ?? String(value)
            }
        }
        isApplyingDraft = false
    }
    private func isCurrent(_ binding: MacLibraryWorkgroupBinding) async -> Bool {
        guard let current = try? await library.binding() else { return false }
        return current.status.generation == binding.status.generation && current.workgroup === binding.workgroup
    }
}
