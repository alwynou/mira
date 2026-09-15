import AppKit
import Foundation
import MiraCore
import Observation

/// Presentation owns immutable action requests; library services own their actual work.
@MainActor @Observable
final class DataSettingsModel {
    @ObservationIgnored let container: AppContainer
    private(set) var statusKey: String?
    private(set) var diagnostics: MacLibraryDiagnostics?
    private(set) var isWorking = false
    private(set) var restoredLibrary: MacSelectedLibrary?
    var restoredDirectory: URL? { restoredLibrary?.directory }
    var canActivateRestoredLibrary: Bool {
        restoredLibrary != nil && container.canActivateRestoredLibrary && !isWorking
    }
    private(set) var error: MiraError?
    private(set) var credentialCleanup: MacCredentialCleanupStatus = .complete
    @ObservationIgnored private var action: Task<Void, Never>?
    @ObservationIgnored private var observation: Task<Void, Never>?
    @ObservationIgnored private var retirement: Task<Void, Never>?
    @ObservationIgnored private var observationID = UUID()
    @ObservationIgnored private var presentationID = UUID()

    init(container: AppContainer) { self.container = container }

    func observe() async {
        let id = UUID()
        observationID = id
        diagnostics = nil
        credentialCleanup = .complete
        retireObservation()
        await retirement?.value
        guard !Task.isCancelled, observationID == id, let library = container.library else { return }
        let task = Task { @MainActor [weak self] in
            for await state in await library.observe() {
                guard let self, !Task.isCancelled, self.observationID == id,
                    self.container.library === library
                else { break }
                if state.phase == .ready {
                    await self.refresh(library: library, generation: state.generation, observationID: id)
                } else {
                    self.diagnostics = nil
                    self.credentialCleanup = .complete
                }
            }
            guard let self, self.observationID == id else { return }
            self.diagnostics = nil
            self.credentialCleanup = .complete
        }
        observation = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if observationID == id { observation = nil }
    }

    func stopObserving() async {
        observationID = UUID()
        diagnostics = nil
        credentialCleanup = .complete
        retireObservation()
        await retirement?.value
    }

    /// A closed settings window clears presentation, while retaining an admitted action's guard.
    func clearResults() {
        presentationID = UUID()
        statusKey = nil
        error = nil
        restoredLibrary = nil
    }

    func waitForAction() async { await action?.value }

    func exportBackup() {
        guard !isWorking else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Mira-backup.mirabackup"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        startExport(to: destination)
    }

    func restoreBackup(locale: Locale) {
        guard !isWorking else { return }
        let sourcePanel = NSOpenPanel()
        sourcePanel.canChooseDirectories = true
        sourcePanel.canChooseFiles = false
        sourcePanel.allowsMultipleSelection = false
        sourcePanel.message = L10n.string("Choose a Mira library backup", locale: locale)
        guard sourcePanel.runModal() == .OK, let source = sourcePanel.url else { return }
        let parentPanel = NSOpenPanel()
        parentPanel.canChooseDirectories = true
        parentPanel.canChooseFiles = false
        parentPanel.canCreateDirectories = true
        parentPanel.allowsMultipleSelection = false
        parentPanel.message = L10n.string(
            "Choose a parent directory. Mira will create a separate restored library inside it.", locale: locale)
        guard parentPanel.runModal() == .OK, let parent = parentPanel.url else { return }
        let destination = parent.appendingPathComponent(
            "Mira-Restored-\(UUID().uuidString.prefix(8))", isDirectory: true)
        startRestore(from: source, to: destination)
    }

    func startExport(to destination: URL) {
        guard !isWorking else { return }
        guard let library = container.library else {
            failUnavailable()
            return
        }
        start(library: library) {
            _ = try await library.exportArchive(to: destination)
            return .exported
        }
    }

    func startRestore(from source: URL, to destination: URL) {
        guard !isWorking else { return }
        guard let restoration = container.restoration else {
            failUnavailable()
            return
        }
        start(library: nil) {
            let result = try await restoration.restore(from: source, to: destination)
            return .restored(.init(directory: result.directory, libraryID: result.authorization.libraryID))
        }
    }

