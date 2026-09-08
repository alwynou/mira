import SwiftUI
import MiraCore
import MiraProviders

struct ProviderConnectionEditor: View {
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss
    let existing: ProviderConnection?
    let container: AppContainer
    let initialTemplateID: String?
    let isEmbedded: Bool
    let onSaved: (ConnectionID) async -> Void
    @State private var templateID = "openai"
    @State private var name = "OpenAI"
    @State private var kind = ProviderKind.openAICompatible
    @State private var baseURL = "https://api.openai.com/v1"
    @State private var secret = ""
    @State private var allowsHTTP = false
    @State private var error: MiraError?
    @State private var saving = false
    @State private var connectionExpanded = true
    @State private var addressExpanded = false
    @State private var baseline: ProviderConnection?
    @State private var reloadAfterSave = false

    init(existing: ProviderConnection?, container: AppContainer, initialTemplateID: String? = nil,
         isEmbedded: Bool = false, onSaved: @escaping (ConnectionID) async -> Void) {
        self.existing = existing
        self.container = container
        self.initialTemplateID = initialTemplateID
        self.isEmbedded = isEmbedded
        self.onSaved = onSaved
    }

    var body: some View {
        Group {
            if isEmbedded {
                MiraSettingsSection {
                    DisclosureGroup(isExpanded: $connectionExpanded) {
                        editorContent.padding(.top, MiraTheme.Spacing.lg)
                    } label: {
                        Text("Connection Settings")
                            .accessibilityIdentifier("settings.provider.connectionSettings")
                    }
                    .font(MiraTheme.Typography.body.weight(.medium))
                }
            } else {
                VStack(alignment: .leading, spacing: MiraTheme.Spacing.xl) {
                    Text(LocalizedStringKey(existing == nil ? "Add Provider" : "Edit Provider"))
                        .font(MiraTheme.Typography.title)
                    editorContent
                }
                .padding(MiraTheme.Spacing.xxl)
                .frame(width: 590)
                .background(MiraTheme.Colors.canvas)
            }
        }
        .onAppear {
            if let initialTemplateID { templateID = initialTemplateID; applyTemplate() }
            load()
            connectionExpanded = existing == nil || !isEmbedded
            addressExpanded = existing == nil
        }
        .onChange(of: templateID) { _, _ in applyTemplate() }
        .onChange(of: existing) { _, _ in
            // Preserve a dirty draft and its original revision so concurrent edits still conflict.
            if reloadAfterSave || !hasChanges { load(); reloadAfterSave = false }
        }
        .onDisappear { secret = "" }
        .interactiveDismissDisabled(saving)
    }

    private var editorContent: some View {
        VStack(alignment: .leading, spacing: MiraTheme.Spacing.lg) {
            if existing == nil && initialTemplateID == nil {
                MiraSettingsRow("Provider Template") {
                    Picker("Provider Template", selection: $templateID) {
                        ForEach(ProviderModelCatalog.bundled.providers) { provider in
                            Text(verbatim: provider.name).tag(provider.id)
                        }
                        Text("Custom Provider").tag("custom")
                    }.labelsHidden()
                }.disabled(saving)
            }
            VStack(alignment: .leading, spacing: MiraTheme.Spacing.sm) {
                Text("API Key").foregroundStyle(MiraTheme.Colors.secondaryText)
                SecureField(LocalizedStringKey(existing == nil ? "API Key" : "New API Key (leave blank to keep)"), text: $secret)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("settings.provider.apiKey")
            }.disabled(saving)
            DisclosureGroup("API Address and Protocol", isExpanded: $addressExpanded) {
                VStack(alignment: .leading, spacing: MiraTheme.Spacing.lg) {
                    LabeledContent("Name") { TextField("Name", text: $name).labelsHidden() }
                    LabeledContent("Base URL") { TextField("Base URL", text: $baseURL).labelsHidden() }
                    LabeledContent("Protocol") {
                        Picker("Protocol", selection: $kind) {
                            Text("OpenAI Chat Completions Compatible").tag(ProviderKind.openAICompatible)
                            Text("Anthropic Messages").tag(ProviderKind.anthropic)
                        }.labelsHidden()
                    }
                    Toggle("Allow explicitly configured local HTTP services", isOn: $allowsHTTP)
                }
                .textFieldStyle(.roundedBorder)
                .padding(.top, MiraTheme.Spacing.md)
            }.disabled(saving)
            Text("Use a base service URL without credentials, query parameters, fragments, or a provider route suffix. API keys are stored in this Mac’s Keychain.")
                .font(MiraTheme.Typography.caption).foregroundStyle(MiraTheme.Colors.secondaryText)
            if existing == nil {
                Text("New providers start inactive. After saving, activate the provider and select its models.")
                    .font(MiraTheme.Typography.caption).foregroundStyle(MiraTheme.Colors.secondaryText)
            }
            if let error { Text(L10n.error(error, locale: locale)).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                if saving { ProgressView().controlSize(.small) }
                Spacer()
                if isEmbedded {
                    Button("Discard Changes") { secret = ""; load() }
                        .disabled(saving || !hasChanges)
                } else {
                    Button("Cancel", role: .cancel) { secret = ""; dismiss() }
                        .keyboardShortcut(.cancelAction).disabled(saving)
                }
                Button("Save") { Task { await save() } }
                    .buttonStyle(MiraPrimaryButtonStyle())
                    .keyboardShortcut(isEmbedded ? nil : KeyboardShortcut.defaultAction)
                    .disabled(saving || container.isDemo || !hasChanges || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("settings.provider.save")
            }
        }
        .font(MiraTheme.Typography.body)
    }

    private var hasChanges: Bool {
        guard let baseline else { return true }
        return name != baseline.name || kind != baseline.providerKind || baseURL != baseline.baseURL ||
            allowsHTTP != baseline.allowsLoopbackHTTP || !secret.isEmpty
    }

    private func applyTemplate() {
        guard existing == nil else { return }
        if let provider = ProviderModelCatalog.bundled.providers.first(where: { $0.id == templateID }) {
            name = provider.name; kind = provider.providerKind; baseURL = provider.baseURL
        } else {
            name = ""; baseURL = ""; kind = .openAICompatible
        }
        allowsHTTP = false
    }

    private func load() {
        baseline = existing
        guard let existing else { applyTemplate(); return }
        name = existing.name; kind = existing.providerKind; baseURL = existing.baseURL
        allowsHTTP = existing.allowsLoopbackHTTP
        error = nil
    }

    private func save() async {
        saving = true; error = nil
        defer { saving = false }
        do {
            let previous = baseline
            let connection = ProviderConnection(
                id: previous?.id ?? .init(), revision: (previous?.revision ?? 0) + 1,
                name: name.trimmingCharacters(in: .whitespacesAndNewlines), providerKind: kind,
                baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
                credentialReference: previous?.credentialReference ?? UUID().uuidString,
                credentialVersion: previous?.credentialVersion ?? 1, allowsLoopbackHTTP: allowsHTTP,
                isEnabled: previous?.isEnabled ?? false)
            try connection.validate()
            try await container.saveConnection(connection, previous: previous, secret: secret.trimmingCharacters(in: .whitespacesAndNewlines))
            secret = ""
            reloadAfterSave = true
            await onSaved(connection.id)
            if !isEmbedded { dismiss() }
        } catch { self.error = MiraError.safe(error) }
    }
}
