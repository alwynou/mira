import Foundation

public protocol WorkspaceStore: Sendable {
    func workspaces() async throws -> [Workspace]
    func workspace(_ id: WorkspaceID) async throws -> Workspace
    func saveWorkspace(_ workspace: Workspace, expectedRevision: Int?, authorization: AgentLibraryAuthorization) async throws
}