    func activateRestoredLibrary() {
        guard canActivateRestoredLibrary, let target = restoredLibrary else { return }
        let container = container
        start(library: nil) {
            try await container.activateRestoredLibrary(target)
            return .activated
        }
    }

    func cleanupFiles() {
        guard !isWorking else { return }
        guard let library = container.library else {
            failUnavailable()
            return
        }
        start(library: library) {
            let pending = await library.pendingMaintenance()
            let request: AgentLibraryMaintenanceRequest
            if let pending {
                guard pending.request.namespace == "knowledge.collect" else {
                    throw MiraError(.busy, "Another library maintenance operation must finish first.")
                }
                request = pending.request
            } else {
                request = .init(
                    id: UUID(), namespace: "knowledge.collect", revision: 1, scope: .library, requestedAt: Date())
            }
            let completed = try await library.maintain(request)
            guard completed.completedAt != nil else {
                throw MiraError(.storage, "Library file cleanup did not finish.")
            }
            return .collected
        }
    }

    func retryCredentialCleanup() {
        guard !isWorking else { return }
        guard let library = container.library else {
            failUnavailable()
            return
        }
        start(library: library) {
            let binding = try await library.binding()
            let result = try await binding.workgroup.credentialSettings.retryCleanup()
            let current = try await library.binding()
            guard current.workgroup === binding.workgroup else {
                throw MiraError(.cancelled, "The library settings changed during credential cleanup.")
            }
            return .credentials(result)
        }
    }

    private enum Result: Sendable {
        case exported
        case restored(MacSelectedLibrary)
        case activated, collected
        case credentials(MacCredentialCleanupStatus)
    }

    private func start(library: MacLibrary?, operation: @escaping @Sendable () async throws -> Result) {
        guard !isWorking else { return }
        clearResults()
        let presentation = presentationID
        isWorking = true
        action = Task { @MainActor in
            defer {
                isWorking = false
                action = nil
            }
            do {
                let result = try await operation()
                guard canPublish(presentation, library: library) else { return }
                switch result {
                case .exported: statusKey = "Backup saved."
                case .restored(let selected):
                    restoredLibrary = selected
                    statusKey = "Backup verified and restored to a separate library."
                case .activated: statusKey = "Restored library is now open."
                case .collected: statusKey = "Unreferenced file cleanup completed."
                case .credentials(let status):
                    credentialCleanup = status
                    switch status {
                    case .complete: statusKey = "Credential cleanup completed."
                    case .pending(let failure): error = failure
                    }
                }
            } catch {
                guard canPublish(presentation, library: library) else { return }
                self.error = MiraError.safe(error)
            }
        }
    }

    private func canPublish(_ id: UUID, library: MacLibrary?) -> Bool {
        presentationID == id && (library == nil || container.library === library)
            && container.status.phase != .closing && container.status.phase != .closed
    }

    private func refresh(library: MacLibrary, generation: UInt64, observationID id: UUID) async {
        do {
            let binding = try await library.binding()
            guard binding.status.generation == generation else { return }
            let diagnostics = try await library.diagnostics()
            let cleanup = await binding.workgroup.credentialSettings.cleanupStatus()
            let current = try await library.binding()
            guard !Task.isCancelled, observationID == id, container.library === library,
                current.workgroup === binding.workgroup, current.status.generation == generation
            else { return }
            self.diagnostics = diagnostics
            self.credentialCleanup = cleanup
        } catch {
            // Maintenance revokes reads. Its terminal status or the explicit action owns any error presentation.
            guard !Task.isCancelled, observationID == id, container.library === library else { return }
            diagnostics = nil
        }
    }

    private func retireObservation() {
        guard let old = observation else { return }
        observation = nil
        old.cancel()
        let previous = retirement
        retirement = Task {
            await previous?.value
            await old.value
        }
    }

    private func failUnavailable() {
        clearResults()
        error = MiraError(.storage, "The library is not open.")
    }
}
