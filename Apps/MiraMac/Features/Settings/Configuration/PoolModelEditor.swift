import MiraCore
import MiraProviders
import SwiftUI

struct PoolModelEditor: View {
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss
    @State private var model: PoolModelEditorModel
    let onSaved: @MainActor () async -> Void

    init(existing: AgentConfiguredModel?, connection: AgentConfiguredConnection, preset: AgentRoutePreset?,
         initialModelID: String, library: MacLibrary, isDemo: Bool,
         onSaved: @MainActor @escaping () async -> Void) {
        self.onSaved = onSaved
        _model = State(initialValue: PoolModelEditorModel(existing: existing, connection: connection, preset: preset,
            initialModelID: initialModelID, library: library, isDemo: isDemo, onSaved: onSaved))
    }

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: MiraTheme.Spacing.lg) {
            Text(LocalizedStringKey(model.existing == nil ? "Add Model" : "Edit Model"))
                .font(.title2.weight(.semibold))
            ScrollView {
                Form {
                    LabeledContent("Provider") { Text(verbatim: model.connection.name) }
                    TextField("Model ID", text: Binding(
                        get: { model.modelID }, set: { value in model.modelIDChanged(value) }))
                    if model.invocationChoices.count > 1 {
                        MiraSettingsSelect(
                            title: "Invocation",
                            selection: Binding(
                                get: { model.selectedInvocationID },
                                set: { model.selectInvocation($0) }),
                            options: model.invocationChoices.map {
                                .init(id: $0.id, verbatimTitle: $0.adapter.id)
                            }, identifier: "settings.model.invocation", maximumWidth: 260)
                    } else if !model.invocationTitle.isEmpty {
                        LabeledContent("Invocation") { Text(verbatim: model.invocationTitle).textSelection(.enabled) }
                    }
                    TextField("Context Window (tokens, optional)", text: $model.contextWindowText)
                    TextField("Maximum Output Tokens", text: $model.maxOutputTokensText)
                    Toggle("Include in Model Pool", isOn: $model.isEnabled)
                    Toggle("Text capability declared", isOn: $model.textDeclared)
                    Toggle("Tool capability declared", isOn: $model.toolsDeclared)
                    Toggle("JSON capability declared", isOn: $model.jsonDeclared)
                    DisclosureGroup("Advanced invocation settings", isExpanded: $model.advancedOptions) {
                        if model.descriptorControlKeys.contains("requestsUsage") {
                            Toggle("Request usage reporting", isOn: $model.requestsUsage)
                        }
                        if model.descriptorControlKeys.contains("storeResponses"), model.invocationTitle != HTTPAdapterIdentity.responses.id {
                            Toggle("Allow provider response storage", isOn: $model.storeResponses)
                        }
                        if !model.thinkingModes.isEmpty {
                            MiraSettingsSelect(
                                title: "Thinking mode",
                                selection: $model.thinkingMode,
                                options: model.thinkingModes.map {
                                    .init(id: $0, verbatimTitle: thinkingModeTitle($0))
                                },
                                identifier: "settings.model.thinking-mode", maximumWidth: 220)
                        }
                        if !model.thinkingEfforts.isEmpty {
                            MiraSettingsSelect(
                                title: "Thinking effort",
                                selection: $model.thinkingEffort,
                                options: [MiraSettingsSelect.Option(id: "", title: "Provider default")] +
                                    model.thinkingEfforts.map { .init(id: $0, verbatimTitle: $0) },
                                identifier: "settings.model.thinking-effort", maximumWidth: 220)
                        }
                        if model.thinkingBudgetSupported {
                            TextField("Thinking budget tokens", text: $model.thinkingBudgetText)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityIdentifier("settings.model.thinking-budget")
                        }
                        if model.descriptors.isEmpty {
                            Text("No additional settings are required for this invocation.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(model.descriptors, id: \.adapter) { descriptor in
                                LabeledContent("Configuration") { Text(verbatim: descriptor.title) }
                            }
                        }
                    }
                }
                .disabled(model.isSaving)
                if let metadata = model.catalogMetadata {
                    VStack(alignment: .leading, spacing: MiraTheme.Spacing.sm) {
                        Text("Model information from the catalog").font(.headline)
                        Text(verbatim: metadata.displayName ?? model.modelID)
                        if let context = metadata.contextWindow { Text("Catalog context limit: \(context) tokens") }
                        if let output = metadata.maxOutputTokens { Text("Catalog output limit: \(output) tokens") }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                Text("New model IDs can be saved immediately. A missing context limit is reported when you send.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let unsupported = model.unsupportedMessage {
                Text(L10n.error(model.unsupportedError ?? MiraError(.unsupported, unsupported), locale: locale))
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let error = model.error {
                Text(L10n.error(error, locale: locale)).font(.callout).foregroundStyle(.red)
            }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") { model.startSave() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!model.canSave)
            }
        }
        .padding(28).frame(width: 590)
        .task { await model.observe() }
        .onChange(of: model.saveConfirmation) { _, _ in dismiss() }
        .onDisappear { Task { await model.stop() } }
        .interactiveDismissDisabled(model.isSaving)
    }

    private func thinkingModeTitle(_ value: String) -> String {
        switch value {
        case "providerDefault": return String(localized: "Provider default", locale: locale)
        case "enabled": return String(localized: "Enabled", locale: locale)
        case "disabled": return String(localized: "Disabled", locale: locale)
        case "adaptive": return String(localized: "Adaptive thinking", locale: locale)
        default: return value
        }
    }
}
