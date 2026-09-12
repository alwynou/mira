import SwiftUI
import MiraCore

@MainActor
struct DataSettingsView: View {
    @Environment(\.miraSettingsPageActive) private var isActive
    @Environment(\.locale) private var locale
    @Bindable var model: DataSettingsModel

    var body: some View {
        MiraSettingsPage {
            Group {
                MiraSettingsSection("Local Library") {
                    MiraSettingsRow("Directory") {
                        Text(verbatim: model.container.directory.path)
                            .textSelection(.enabled).lineLimit(3)
                    }
                    if let diagnostics = model.diagnostics {
                        MiraSettingsRow("SQLite") { Text(diagnostics.sqliteVersion) }
                        MiraSettingsRow("FTS5") { Text(LocalizedStringKey(diagnostics.supportsFTS5 ? "Available" : "Unavailable")) }
                        MiraSettingsRow("Trigram") { Text(LocalizedStringKey(diagnostics.supportsTrigram ? "Available" : "Unavailable")) }
                    }
                    Text("Use disposable data during development. Memory, source files, and long-term recovery will be verified in later milestones.")
                        .font(MiraTheme.Settings.caption).foregroundStyle(MiraTheme.Settings.secondaryText)
                    if let message = model.container.maintenanceMessage {
                        Text(L10n.string(message, locale: locale)).font(MiraTheme.Settings.body).foregroundStyle(.orange)
                        Button("Retry Credential Cleanup") { Task { await model.container.retryCredentialCleanup() } }
                    }
                }
                MiraSettingsSection("Backup and Restore") {
                    Text("Backups contain conversations, configuration, request records, knowledge source versions and files, plus integrity checksums. API keys and other credentials are excluded. Restoring creates a separate directory and preserves the current library.")
                        .font(MiraTheme.Settings.body)
                    HStack {
                        Button("Export Library Backup…") { model.exportBackup() }
                            .accessibilityIdentifier("settings.data.export")
                        Button("Restore to New Directory…") { model.restoreBackup(locale: locale) }
                            .accessibilityIdentifier("settings.data.restore")
                    }.disabled(model.isWorking)
                    Text("Unreferenced managed files are eligible for cleanup after 7 days. Cleanup never removes referenced historical versions and does not rewrite existing backups.")
                        .font(MiraTheme.Settings.caption).foregroundStyle(MiraTheme.Settings.secondaryText)
                    Button("Clean Up Unreferenced Files") { model.cleanupFiles() }.disabled(model.isWorking)
                    if let report = model.cleanupReport {
                        Text(L10n.format("Cleaned up %lld unreferenced files; retained %lld referenced files.", locale: locale, Int64(report.removedCount), Int64(report.retainedCount)))
                            .font(MiraTheme.Settings.body).textSelection(.enabled)
                    }
                    if let error = model.statusError {
                        Text(L10n.error(error, locale: locale)).font(MiraTheme.Settings.body).foregroundStyle(.red).textSelection(.enabled)
                    } else if !model.status.isEmpty {
                        Text(L10n.string(model.status, locale: locale)).font(MiraTheme.Settings.body).textSelection(.enabled)
                    }
                    if let path = model.restoredPath {
                        MiraSettingsRow("Restored Library") { Text(verbatim: path).textSelection(.enabled) }
                    }
                }
            }
        }
        .task(id: isActive) { if isActive { await model.observe() } }
    }
}
