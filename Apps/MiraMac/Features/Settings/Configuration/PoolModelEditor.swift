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
    @State private var maxOutputTokens = "1024"
    @State private var requestsUsage = true
    @State private var isEnabled = true
    @State private var modelID = ""
    @State private var contextWindow = ""
    @State private var textDeclared = false
    @State private var toolsDeclared = false
    @State private var extractionDeclared = false
    @State private var protocolMode = ModelProtocolMode.standard
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
                Picker("Thinking compatibility", selection: $protocolMode) {
                    Text("Standard text mode").tag(ModelProtocolMode.standard)
                    Text("Disable thinking for DeepSeek / Kimi").tag(ModelProtocolMode.thinkingDisabled)
                    Text("Needs reasoning continuation support").tag(ModelProtocolMode.unsupportedReasoning)
                }
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
            if protocolMode == .thinkingDisabled {
                Text("Mira will request thinking disabled for this model. This option is supported only on the official DeepSeek and Kimi endpoints.")
            } else if protocolMode == .unsupportedReasoning {
                Text("This model needs reasoning continuation support. You can keep it in the pool, but it cannot be selected for execution yet.")
                    .foregroundStyle(.orange)
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
        let requestedOutput = Int(maxOutputTokens) ?? 1024
        let contextBound = (item.metadata.contextWindow ?? 1025) - 1
        maxOutputTokens = String(max(1, min(requestedOutput, item.metadata.maxOutputTokens ?? requestedOutput, contextBound)))
        textDeclared = item.metadata.task == .textGeneration && item.metadata.inputModalities.contains("text") && item.metadata.outputModalities.contains("text")
        toolsDeclared = item.metadata.toolCall == true
        extractionDeclared = false
        protocolMode = item.suggestedProtocolMode
    }

    private func load() {
        maxOutputTokens = route.map { String($0.maxOutputTokens) } ?? "1024"
        requestsUsage = route?.requestsUsage ?? true
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
            let descriptorChanged = catalogSuggestionsApplied || (existing.map { $0.connectionID != connectionID || $0.connectionRevision != connection.revision || $0.modelID != modelID.trimmingCharacters(in: .whitespacesAndNewlines) || $0.contextWindow != parsedWindow || $0.protocolMode != protocolMode || $0.catalogMetadata != catalogMetadata } ?? true)
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
                                    maxOutputTokens: output, requestsUsage: requestsUsage)
            try await application.savePoolModel(model, route: preset, expectedModelRevision: existing?.revision, expectedRouteRevision: route?.revision)
            await onSaved(); dismiss()
        } catch { self.error = MiraError.safe(error) }
    }
}
