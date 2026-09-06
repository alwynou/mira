import SwiftUI
import MiraCore
import MiraProviders

struct PoolModelEditor: View {
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss
    let existing: ModelDescriptor?
    let connection: ProviderConnection
    let route: ModelRoute?
    let initialModelID: String
    let container: AppContainer
    let onSaved: () async -> Void
    @State private var maxOutputTokens = "8192"
    @State private var requestsUsage = true
    @State private var isEnabled = true
    @State private var modelID = ""
    @State private var contextWindow = ""
    @State private var textDeclared = false
    @State private var toolsDeclared = false
    @State private var extractionDeclared = false
    @State private var protocolMode = ModelProtocolMode.standard
    @State private var thinkingMode = ThinkingMode.providerDefault
    @State private var thinkingEffort: ThinkingEffort?
    @State private var thinkingBudget = ""
    @State private var catalogMetadata: ModelCatalogMetadata?
    @State private var catalogSuggestionsApplied = false
    @State private var error: MiraError?
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(LocalizedStringKey(existing == nil ? "Add Model" : "Edit Model")).font(.title2.weight(.semibold))
            ScrollView {
            Form {
                LabeledContent("Provider") { Text(verbatim: connection.name) }
                TextField("Model ID", text: Binding(get: { modelID }, set: { updated in
                    if modelID.trimmingCharacters(in: .whitespacesAndNewlines) != updated.trimmingCharacters(in: .whitespacesAndNewlines) {
                        catalogMetadata = nil; contextWindow = ""; textDeclared = false
                        toolsDeclared = false; extractionDeclared = false; protocolMode = .standard
                        thinkingMode = .providerDefault; thinkingEffort = nil; thinkingBudget = ""
                    }
                    modelID = updated
                }))
                TextField("Context Window (tokens, optional)", text: $contextWindow)
                TextField("Maximum Output Tokens", text: $maxOutputTokens)
                Toggle("Request usage reporting", isOn: $requestsUsage)
                Toggle("Include in Model Pool", isOn: $isEnabled)
                Toggle("Text capability declared", isOn: $textDeclared)
                Toggle("Tool capability declared", isOn: $toolsDeclared)
                Toggle("JSON extraction capability declared", isOn: $extractionDeclared)
                thinkingControls
            }.disabled(saving)
            catalogReference
            Text("Catalog suggestions are declarations, not successful tests. Confirm the limits and capabilities before saving. Connection or model changes require reconfirmation.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Memory extraction uses JSON text with local validation. Declare it separately or run Test JSON Extraction in the pool. Native structured output is not required.")
                .font(.caption).foregroundStyle(.secondary)
            }.frame(maxHeight: 500)
            if let error { Text(L10n.error(error, locale: locale)).font(.callout).foregroundStyle(.red) }
            HStack { Spacer(); Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving); Button("Save") { Task { await save() } }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(saving || modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || container.isDemo) }
        }
        .padding(28).frame(width: 590)
        .onAppear { load() }
        .interactiveDismissDisabled(saving)
    }
    private var thinkingCapabilities: ThinkingCapabilities { .init(protocolMode: protocolMode, modelID: modelID.trimmingCharacters(in: .whitespacesAndNewlines)) }
    private var thinkingSettings: ThinkingSettings {
        .init(mode: thinkingMode, effort: thinkingMode == .disabled ? nil : thinkingEffort,
              budgetTokens: thinkingMode == .disabled ? nil : Int(thinkingBudget.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    @ViewBuilder private var thinkingControls: some View {
        if catalogModel == nil {
            Picker("Thinking interface", selection: Binding(get: { protocolMode }, set: { mode in
                protocolMode = mode
                thinkingMode = .providerDefault; thinkingEffort = nil; thinkingBudget = ""
            })) {
                Text("Service default").tag(ModelProtocolMode.standard)
                if connection.providerKind == .anthropic {
                    Text("Adaptive thinking").tag(ModelProtocolMode.anthropicAdaptive)
                    Text("Thinking with token budget").tag(ModelProtocolMode.anthropicManual)
                } else {
                    Text("DeepSeek").tag(ModelProtocolMode.deepSeek)
                    Text("Kimi / Moonshot").tag(ModelProtocolMode.kimi)
                    Text("OpenAI reasoning effort").tag(ModelProtocolMode.openAI)
                    Text("OpenRouter reasoning").tag(ModelProtocolMode.openRouter)
                }
            }
        }
        Picker("Thinking mode", selection: $thinkingMode) {
            ForEach(thinkingCapabilities.modes, id: \.self) { mode in
                Text(LocalizedStringKey(thinkingModeKey(mode))).tag(mode)
            }
        }
        .onChange(of: thinkingMode) { _, mode in
            if mode == .disabled { thinkingEffort = nil; thinkingBudget = "" }
        }
        if thinkingMode != .disabled && !thinkingCapabilities.efforts.isEmpty {
            Picker("Thinking effort", selection: Binding(get: { thinkingEffort }, set: { value in
                thinkingEffort = value
                if protocolMode == .openRouter && value != nil { thinkingBudget = "" }
            })) {
                Text("Service default").tag(nil as ThinkingEffort?)
                ForEach(thinkingCapabilities.efforts, id: \.self) { effort in
                    Text(LocalizedStringKey(thinkingEffortKey(effort))).tag(Optional(effort))
                }
            }
        }
        if thinkingMode != .disabled && thinkingCapabilities.supportsBudget {
            TextField("Thinking budget (tokens, optional)", text: Binding(get: { thinkingBudget }, set: { value in
                thinkingBudget = value
                if protocolMode == .openRouter && !value.isEmpty { thinkingEffort = nil }
            }))
            Text("Thinking and the answer share the maximum output token limit.").font(.caption).foregroundStyle(.secondary)
        }
        if !thinkingCapabilities.modes.contains(.disabled) && protocolMode != .standard {
            Text("This model uses thinking by default; a disable option is not available for this interface.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func thinkingModeKey(_ mode: ThinkingMode) -> String {
        switch mode { case .providerDefault: "Service default"; case .enabled: "Enabled"; case .disabled: "Disabled" }
    }
    private func thinkingEffortKey(_ effort: ThinkingEffort) -> String {
        switch effort { case .low: "Low"; case .medium: "Medium"; case .high: "High"; case .xhigh: "Very high"; case .max: "Maximum" }
    }

    private var catalogModel: CatalogModel? {
        ProviderModelCatalog.bundled.model(for: connection, modelID: modelID.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @ViewBuilder private var catalogReference: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let item = catalogModel {
                Button("Apply Catalog Suggestions") { applyCatalog(item) }.disabled(saving)
            }
            if let metadata = catalogMetadata {
                Text("Model information from models.dev").font(.headline)
                if let name = metadata.displayName { Text(verbatim: name) }
                LabeledContent("Model Type") { Text(LocalizedStringKey(catalogTaskKey(metadata.task))) }
                LabeledContent("Input Modalities") { Text(verbatim: metadata.inputModalities.joined(separator: ", ")) }
                LabeledContent("Output Modalities") { Text(verbatim: metadata.outputModalities.joined(separator: ", ")) }
                Text(L10n.format("Catalog retrieved: %@", locale: locale, metadata.retrievedAt))
                if let pricing = metadata.pricing {
                    Text(L10n.format("Catalog USD per million tokens · Input: %@ · Output: %@", locale: locale,
                                     CostPresentation.amount(pricing.input, locale: locale), CostPresentation.amount(pricing.output, locale: locale)))
                    if let read = pricing.cacheRead {
                        Text(L10n.format("Cached input USD per million tokens: %@", locale: locale, CostPresentation.amount(read, locale: locale)))
                    }
                    Text("Estimates use the catalog frozen for each call. They are not the provider's bill.")
                } else {
                    Text("No supported text pricing is saved for this model.")
                }
                if let output = metadata.maxOutputTokens {
                    Text(L10n.format("Catalog output limit: %@ tokens", locale: locale, String(output)))
                }
                if let structured = metadata.structuredOutput {
                    Text(LocalizedStringKey(structured ? "Catalog declares native structured output" : "Catalog does not declare native structured output"))
                }
                Text(verbatim: metadata.sourceURL).textSelection(.enabled)
                Text(verbatim: metadata.sourceRevision).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Text("Applied catalog limits restrict selection and output size. Clear the reference to use manually confirmed deployment limits instead.")
                Button("Clear Catalog Reference") { catalogMetadata = nil }.disabled(saving)
            } else {
                Text("No catalog reference applied. Enter and confirm this deployment’s limits and capabilities manually.")
            }

        }.font(.caption).foregroundStyle(.secondary).padding(.vertical, 12)
    }

    private func catalogTaskKey(_ task: ModelCatalogTask) -> String {
        switch task {
        case .textGeneration: "Text Generation"
        case .embedding: "Embedding"
        case .imageGeneration: "Image Generation"
        case .audio: "Audio"
        case .unknown: "Unknown"
        }
    }

    private func applyCatalog(_ item: CatalogModel) {
        catalogSuggestionsApplied = true
        catalogMetadata = item.metadata
        contextWindow = item.metadata.contextWindow.map(String.init) ?? ""
        let requestedOutput = Int(maxOutputTokens) ?? 8192
        let contextBound = (item.metadata.contextWindow ?? 1025) - 1
        maxOutputTokens = String(max(1, min(requestedOutput, item.metadata.maxOutputTokens ?? requestedOutput, contextBound)))
        textDeclared = item.metadata.task == .textGeneration && item.metadata.inputModalities.contains("text") && item.metadata.outputModalities.contains("text")
        toolsDeclared = item.metadata.toolCall == true
        extractionDeclared = false
        protocolMode = item.suggestedProtocolMode
        thinkingMode = (protocolMode == .anthropicManual || protocolMode == .anthropicAdaptive) ? .enabled : .providerDefault
        thinkingEffort = nil; thinkingBudget = ""
    }

    private func load() {
        maxOutputTokens = route.map { String($0.maxOutputTokens) } ?? "8192"
        requestsUsage = route?.requestsUsage ?? true
        thinkingMode = route?.thinking.mode ?? .providerDefault
        thinkingEffort = route?.thinking.effort
        thinkingBudget = route?.thinking.budgetTokens.map(String.init) ?? ""
        guard let existing else {
            modelID = initialModelID
            if let item = catalogModel { applyCatalog(item) }
            return
        }
        modelID = existing.modelID; contextWindow = existing.contextWindow.map(String.init) ?? ""
        isEnabled = existing.isEnabled
        catalogMetadata = existing.catalogMetadata; protocolMode = existing.protocolMode
        extractionDeclared = existing.extractionCapability == .declared || existing.extractionCapability == .verified
        textDeclared = existing.textCapability == .declared || existing.textCapability == .verified
        toolsDeclared = existing.toolCapability == .declared || existing.toolCapability == .verified
    }
    private func save() async {
        saving = true; defer { saving = false }
        do {
            let connectionID = connection.id
            let window = contextWindow.trimmingCharacters(in: .whitespacesAndNewlines)
            guard window.isEmpty || (Int(window).map { $0 > 0 && $0 <= 10_000_000 } ?? false) else { throw MiraError(.configuration, "Enter a valid context window, or leave it unknown.") }
            let parsedWindow = Int(window)
            guard let output = Int(maxOutputTokens.trimmingCharacters(in: .whitespacesAndNewlines)),
                  output > 0, output <= 10_000_000, parsedWindow.map({ output < $0 }) ?? true else {
                throw MiraError(.configuration, "Maximum output tokens must be positive and smaller than the model context window.")
            }
            let descriptorChanged = (route.map { $0.thinking != thinkingSettings } ?? false) || catalogSuggestionsApplied || (existing.map { $0.connectionID != connectionID || $0.connectionRevision != connection.revision || $0.modelID != modelID.trimmingCharacters(in: .whitespacesAndNewlines) || $0.contextWindow != parsedWindow || $0.protocolMode != protocolMode || $0.catalogMetadata != catalogMetadata } ?? true)
            let textDeclarationChanged = existing.map { ($0.textCapability == .declared || $0.textCapability == .verified) != textDeclared } ?? true
            let toolsDeclarationChanged = existing.map { ($0.toolCapability == .declared || $0.toolCapability == .verified) != toolsDeclared } ?? true
            let textCapability: CapabilityState = if !descriptorChanged, let previous = existing, previous.textCapability == .verified, textDeclared { .verified } else if !descriptorChanged, let previous = existing, previous.textCapability == .failed, !textDeclared { .failed } else { textDeclared ? .declared : .unknown }
            let toolCapability: CapabilityState = if !descriptorChanged, let previous = existing, previous.toolCapability == .verified, toolsDeclared { .verified } else if !descriptorChanged, let previous = existing, previous.toolCapability == .failed, !toolsDeclared { .failed } else { toolsDeclared ? .declared : .unknown }
            let extractionCapability: CapabilityState = if !descriptorChanged, let previous = existing, previous.extractionCapability == .verified, extractionDeclared { .verified } else if !descriptorChanged, let previous = existing, previous.extractionCapability == .failed, !extractionDeclared { .failed } else { extractionDeclared ? .declared : .unknown }
            let extractionDeclarationChanged = existing.map { ($0.extractionCapability == .declared || $0.extractionCapability == .verified) != extractionDeclared } ?? true
            let observation = descriptorChanged || textDeclarationChanged || toolsDeclarationChanged || extractionDeclarationChanged ? nil : existing?.probeObservation
            let model = ModelDescriptor(id: existing?.id ?? .init(), revision: existing.map { $0.revision + 1 } ?? 1, connectionID: connectionID, connectionRevision: connection.revision, modelID: modelID.trimmingCharacters(in: .whitespacesAndNewlines), contextWindow: parsedWindow, textCapability: textCapability, toolCapability: toolCapability, probeObservation: observation, isEnabled: isEnabled, extractionCapability: extractionCapability, protocolMode: protocolMode, catalogMetadata: catalogMetadata)
            try model.validate()
            guard let application = container.application else { throw MiraError(.storage, "The library is not open.") }
            let current = try await application.library()
            guard !current.configuration.models.contains(where: { $0.connectionID == connectionID && $0.modelID == model.modelID && $0.id != model.id }) else {
                throw MiraError(.configuration, "This provider already has that model. Edit or enable the existing entry.")
            }
            let preset = ModelRoute(id: model.poolRouteID, revision: (route?.revision ?? 0) + 1,
                                    name: String(model.modelID.prefix(100)), modelDescriptorID: model.id,
                                    maxOutputTokens: output, requestsUsage: requestsUsage, thinking: thinkingSettings)
            if !thinkingBudget.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && Int(thinkingBudget.trimmingCharacters(in: .whitespacesAndNewlines)) == nil {
                throw MiraError(.configuration, "Enter a valid thinking token budget.")
            }
            let snapshot = ResolvedModelRouteSnapshot(route: preset, model: model, connection: connection, purpose: .conversation, selection: .explicit)
            try snapshot.validateThinkingSettings()
            try await application.savePoolModel(model, route: preset, expectedModelRevision: existing?.revision, expectedRouteRevision: route?.revision)
            await onSaved(); dismiss()
        } catch { self.error = MiraError.safe(error) }
    }
}
