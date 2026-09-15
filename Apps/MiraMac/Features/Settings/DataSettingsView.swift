import MiraCore
import SwiftUI

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
                        MiraSettingsRow("FTS5") {
                            Text(LocalizedStringKey(diagnostics.supportsFTS5 ? "Available" : "Unavailable"))
                        }
                        MiraSettingsRow("Trigram") {
                            Text(LocalizedStringKey(diagnostics.supportsTrigram ? "Available" : "Unavailable"))
                        }
                    }
                    if case .pending(let error) = model.credentialCleanup {
                        Text(L10n.error(error, locale: locale)).font(MiraTheme.Settings.body).foregroundStyle(.orange)
                        Button("Retry Credential Cleanup") { model.retryCredentialCleanup() }
                            .disabled(model.isWorking)
                    }
                }
                MiraSettingsSection("Backup and Restore") {
                    Text(
                        "Backups contain conversations, configuration, request records, knowledge source versions and files, plus integrity checksums. API keys and other credentials are excluded. Restoring creates a separate directory and preserves the current library."
                    )
                    .font(MiraTheme.Settings.body)
                    HStack {
                        Button("Export Library Backup…") { model.exportBackup() }
                            .accessibilityIdentifier("settings.data.export")
                        Button("Restore to New Directory…") { model.restoreBackup(locale: locale) }
                            .accessibilityIdentifier("settings.data.restore")
                    }.disabled(model.isWorking)
                    Text(
                        "Cleanup removes unreferenced managed files after active library work has stopped. Referenced historical versions and existing backups are preserved."
                    )
                    .font(MiraTheme.Settings.caption).foregroundStyle(MiraTheme.Settings.secondaryText)
                    Button("Clean Up Unreferenced Files") { model.cleanupFiles() }.disabled(model.isWorking)
                    if let error = model.error {
                        Text(L10n.error(error, locale: locale)).font(MiraTheme.Settings.body).foregroundStyle(.red)
                            .textSelection(.enabled)
                    } else if let key = model.statusKey {
                        Text(L10n.string(key, locale: locale)).font(MiraTheme.Settings.body).textSelection(.enabled)
                    }
                    if let directory = model.restoredDirectory {
                        MiraSettingsRow("Restored Library") { Text(verbatim: directory.path).textSelection(.enabled) }
                        if model.container.canActivateRestoredLibrary {
                            Button("Open Restored Library") { model.activateRestoredLibrary() }
                                .disabled(!model.canActivateRestoredLibrary)
                                .accessibilityIdentifier("settings.data.activateRestored")
                        }
                    }
                }
            }
        }
        .task(id: isActive) {
            if isActive { await model.observe() } else { await model.stopObserving() }
        }
        .onDisappear { Task { await model.stopObserving() } }
    }
}
