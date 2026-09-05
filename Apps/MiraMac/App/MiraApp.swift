import AppKit
import SwiftUI

@main
struct MiraApp: App {
    @NSApplicationDelegateAdaptor(MiraAppDelegate.self) private var delegate
    private let container = AppContainer()

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
                    ContentUnavailableView("无法打开资料库", systemImage: "externaldrive.badge.exclamationmark", description: Text(container.startupError?.message ?? "请检查存储空间与目录权限。"))
                        .frame(minWidth: 640, minHeight: 420)
                }
            }
        }
        .defaultSize(width: 1100, height: 760)
        .commands { CommandGroup(replacing: .help) { Link("Mira 项目文档", destination: URL(string: "https://github.com/alwynou/mira/tree/dev/docs")!) } }
        Settings { SettingsView(container: container) }
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
