import AppKit
import SwiftUI
import MiraCore
import MiraProviders

struct SettingsView: View {
    @Environment(\.locale) private var locale
    @AppStorage(AppLanguage.preferenceKey) private var languagePreference = ""
    let container: AppContainer
    @State private var status = ""
    @State private var diagnostics: StorageDiagnostics?
    @State private var isWorking = false
    @State private var restoredPath: String?

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { generalSettings }
            Tab("Providers", systemImage: "network") { ProviderConfigurationView(container: container) }
            Tab("Data", systemImage: "externaldrive") { dataSettings }
        }.padding(20).frame(width: 900, height: 700)
            .task {
                guard let application = container.application else { return }
                for await _ in await application.events() {
                    if Task.isCancelled { return }
                    do { diagnostics = try await application.diagnostics() }
                    catch { status = MiraError.safe(error).message }
                }
            }
    }

    private var generalSettings: some View {
        Form {
            Section("Language") {
                Picker("Display Language", selection: Binding(
                    get: { AppLanguage.resolve(stored: languagePreference) },
                    set: { languagePreference = $0.rawValue }
                )) {
                    Text("English").tag(AppLanguage.english)
                    Text("Chinese (Simplified)").tag(AppLanguage.simplifiedChinese)
                }
                Text("Changes apply immediately to all Mira windows and are saved for the next launch. Conversation content and model response language are not changed.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("macOS manages the language of system menus and file dialogs.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }

    private var dataSettings: some View {
        Form {
            Section("Local Library") {
                LabeledContent("Directory") { Text(container.directory.path).textSelection(.enabled).lineLimit(3) }
                if let diagnostics {
                    LabeledContent("SQLite", value: diagnostics.sqliteVersion)
                    LabeledContent("FTS5") { Text(LocalizedStringKey(diagnostics.supportsFTS5 ? "Available" : "Unavailable")) }
                    LabeledContent("Trigram") { Text(LocalizedStringKey(diagnostics.supportsTrigram ? "Available" : "Unavailable")) }
                }
                Text("Use disposable data during development. Memory, source files, and long-term recovery will be verified in later milestones.").font(.caption).foregroundStyle(.secondary)
                if let message = container.maintenanceMessage {
                    Text(L10n.string(message, locale: locale)).font(.callout).foregroundStyle(.orange)
                    Button("Retry Credential Cleanup") { Task { await container.retryCredentialCleanup() } }
                }
            }
            Section("Backup and Restore") {
                Text("Backups contain conversations, configuration, and local request records, but no API keys. Store backups securely. Restoring creates a separate directory and preserves the current library.")
                HStack {
                    Button("Export Library Backup…") { exportBackup() }
                    Button("Restore to New Directory…") { restoreBackup() }
                }.disabled(isWorking)
                if !status.isEmpty { Text(L10n.string(status, locale: locale)).font(.callout).textSelection(.enabled) }
                if let restoredPath { LabeledContent("Restored Library") { Text(verbatim: restoredPath).textSelection(.enabled) } }
            }
        }.formStyle(.grouped)
    }
    private func exportBackup() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Mira-backup.sqlite"; panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                guard let application = container.application else { throw MiraError(.storage, "The library is not open.") }
                try await application.exportBackup(to: url); status = "Backup saved."
            }
            catch { status = MiraError.safe(error).message }
        }
    }
    private func restoreBackup() {
        let sourcePanel = NSOpenPanel(); sourcePanel.canChooseDirectories = false; sourcePanel.allowsMultipleSelection = false
        sourcePanel.message = L10n.string("Choose a Mira library backup", locale: locale)
        guard sourcePanel.runModal() == .OK, let source = sourcePanel.url else { return }
        let folderPanel = NSOpenPanel(); folderPanel.canChooseDirectories = true; folderPanel.canChooseFiles = false
        folderPanel.canCreateDirectories = true; folderPanel.message = L10n.string("Choose a parent directory. Mira will create a separate restored library inside it.", locale: locale)
        guard folderPanel.runModal() == .OK, let parent = folderPanel.url else { return }
        let destination = parent.appendingPathComponent("Mira-Restored-\(UUID().uuidString.prefix(8))", isDirectory: true)
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                guard let application = container.application else { throw MiraError(.storage, "The library is not open.") }
                try await application.restoreBackup(from: source, to: destination)
                restoredPath = destination.path
                status = "Backup verified and restored. The current library is still open. See the development guide to switch libraries."
            } catch { status = MiraError.safe(error).message }
        }
    }
}
