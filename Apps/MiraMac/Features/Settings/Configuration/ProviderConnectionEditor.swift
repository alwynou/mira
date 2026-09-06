import SwiftUI
import MiraCore

struct ProviderConnectionEditor: View {
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss
    let existing: ProviderConnection?
    let container: AppContainer
    let onSaved: (ConnectionID) async -> Void
    @State private var template = ProviderTemplate.openAI
    @State private var name = "OpenAI"
    @State private var kind = ProviderKind.openAICompatible
    @State private var baseURL = "https://api.openai.com/v1"
    @State private var secret = ""
    @State private var allowsHTTP = false
    @State private var error: MiraError?
    @State private var saving = false

    private enum ProviderTemplate: Hashable { case openAI, anthropic, custom }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(LocalizedStringKey(existing == nil ? "Add Provider" : "Edit Provider")).font(.title2.weight(.semibold))
            Form {
                if existing == nil {
                    Picker("Provider Template", selection: $template) {
                        Text("OpenAI").tag(ProviderTemplate.openAI)
                        Text("Anthropic").tag(ProviderTemplate.anthropic)
                        Text("Custom Provider").tag(ProviderTemplate.custom)
                    }
                }
                TextField("Name", text: $name)
                Picker("Protocol", selection: $kind) {
                    Text("OpenAI Chat Completions Compatible").tag(ProviderKind.openAICompatible)
                    Text("Anthropic Messages").tag(ProviderKind.anthropic)
                }
                TextField("Base URL", text: $baseURL)
                SecureField(LocalizedStringKey(existing == nil ? "API Key" : "New API Key (leave blank to keep)"), text: $secret)
                Toggle("Allow explicitly configured local HTTP services", isOn: $allowsHTTP)
            }.disabled(saving)
            Text("Use a base service URL without credentials, query parameters, fragments, or a provider route suffix. API keys are stored in this Mac’s Keychain.")
                .font(.caption).foregroundStyle(.secondary)
            if existing == nil {
                Text("New providers start inactive. After saving, activate the provider and select its models.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let error { Text(L10n.error(error, locale: locale)).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { secret = ""; dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                Button("Save") { Task { await save() } }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(saving || container.isDemo || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(28).frame(width: 590)
        .onAppear { load() }
        .onChange(of: template) { _, _ in applyTemplate() }
        .onDisappear { secret = "" }
        .interactiveDismissDisabled(saving)
    }

    private func applyTemplate() {
        guard existing == nil else { return }
        switch template {
        case .openAI: name = "OpenAI"; kind = .openAICompatible; baseURL = "https://api.openai.com/v1"
        case .anthropic: name = "Anthropic"; kind = .anthropic; baseURL = "https://api.anthropic.com/v1"
        case .custom: name = ""; baseURL = ""; kind = .openAICompatible
        }
    }

    private func load() {
        guard let existing else { return }
        name = existing.name; kind = existing.providerKind; baseURL = existing.baseURL
        allowsHTTP = existing.allowsLoopbackHTTP
    }

    private func save() async {
        saving = true; error = nil
        defer { saving = false }
        do {
            let connection = ProviderConnection(
                id: existing?.id ?? .init(), revision: (existing?.revision ?? 0) + 1,
                name: name.trimmingCharacters(in: .whitespacesAndNewlines), providerKind: kind,
                baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
                credentialReference: existing?.credentialReference ?? UUID().uuidString,
                credentialVersion: existing?.credentialVersion ?? 1, allowsLoopbackHTTP: allowsHTTP,
                isEnabled: existing?.isEnabled ?? false)
            try connection.validate()
            try await container.saveConnection(connection, previous: existing, secret: secret.trimmingCharacters(in: .whitespacesAndNewlines))
            secret = ""; await onSaved(connection.id); dismiss()
        } catch { self.error = MiraError.safe(error) }
    }
}
