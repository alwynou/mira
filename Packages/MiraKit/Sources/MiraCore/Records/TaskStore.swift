import Foundation

/// Business records only. Callers own a library access lease; no method reads session projections.
public protocol TaskReadStore: Sendable {
    func taskList(workspaceID: WorkspaceID?, includeCompleted: Bool, limit: Int) async throws -> [MiraTask]
    func taskDetail(_ id: MiraTaskID, workspaceID: WorkspaceID?) async throws -> MiraTask
    /// Resolves one immutable revision while checking the current task and workspace in the same read snapshot.
    func taskRevision(_ id: MiraTaskID, revision: Int, workspaceID: WorkspaceID?) async throws -> TaskRevision
    func taskRevisions(_ id: MiraTaskID, workspaceID: WorkspaceID?) async throws -> [TaskRevision]
    func taskProposals(workspaceID: WorkspaceID?) async throws -> [TaskProposal]
}

public protocol TaskStore: TaskReadStore {
    func saveTask(_ id: MiraTaskID, workspaceID: WorkspaceID?, draft: TaskDraft, status: MiraTaskStatus,
                  expectedRevision: Int?, operationID: UUID, authorization: AgentLibraryAuthorization, at: Date) async throws -> MiraTask
    /// Accepted proposals require fresh original journal evidence; the transaction verifies the
    /// complete stored reference, source body, clock, workspace and current library authorization.
    func resolveTaskProposal(_ id: UUID, workspaceID: WorkspaceID?, accept: Bool, correctedDraft: TaskDraft?,
                             source: SessionUserEvidence?, authorization: AgentLibraryAuthorization, at: Date) async throws -> TaskWriteReceipt
    func reminderWork(limit: Int) async throws -> [MiraTask]
    func reminderTaskExists(_ id: MiraTaskID) async throws -> Bool
    func setReminderDelivery(_ id: MiraTaskID, expectedRevision: Int, state: ReminderDeliveryState,
                             error: MiraError?, authorization: AgentLibraryAuthorization, at: Date) async throws -> Bool
    func resumeReminder(_ id: MiraTaskID, workspaceID: WorkspaceID?, expectedRevision: Int,
                        authorization: AgentLibraryAuthorization, at: Date) async throws
}
