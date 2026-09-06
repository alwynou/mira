import SwiftUI
import MiraCore

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
    @State private var error: MiraError?
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(LocalizedStringKey(existing == nil ? "Add Model" : "Edit Model")).font(.title2.weight(.semibold))
            Form {
                LabeledContent("Provider") { Text(verbatim: connection.name) }
                TextField("Model ID", text: $modelID)
                TextField("Context Window (tokens, optional)", text: $contextWindow)
                TextField("Maximum Output Tokens", text: $maxOutputTokens)
                Toggle("Request usage reporting", isOn: $requestsUsage)
                Toggle("Include in Model Pool", isOn: $isEnabled)
                Toggle("Text capability declared", isOn: $textDeclared)
                Toggle("Tool capability declared", isOn: $toolsDeclared)
            }.disabled(saving)
            Text("Declare capabilities only when you have verified them. Capability observations reset when the connection, model ID, or context window changes. Adding a model does not verify its capabilities. Use Test Text and Test Tools from the model pool.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(L10n.error(error, locale: locale)).font(.callout).foregroundStyle(.red) }
            HStack { Spacer(); Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving); Button("Save") { Task { await save() } }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(saving || modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || container.isDemo) }
        }
        .padding(28).frame(width: 590)
        .onAppear { load() }
        .interactiveDismissDisabled(saving)
    }
    private func load() {
        maxOutputTokens = route.map { String($0.maxOutputTokens) } ?? "1024"
        requestsUsage = route?.requestsUsage ?? true
        guard let existing else { modelID = initialModelID; return }
        modelID = existing.modelID; contextWindow = existing.contextWindow.map(String.init) ?? ""
        isEnabled = existing.isEnabled
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
            let descriptorChanged = existing.map { $0.connectionID != connectionID || $0.connectionRevision != connection.revision || $0.modelID != modelID.trimmingCharacters(in: .whitespacesAndNewlines) || $0.contextWindow != parsedWindow } ?? true
            let textDeclarationChanged = existing.map { ($0.textCapability == .declared || $0.textCapability == .verified) != textDeclared } ?? true
            let toolsDeclarationChanged = existing.map { ($0.toolCapability == .declared || $0.toolCapability == .verified) != toolsDeclared } ?? true
            let textCapability: CapabilityState = if !descriptorChanged, let previous = existing, previous.textCapability == .verified, textDeclared { .verified } else if !descriptorChanged, let previous = existing, previous.textCapability == .failed, !textDeclared { .failed } else { textDeclared ? .declared : .unknown }
            let toolCapability: CapabilityState = if !descriptorChanged, let previous = existing, previous.toolCapability == .verified, toolsDeclared { .verified } else if !descriptorChanged, let previous = existing, previous.toolCapability == .failed, !toolsDeclared { .failed } else { toolsDeclared ? .declared : .unknown }
            let observation = descriptorChanged || textDeclarationChanged || toolsDeclarationChanged ? nil : existing?.probeObservation
            let model = ModelDescriptor(id: existing?.id ?? .init(), revision: existing.map { $0.revision + 1 } ?? 1, connectionID: connectionID, connectionRevision: connection.revision, modelID: modelID.trimmingCharacters(in: .whitespacesAndNewlines), contextWindow: parsedWindow, textCapability: textCapability, toolCapability: toolCapability, probeObservation: observation, isEnabled: isEnabled)
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
