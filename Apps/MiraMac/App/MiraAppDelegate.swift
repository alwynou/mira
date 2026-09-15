import AppKit
import MiraCore

/// The application owns termination even when no window has finished starting.
@MainActor
final class MiraAppDelegate: NSObject, NSApplicationDelegate {
    var container: AppContainer?
    var confirmUnsettledClose: @MainActor (MacLibraryCloseResult) -> Bool = MiraAppDelegate.confirmClose
    private var terminationTask: Task<Void, Never>?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        requestTermination { sender.reply(toApplicationShouldTerminate: $0) }
    }

    /// A single close owns every startup and runtime resource before replying to AppKit.
    func requestTermination(reply: @escaping @MainActor (Bool) -> Void) -> NSApplication.TerminateReply {
        guard let container else { return .terminateNow }
        guard terminationTask == nil else { return .terminateLater }
        terminationTask = Task {
            let result = await container.close()
            let shouldQuit = result.isSettled || confirmUnsettledClose(result)
            terminationTask = nil
            reply(shouldQuit)
        }
        return .terminateLater
    }

    private static func confirmClose(_ result: MacLibraryCloseResult) -> Bool {
        let locale = AppLanguage.resolve(stored: UserDefaults.standard.string(forKey: AppLanguage.preferenceKey) ?? "")
            .locale
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.string("Library closed with an error", locale: locale)
        let detail =
            result.storageError.map { L10n.error($0, locale: locale) }
            ?? L10n.string("Some executions could not finish saving before library closure.", locale: locale)
        alert.informativeText =
            detail + "\n\n" + L10n.string("The library is closed. Quit and reopen Mira to continue.", locale: locale)
        alert.addButton(withTitle: L10n.string("Quit Mira", locale: locale))
        alert.addButton(withTitle: L10n.string("Keep Mira Open", locale: locale))
        return alert.runModal() == .alertFirstButtonReturn
    }
}
