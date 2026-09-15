import Foundation
import MiraCore
import Observation

@MainActor @Observable
final class WorkspaceEditorModel {
    @ObservationIgnored let workspaces: WorkspaceApplication
    @ObservationIgnored let settings: any MacModelSettings
    @ObservationIgnored private var baseline: Workspace?
    @ObservationIgnored private let draftID: WorkspaceID
    @ObservationIgnored private var hasLoadedConnections = false
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var activeSaveGeneration: UUID?
    @ObservationIgnored private var presentationGeneration = UUID()

    var name: String
    var background: String
    var allowsRemoteSend: Bool
    var restrictConnections: Bool
    var allowedConnections: Set<ConnectionID>
    private(set) var connections: [AgentConfiguredConnection] = []
    private(set) var isSaving = false
    private(set) var error: MiraError?

    init(workspaces: WorkspaceApplication, settings: any MacModelSettings, workspace: Workspace?) {
        self.workspaces = workspaces
        self.settings = settings
        baseline = workspace
        draftID = workspace?.id ?? WorkspaceID()
        name = workspace?.name ?? ""
        background = workspace?.background ?? ""
        allowsRemoteSend = workspace?.allowsRemoteSend ?? true
        restrictConnections = workspace?.allowedConnectionIDs != nil
        allowedConnections = workspace?.allowedConnectionIDs ?? []
    }

    func loadConnections() async {
        guard !hasLoadedConnections else { return }
        let request = generation
        let presentation = presentationGeneration
        do {
            let values = try await settings.connections(after: nil, limit: 128)
            guard !Task.isCancelled, request == generation, presentation == presentationGeneration else { return }
            connections = values
            hasLoadedConnections = true
        } catch {
            guard !Task.isCancelled, request == generation, presentation == presentationGeneration else { return }
            self.error = MiraError.safe(error)
        }
    }

    func dismiss() {
        invalidatePresentation()
    }

    func invalidatePresentation() {
        presentationGeneration = UUID()
    }

    func save() async -> Bool {
        guard !isSaving, !Task.isCancelled else { return false }
        let token = UUID()
        generation = token
        activeSaveGeneration = token
        let presentation = presentationGeneration
        isSaving = true
        error = nil
        defer {
            if activeSaveGeneration == token {
                activeSaveGeneration = nil
                isSaving = false
            }
        }

        let value: Workspace
        let expectedRevision: Int?
        if let baseline {
            guard baseline.revision < Int.max else {
                error = MiraError(.conflict, "The workspace revision cannot be advanced.")
                return false
            }
            value = Workspace(
                id: baseline.id, name: name, background: background,
                allowsRemoteSend: allowsRemoteSend, revision: baseline.revision + 1,
                allowedConnectionIDs: restrictConnections ? allowedConnections : nil)
            expectedRevision = baseline.revision
        } else {
            value = Workspace(
                id: draftID, name: name, background: background,
                allowsRemoteSend: allowsRemoteSend, revision: 1,
                allowedConnectionIDs: restrictConnections ? allowedConnections : nil)
            expectedRevision = nil
        }

        do {
            try await workspaces.save(value, expectedRevision: expectedRevision)
            // Keep the committed revision even when presentation cancellation
            // wins the race after the application service accepted the write.
            baseline = value
            guard !Task.isCancelled, activeSaveGeneration == token, presentation == presentationGeneration else {
                return false
            }
            return true
        } catch {
            guard !Task.isCancelled, activeSaveGeneration == token, presentation == presentationGeneration else {
                return false
            }
            self.error = MiraError.safe(error)
            return false
        }
    }
}
