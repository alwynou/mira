import Foundation

public protocol TaskStore: Sendable {
    func taskList(workspaceID: WorkspaceID?, includeCompleted: Bool, limit: Int) throws -> [MiraTask]
    func taskDetail(_ id: MiraTaskID, workspaceID: WorkspaceID?) throws -> MiraTask
    func taskRevisions(_ id: MiraTaskID, workspaceID: WorkspaceID?) throws -> [TaskRevision]
    func saveTask(_ id: MiraTaskID, workspaceID: WorkspaceID?, draft: TaskDraft, status: MiraTaskStatus, expectedRevision: Int?, operationID: UUID, at: Date) throws -> MiraTask
    func taskProposals(workspaceID: WorkspaceID?) throws -> [TaskProposal]
    func resolveTaskProposal(_ id: UUID, workspaceID: WorkspaceID?, accept: Bool, correctedDraft: TaskDraft?, at: Date) throws -> TaskWriteReceipt
    /// Revalidates the persisted invocation, source, scope and proposal within the commit transaction.
    func performTaskTool(arguments: JSONValue, context: ToolContext, at: Date) throws -> TaskWriteReceipt
    func taskToolReference(context: ToolContext) throws -> TaskEvidence
    func reminderWork(limit: Int) throws -> [MiraTask]
    /// Scheduler-only existence check, independent of the bounded work page.
    func reminderTaskExists(_ id: MiraTaskID) throws -> Bool
    func setReminderDelivery(_ id: MiraTaskID, expectedRevision: Int, state: ReminderDeliveryState, error: MiraError?, at: Date) throws -> Bool
    func resumeReminder(_ id: MiraTaskID, workspaceID: WorkspaceID?, expectedRevision: Int, at: Date) throws
}
