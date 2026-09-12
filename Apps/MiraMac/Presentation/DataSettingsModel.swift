import AppKit
import Foundation
import Observation
import MiraCore

@MainActor @Observable
final class DataSettingsModel {
    @ObservationIgnored let container: AppContainer
    var status = ""
    var diagnostics: StorageDiagnostics?
    var isWorking = false
    var restoredPath: String?
    var statusError: MiraError?
    var cleanupReport: BlobCollectionReport?

    init(container: AppContainer) { self.container = container }

    func observe() async {
        await refreshDiagnostics()
        guard !Task.isCancelled, let application = container.application else { return }
        let stream = await application.events()
        for await event in stream {
            guard !Task.isCancelled else { return }
            switch event {
            case .changed, .configurationChanged, .conversationChanged, .conversationContentInvalidated:
                await refreshDiagnostics()
            default: break
            }
        }
    }

    private func refreshDiagnostics() async {
        do { diagnostics = try await container.application?.diagnostics() }
        catch { statusError = MiraError.safe(error) }
    }

    func exportBackup() {
        guard !isWorking else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Mira-backup.mirabackup"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isWorking = true
        let accessed = url.startAccessingSecurityScopedResource()
        Task { @MainActor in
            defer { if accessed { url.stopAccessingSecurityScopedResource() }; isWorking = false }
            do {
                guard let application = container.application else { throw MiraError(.storage, "The library is not open.") }
                try await application.exportBackup(to: url)
                status = "Backup saved."; statusError = nil; cleanupReport = nil
            } catch { status = ""; statusError = MiraError.safe(error) }
        }
    }

    func restoreBackup(locale: Locale) {
        guard !isWorking else { return }
        let sourcePanel = NSOpenPanel()
        sourcePanel.canChooseDirectories = true; sourcePanel.canChooseFiles = false; sourcePanel.allowsMultipleSelection = false
        sourcePanel.message = L10n.string("Choose a Mira library backup", locale: locale)
        guard sourcePanel.runModal() == .OK, let source = sourcePanel.url else { return }
        let folderPanel = NSOpenPanel()
        folderPanel.canChooseDirectories = true; folderPanel.canChooseFiles = false; folderPanel.canCreateDirectories = true
        folderPanel.message = L10n.string("Choose a parent directory. Mira will create a separate restored library inside it.", locale: locale)
        guard folderPanel.runModal() == .OK, let parent = folderPanel.url else { return }
        let destination = parent.appendingPathComponent("Mira-Restored-\(UUID().uuidString.prefix(8))", isDirectory: true)
        isWorking = true
        let sourceAccessed = source.startAccessingSecurityScopedResource()
        let parentAccessed = parent.startAccessingSecurityScopedResource()
        Task { @MainActor in
            defer { if parentAccessed { parent.stopAccessingSecurityScopedResource() }; if sourceAccessed { source.stopAccessingSecurityScopedResource() }; isWorking = false }
            do {
                guard let application = container.application else { throw MiraError(.storage, "The library is not open.") }
                try await application.restoreBackup(from: source, to: destination)
                restoredPath = destination.path
                status = "Backup verified and restored. The current library is still open. See the development guide to switch libraries."; statusError = nil; cleanupReport = nil
            } catch { status = ""; statusError = MiraError.safe(error) }
        }
    }

    func cleanupFiles() {
        guard !isWorking else { return }
        isWorking = true
        Task { @MainActor in
            defer { isWorking = false }
            do {
                guard let application = container.application else { throw MiraError(.storage, "The library is not open.") }
                cleanupReport = try await application.collectUnreferencedBlobs(); status = ""; statusError = nil
            } catch { status = ""; statusError = MiraError.safe(error) }
        }
    }
}
