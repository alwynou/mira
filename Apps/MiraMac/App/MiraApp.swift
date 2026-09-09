import AppKit
import SwiftUI

@main
struct MiraApp: App {
    @NSApplicationDelegateAdaptor(MiraAppDelegate.self) private var delegate
    private let container = AppContainer()
    @AppStorage(AppLanguage.preferenceKey) private var languagePreference = ""
    @AppStorage(AppDisplayMode.preferenceKey) private var displayModePreference = AppDisplayMode.initialValue.rawValue
    private var displayMode: AppDisplayMode { .resolve(stored: displayModePreference) }
    private var language: AppLanguage { .resolve(stored: languagePreference) }

    var body: some Scene {
        WindowGroup {
            Group {
                if let application = container.application {
                    ConversationRoot(application: application, container: container)
                        .containerBackground(MiraTheme.Colors.canvas, for: .window)
                        .task {
                            delegate.container = container
                            do { try await container.seedDemo() }
                            catch { /* Demo setup failure is surfaced by the settings/library state. */ }
                        }
                } else {
                    ContentUnavailableView("Unable to Open Library", systemImage: "externaldrive.badge.exclamationmark", description: Text(container.startupError.map { L10n.error($0, locale: language.locale) } ?? L10n.string("Check available storage and directory permissions.", locale: language.locale)))
                        .frame(minWidth: 640, minHeight: 420)
                }
            }
            .environment(\.locale, language.locale)
            .tint(MiraTheme.Colors.accent)
            .preferredColorScheme(displayMode.colorScheme)
            .onChange(of: displayMode, initial: true) { _, mode in
                // Native split panes, menus, and future windows share the saved mode.
                if NSApp.appearance?.name != mode.appearanceName {
                    NSApp.appearance = mode.appearanceName.flatMap { NSAppearance(named: $0) }
                }
            }
        }
        .defaultSize(width: 1100, height: 760)
        .windowToolbarStyle(.unified)
        .commands { MiraSettingsCommands(locale: language.locale) }
        .commands { CommandGroup(replacing: .help) { Link(L10n.string("Mira Documentation", locale: language.locale), destination: URL(string: "https://github.com/alwynou/mira/tree/dev/docs")!) } }
    }
}

@MainActor
final class MiraAppDelegate: NSObject, NSApplicationDelegate {
    var container: AppContainer?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let application = container?.application else { return .terminateNow }
        Task {
            let saved = await application.shutdown()
            sender.reply(toApplicationShouldTerminate: saved)
        }
        return .terminateLater
    }
}
