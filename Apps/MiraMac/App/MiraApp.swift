import AppKit
import SwiftUI

@main
struct MiraApp: App {
    @NSApplicationDelegateAdaptor(MiraAppDelegate.self) private var delegate
    @State private var container: AppContainer
    @State private var settingsModel: SettingsModel
    @AppStorage(AppLanguage.preferenceKey) private var languagePreference = ""
    private var language: AppLanguage { .resolve(stored: languagePreference) }

    init() {
        let container = AppContainer()
        _container = State(initialValue: container)
        _settingsModel = State(initialValue: SettingsModel(container: container))
        delegate.container = container
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let library = container.library {
                    ConversationRoot(library: library, isDemo: container.isDemo)
                        .id(ObjectIdentifier(library))
                        .containerBackground(MiraTheme.Colors.canvas, for: .window)
                } else {
                    LibraryStartupView(container: container)
                }
            }
            .task { await container.start() }
            .environment(\.locale, language.locale)
            .tint(MiraTheme.Colors.accent)
            .modifier(MiraAppAppearance())
        }
        .defaultSize(width: 1100, height: 760)
        .windowToolbarStyle(.unified)
        .commands { MiraSettingsCommands(locale: language.locale) }
        .commands {
            CommandGroup(replacing: .help) {
                Link(
                    L10n.string("Mira Documentation", locale: language.locale),
                    destination: URL(string: "https://github.com/alwynou/mira/tree/dev/docs")!)
            }
        }

        Window("Settings", id: MiraSettingsWindow.id) {
            MiraSettingsRoot(model: settingsModel)
                .onChange(of: container.library.map(ObjectIdentifier.init)) { _, _ in settingsModel.close() }
                .environment(\.locale, language.locale)
                .modifier(MiraAppAppearance())
                .containerBackground(MiraTheme.Settings.canvas, for: .window)
        }
        .defaultSize(width: MiraTheme.Settings.windowWidth, height: MiraTheme.Settings.windowHeight)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
        .windowManagerRole(.associated)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
    }
}
