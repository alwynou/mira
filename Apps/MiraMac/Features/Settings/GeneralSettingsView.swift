import SwiftUI

struct GeneralSettingsView: View {
    @AppStorage(AppLanguage.preferenceKey) private var languagePreference = ""

    var body: some View {
        MiraSettingsPage {
            MiraSettingsHeader(title: "General", subtitle: "Customize Mira's display language.")
            MiraSettingsSection("Language") {
                MiraSettingsRow("Display Language", subtitle: "Changes apply immediately to all Mira windows and are saved for the next launch. Conversation content and model response language are not changed.") {
                    Picker("Display Language", selection: Binding(
                        get: { AppLanguage.resolve(stored: languagePreference) },
                        set: { languagePreference = $0.rawValue }
                    )) {
                        Text("English").tag(AppLanguage.english)
                        Text("Chinese (Simplified)").tag(AppLanguage.simplifiedChinese)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
                MiraSettingsDivider()
                Text("macOS manages the language of system menus and file dialogs.")
                    .font(MiraTheme.Typography.caption)
                    .foregroundStyle(MiraTheme.Colors.secondaryText)
            }
        }
    }
}
