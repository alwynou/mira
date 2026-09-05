import AppKit
import SwiftUI

@main
struct MiraApp: App {
    @NSApplicationDelegateAdaptor(MiraAppDelegate.self) private var delegate
    private let container = AppContainer()
    @AppStorage(AppLanguage.preferenceKey) private var languagePreference = ""
    private var language: AppLanguage { .resolve(stored: languagePreference) }

    var body: some Scene {
        WindowGroup {
            Group {
                if let application = container.application {
                    ConversationRoot(application: application, isDemo: container.isDemo)
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
        }
        .defaultSize(width: 1100, height: 760)
        .commands { CommandGroup(replacing: .help) { Link(L10n.string("Mira Documentation", locale: language.locale), destination: URL(string: "https://github.com/alwynou/mira/tree/dev/docs")!) } }
        Settings { SettingsView(container: container).environment(\.locale, language.locale) }
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
