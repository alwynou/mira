import SwiftUI
import MiraCore
import MiraProviders

struct ProviderConnectionEditor: View {
    @Environment(\.locale) private var locale
    @FocusState private var isKeyFocused: Bool
    @Bindable var settings: ProviderConnectionSettingsModel
    let isUnavailable: Bool
    let onMutation: () -> Void
    let onSaved: @MainActor (ProviderConnection) async -> Void

    var body: some View {
        Group {
            MiraSettingsSection {
                heading
                MiraSettingsFormRow("API Key") {
                    MiraSettingsCredentialField(text: $settings.secret, hasStoredKey: settings.hasStoredKey,
                                                showsRequiredError: settings.requiresAPIKey)
                        .focused($isKeyFocused)
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
                VStack(alignment: .leading, spacing: MiraTheme.Spacing.sm) {
                    MiraSettingsFormRow("Test Connectivity", subtitle: "Enabling only saves the provider state. The API key is checked when you use a model or choose Test.") {
                        testControls
                    }
                    if settings.error != nil || settings.statusKey != nil || settings.testModels.isEmpty {
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
    }

    private var heading: some View {
        Toggle(isOn: Binding(get: { settings.isEnabled }, set: { enabled in
            onMutation(); settings.setEnabled(enabled, onSaved: onSaved)
            if settings.requiresAPIKey { isKeyFocused = true }
        })) {
            HStack(spacing: MiraTheme.Spacing.md) {
                MiraProviderIcon(providerID: settings.providerID, size: MiraTheme.Layout.providerHeadingIconSize)
                VStack(alignment: .leading, spacing: MiraTheme.Spacing.xs) {
                    Text(verbatim: settings.displayName).font(MiraTheme.Settings.body.weight(.semibold))
                    Text(verbatim: settings.baseline?.baseURL ?? settings.baseURL)
                        .font(MiraTheme.Settings.caption)
                        .foregroundStyle(MiraTheme.Settings.secondaryText)
                        .textSelection(.enabled)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .disabled(isUnavailable || settings.isWorking)
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
