import SwiftUI
import MiraCore
import MiraProviders

struct ProviderConnectionEditor: View {
    @Environment(\.locale) private var locale
    let existing: ProviderConnection?
    let configuration: ModelConfiguration
    let isUnavailable: Bool
    let onMutation: () -> Void
    let onSaved: @MainActor (ConnectionID) async -> Void
    @State private var settings: ProviderConnectionSettingsModel

    init(existing: ProviderConnection?, template: CatalogProvider?, library: ProviderLibraryModel,
         onMutation: @escaping () -> Void, onSaved: @escaping @MainActor (ConnectionID) async -> Void) {
        self.existing = existing; configuration = library.configuration
        isUnavailable = library.isWorking || library.container.isDemo
        self.onMutation = onMutation; self.onSaved = onSaved
        _settings = State(initialValue: ProviderConnectionSettingsModel(existing: existing, template: template, container: library.container))
    }

    var body: some View {
        Group {
            MiraSettingsSection {
                heading
                MiraSettingsFormRow("API Key") {
                    SecureField(LocalizedStringKey(settings.hasStoredKey ? "New API Key (leave blank to keep)" : "API Key"), text: $settings.secret)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("API Key")
                        .accessibilityIdentifier("settings.provider.apiKey")
                }
                .disabled(settings.isWorking)
                MiraSettingsFormRow("API Proxy URL") {
                    TextField("API Proxy URL", text: $settings.baseURL)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("settings.provider.baseURL")
                }
                .disabled(settings.isWorking)
                MiraSettingsFormRow("Test Model") {
                    MiraSettingsSelect(title: "Test Model", selection: $settings.selectedModelID,
                        options: settings.testModels.map { .init(id: $0.id, verbatimTitle: $0.id) },
                        identifier: "settings.provider.testModel", placeholder: "Select a model",
                        maximumWidth: 220)
                        .disabled(settings.isWorking)
                }
                MiraSettingsFormRow("Test Connectivity", subtitle: "Testing sends a short request using the selected model. Enabling requires a successful test. A saved API key can be reused.") {
                    testControls
                }
                if settings.error != nil || settings.statusKey != nil || settings.testModels.isEmpty {
                    feedback
                }
                HStack {
                    if settings.isWorking && !settings.isTesting { ProgressView().controlSize(.small) }
                    Spacer(minLength: 0)
                    if settings.hasChanges {
                        Button("Discard Changes") { settings.discardChanges() }
                            .buttonStyle(MiraSettingsButtonStyle())
                            .disabled(settings.isWorking)
                    }
                    Button("Save") { onMutation(); settings.save(onSaved: onSaved) }
                        .buttonStyle(MiraSettingsButtonStyle(isPrimary: true))
                        .disabled(isUnavailable || !settings.canSave)
                        .accessibilityIdentifier("settings.provider.save")
                }
                .controlSize(.small)
            }
        }
        .onChange(of: configuration, initial: true) { _, next in settings.update(existing: existing, configuration: next) }
        .onDisappear { settings.disappear() }
    }

    private var heading: some View {
        Toggle(isOn: Binding(get: { settings.isEnabled }, set: { enabled in
            onMutation(); settings.setEnabled(enabled, onSaved: onSaved)
        })) {
            HStack(spacing: MiraTheme.Spacing.md) {
                MiraProviderIcon(providerID: settings.providerID, size: MiraTheme.Layout.providerHeadingIconSize)
                VStack(alignment: .leading, spacing: MiraTheme.Spacing.xs) {
                    Text(verbatim: settings.displayName).font(MiraTheme.Settings.body.weight(.semibold))
                    Text(verbatim: existing?.baseURL ?? settings.baseURL)
                        .font(MiraTheme.Settings.caption)
                        .foregroundStyle(MiraTheme.Settings.secondaryText)
                        .textSelection(.enabled)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.switch)
        .disabled(isUnavailable || settings.isWorking || (!settings.isEnabled && !settings.canTest))
        .accessibilityLabel("Active")
        .accessibilityIdentifier("settings.provider.active")
    }

    @ViewBuilder private var testControls: some View {
        if settings.isTesting {
            Button("Cancel") { settings.cancel() }
                .buttonStyle(MiraSettingsButtonStyle())
        } else {
            Button("Test") { settings.test() }
                .buttonStyle(MiraSettingsButtonStyle())
                .disabled(isUnavailable || !settings.canTest)
                .accessibilityIdentifier("settings.provider.test")
        }
    }

    private var feedback: some View {
        VStack(alignment: .leading, spacing: MiraTheme.Spacing.xs) {
            if let error = settings.error {
                Text(L10n.error(error, locale: locale)).foregroundStyle(.red).textSelection(.enabled)
            } else if let key = settings.statusKey {
                Label(LocalizedStringKey(key), systemImage: settings.isTesting ? "network" : "checkmark.circle")
                    .foregroundStyle(settings.isTesting ? MiraTheme.Settings.secondaryText : MiraTheme.Colors.active)
            }
            if settings.testModels.isEmpty {
                Text("Add and configure a text model to test this provider.")
                    .foregroundStyle(MiraTheme.Settings.secondaryText)
            }
        }
        .font(MiraTheme.Settings.caption)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("settings.provider.testStatus")
    }
}
