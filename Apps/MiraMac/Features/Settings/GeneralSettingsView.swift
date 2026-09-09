import SwiftUI

struct GeneralSettingsView: View {
    @AppStorage(AppLanguage.preferenceKey) private var languagePreference = ""

    @AppStorage(AppDisplayMode.preferenceKey) private var displayModePreference = AppDisplayMode.initialValue.rawValue

    var body: some View {
        MiraSettingsPage {
            MiraSettingsHeader(title: "General", subtitle: "Customize Mira's display language and appearance.")
            MiraSettingsSection("Language") {
                MiraSettingsRow("Display Language", subtitle: "Changes apply immediately to all Mira windows and are saved for the next launch. Conversation content and model response language are not changed.") {
                    MiraSettingsSelect(
                        title: "Display Language",
                        selection: Binding(
                            get: { AppLanguage.resolve(stored: languagePreference).rawValue },
                            set: { languagePreference = $0 }
                        ),
                        options: [
                            .init(id: AppLanguage.english.rawValue, title: "English"),
                            .init(id: AppLanguage.simplifiedChinese.rawValue, title: "Chinese (Simplified)")
                        ],
                        identifier: "settings.language",
                        maximumWidth: MiraTheme.Layout.selectMaxWidth,
                        menuMaximumWidth: MiraTheme.Layout.selectMenuMaxWidth
                    )
                }
                MiraSettingsDivider()
                Text("macOS manages the language of system menus and file dialogs.")
                    .font(MiraTheme.Typography.caption)
                    .foregroundStyle(MiraTheme.Colors.secondaryText)
            }
            MiraSettingsSection("Appearance") {
                MiraSettingsRow("Display Mode", subtitle: "Choose an appearance for all Mira windows, or follow your system setting.") {
                    MiraSettingsSelect(
                        title: "Display Mode",
                        selection: Binding(
                            get: { AppDisplayMode.resolve(stored: displayModePreference).rawValue },
                            set: { displayModePreference = $0 }
                        ),
                        options: [
                            .init(id: AppDisplayMode.dark.rawValue, title: "Dark"),
                            .init(id: AppDisplayMode.light.rawValue, title: "Light"),
                            .init(id: AppDisplayMode.system.rawValue, title: "Follow System")
                        ],
                        identifier: "settings.displayMode",
                        maximumWidth: MiraTheme.Layout.selectMaxWidth,
                        menuMaximumWidth: MiraTheme.Layout.selectMenuMaxWidth
                    )
                }
            }
        }
    }
}
