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
        VStack(alignment: .leading, spacing: MiraTheme.Spacing.xl) {
            heading
            VStack(alignment: .leading, spacing: MiraTheme.Spacing.md) {
                MiraSettingsSection {
                    MiraSettingsFormRow("API Key") {
                        SecureField(LocalizedStringKey(settings.hasStoredKey ? "New API Key (leave blank to keep)" : "API Key"), text: $settings.secret)
                            .textFieldStyle(MiraSettingsTextFieldStyle())
                            .accessibilityLabel("API Key")
                            .accessibilityIdentifier("settings.provider.apiKey")
                    }
                    .disabled(settings.isWorking)
                    MiraSettingsDivider()
                    MiraSettingsFormRow("API Proxy URL") {
                        TextField("API Proxy URL", text: $settings.baseURL)
                            .textFieldStyle(MiraSettingsTextFieldStyle())
                            .accessibilityIdentifier("settings.provider.baseURL")
                    }
                    .disabled(settings.isWorking)
                    MiraSettingsDivider()
                    VStack(alignment: .leading, spacing: MiraTheme.Spacing.sm) {
                        MiraSettingsFormRow("Test Connectivity", subtitle: "Testing sends a short request using the selected model. Enabling requires a successful test. A saved API key can be reused.") {
                            testControls
                        }
                        feedback
                    }
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
        .font(MiraTheme.Typography.body)
        .onChange(of: configuration, initial: true) { _, next in settings.update(existing: existing, configuration: next) }
        .onDisappear { settings.disappear() }
    }

    private var heading: some View {
        HStack(alignment: .center, spacing: MiraTheme.Spacing.md) {
            MiraProviderIcon(providerID: settings.providerID, size: MiraTheme.Layout.providerHeadingIconSize)
            VStack(alignment: .leading, spacing: MiraTheme.Spacing.xs) {
                Text(verbatim: settings.displayName).font(MiraTheme.Typography.providerTitle)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: existing?.baseURL ?? settings.baseURL).font(MiraTheme.Typography.caption)
                    .foregroundStyle(MiraTheme.Colors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            Spacer(minLength: MiraTheme.Spacing.sm)
            Toggle("Active", isOn: Binding(get: { settings.isEnabled }, set: { enabled in
                onMutation(); settings.setEnabled(enabled, onSaved: onSaved)
            }))
            .toggleStyle(.switch).controlSize(.small).font(MiraTheme.Typography.caption).fixedSize()
            .disabled(isUnavailable || settings.isWorking || (!settings.isEnabled && !settings.canTest))
            .accessibilityIdentifier("settings.provider.active")
        }
    }

    private var testControls: some View {
        HStack(spacing: MiraTheme.Spacing.sm) {
            MiraSettingsSelect(title: "Test Model", selection: $settings.selectedModelID,
                               options: settings.testModels.map { .init(id: $0.id, verbatimTitle: $0.id) },
                               identifier: "settings.provider.testModel", placeholder: "Select a model", minimumWidth: 80, maximumWidth: 180)
                .disabled(settings.isWorking)
            if settings.isTesting {
                Button("Cancel") { settings.cancel() }
                    .buttonStyle(MiraSettingsButtonStyle()).fixedSize()
            } else {
                Button("Test") { settings.test() }
                    .buttonStyle(MiraSettingsButtonStyle())
                    .fixedSize()
                    .disabled(isUnavailable || !settings.canTest)
                    .accessibilityIdentifier("settings.provider.test")
            }
        }
        .controlSize(.small)
    }

    private var feedback: some View {
        VStack(alignment: .leading, spacing: MiraTheme.Spacing.xs) {
            if let error = settings.error {
                Text(L10n.error(error, locale: locale)).foregroundStyle(.red).textSelection(.enabled)
            } else if let key = settings.statusKey {
                Label(LocalizedStringKey(key), systemImage: settings.isTesting ? "network" : "checkmark.circle")
                    .foregroundStyle(settings.isTesting ? MiraTheme.Colors.secondaryText : MiraTheme.Colors.active)
            }
            if settings.testModels.isEmpty {
                Text("Add and configure a text model to test this provider.")
                    .foregroundStyle(MiraTheme.Colors.secondaryText)
            }
        }
        .font(MiraTheme.Typography.caption)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("settings.provider.testStatus")
    }
}
