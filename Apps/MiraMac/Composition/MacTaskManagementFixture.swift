#if DEBUG
import Foundation
import MiraCore

/// Explicit, disposable data for native Tasks management QA. It is enabled only by
/// `--demo --verify-task-management` and never replaces existing demo records.
enum MacTaskManagementFixture {
    private static let workspaceID = WorkspaceID(UUID(uuidString: "0D8F40B7-1A68-4E0F-9A89-0E8FD8B2E301")!)
    private static let taskIDs = [
        MiraTaskID(UUID(uuidString: "0D8F40B7-1A68-4E0F-9A89-0E8FD8B2E311")!),
        MiraTaskID(UUID(uuidString: "0D8F40B7-1A68-4E0F-9A89-0E8FD8B2E312")!),
        MiraTaskID(UUID(uuidString: "0D8F40B7-1A68-4E0F-9A89-0E8FD8B2E313")!),
        MiraTaskID(UUID(uuidString: "0D8F40B7-1A68-4E0F-9A89-0E8FD8B2E314")!),
    ]

    static func seed(in group: MacLibraryWorkloads) async throws {
        let workspace = Workspace(id: workspaceID, name: "Tasks QA Workspace", background: "Synthetic offline task fixture")
        let workspaces = try await group.workspaces.workspaces()
        if workspaces.first(where: { $0.id == workspaceID }) == nil {
            try await group.workspaces.save(workspace, expectedRevision: nil)
        }
        let now = Date()
        let values: [(MiraTaskStatus, TaskDraft, WorkspaceID?)] = [
            (.open, .init(title: "Inbox: confirm task list filters", notes: "Synthetic open task", dueAt: now.addingTimeInterval(86_400)), nil),
            (.inProgress, .init(title: "Workspace: inspect reminder states", notes: "Synthetic in-progress task", reminderAt: now.addingTimeInterval(3_600)), workspaceID),
            (.completed, .init(title: "Workspace: verify completed history", notes: "Synthetic completed task"), workspaceID),
            (.cancelled, .init(title: "Inbox: cancelled fixture", notes: "Synthetic cancelled task", reminderAt: now.addingTimeInterval(7_200)), nil),
        ]
        for (index, value) in values.enumerated() {
            let id = taskIDs[index]
            if let current = try? await group.tasks.detail(id: id, workspaceID: value.2) {
                // Existing fixture rows may contain manual QA edits. Preserve them;
                // a reopen only fills rows that were never created.
                _ = current
                continue
            }
            let created = try await group.tasks.save(id: id, workspaceID: value.2, draft: value.1,
                                                     status: .open, expectedRevision: nil,
                                                     operationID: stableOperationID(index, suffix: 0))
            if value.0 != .open {
                _ = try await group.tasks.save(id: id, workspaceID: value.2, draft: value.1,
                                               status: value.0, expectedRevision: created.revision,
                                               operationID: stableOperationID(index, suffix: 1))
            }
        }
        // Demo notifications intentionally report denied permission. Reconciliation
        // therefore leaves the reminder-bearing active task in permissionRequired.
        try await group.reminders.reconcile()

        // Drive one normal task.change call so the pending proposal retains journal
        // evidence and can exercise fresh-evidence acceptance in the native screen.
        if try await group.tasks.proposals(workspaceID: nil).contains(where: { $0.draft.title == "Review local task fixture" }) { return }
        let route = try await group.modelSettings.candidate(routeID: MacDemoModule.routeID).freeze(configuration: .object([:]))
        let sessionID = ConversationID(UUID(uuidString: "0D8F40B7-1A68-4E0F-9A89-0E8FD8B2E321")!)
        let executionID = ExecutionID(UUID(uuidString: "0D8F40B7-1A68-4E0F-9A89-0E8FD8B2E322")!)
        let text = "Please add a task for the local task management fixture"
        let command = AgentSubmitCommand(id: UUID(uuidString: "0D8F40B7-1A68-4E0F-9A89-0E8FD8B2E323")!, sessionID: sessionID,
            executionID: executionID, input: .message(id: MessageID(UUID(uuidString: "0D8F40B7-1A68-4E0F-9A89-0E8FD8B2E324")!), text: text, timeZoneIdentifier: TimeZone.current.identifier),
            options: .init(instructions: "Use task.change to prepare the requested task.", route: route),
            opening: .init(title: "Tasks QA fixture", workspaceID: nil))
        let snapshot = try await group.application.sessionSnapshot(id: sessionID)
        guard snapshot.executions[executionID] == nil else { return }
        switch await group.application.submit(command) {
        case .committed:
            let result = await group.application.waitForExecution(id: executionID, sessionID: sessionID)
            if case .notCommitted(let error) = result { throw error }
            if case .indeterminate(_, let error) = result { throw error }
        case .notCommitted(let error): throw error
        case .indeterminate(_, let error): throw error
        }
    }

    private static func stableOperationID(_ index: Int, suffix: Int) -> UUID {
        UUID(uuidString: String(format: "0D8F40B7-1A68-4E0F-9A89-0E8FD8B2E3%02d", index * 2 + suffix + 31))!
    }

}
#endif
