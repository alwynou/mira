import Foundation

/// Validates the model's structured command; conversational interpretation belongs to the model.
public enum TaskCommandInterpreter {
    public static func proposal(arguments: JSONValue, reference: TaskEvidence, workspaceID: WorkspaceID?, operationID: UUID, at: Date) throws -> TaskProposal {
        try reference.validate()
        guard let operation = arguments["operation"]?.stringValue.flatMap(TaskOperation.init(rawValue:)),
              let title = arguments["title"]?.stringValue, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw invalid }
        let taskID: MiraTaskID?
        let expectedRevision: Int?
        if operation == .create {
            guard arguments["task_id"] == nil, arguments["expected_revision"] == nil else { throw invalid }
            taskID = nil; expectedRevision = nil
        } else {
            guard let raw = arguments["task_id"]?.stringValue, let uuid = UUID(uuidString: raw),
                  case .number(let revision) = arguments["expected_revision"], revision > 0, revision.rounded() == revision, revision <= 1_000_000 else { throw invalid }
            taskID = .init(uuid); expectedRevision = Int(revision)
        }
        let wantsReminder = arguments["remind"] == .bool(true)
        let time = arguments["time"]?.stringValue
        let date = arguments["date"]?.stringValue
        let offset: Int?
        if let value = arguments["day_offset"] {
            guard case .number(let number) = value, number.isFinite, number.rounded() == number,
                  (0...3660).contains(number) else { throw invalid }
            offset = Int(number)
        } else {
            // An omitted date means the original message's local day, never the next occurrence.
            offset = date == nil && time != nil ? 0 : nil
        }
        var dueAt: Date?
        var unclear = false
        if wantsReminder || time != nil || date != nil || offset != nil {
            if let time, let resolved = try? TaskTimeResolver.resolve(
                date: date, dayOffset: offset, time: time, reference: reference.sentAt, timeZoneID: reference.timeZoneID
            ) {
                dueAt = resolved
            } else { unclear = true }
        }
        let draft = TaskDraft(title: title, notes: arguments["notes"]?.stringValue ?? "", dueAt: dueAt, reminderAt: wantsReminder ? dueAt : nil, timeZoneID: reference.timeZoneID)
        try draft.validate()
        return .init(id: operationID, workspaceID: workspaceID, operation: operation, taskID: taskID, expectedRevision: expectedRevision, draft: draft, evidence: reference, requiresTimeClarification: unclear && wantsReminder, createdAt: at)
    }

    public static func reviewReason(_ proposal: TaskProposal, arguments: JSONValue, at: Date) -> TaskReviewReason? {
        guard proposal.operation == .create || proposal.operation == .update else { return nil }
        let hasTime = arguments["time"] != nil || arguments["date"] != nil || arguments["day_offset"] != nil || arguments["remind"] == .bool(true)
        guard hasTime else { return nil }
        guard let dueAt = proposal.draft.dueAt, !proposal.requiresTimeClarification else { return .timeUnclear }
        if proposal.draft.reminderAt != nil, dueAt <= max(proposal.evidence.sentAt, at) { return .timeElapsed }
        return nil
    }

    private static var invalid: MiraError { .init(.invalidInput, "The task command has missing or invalid fields.") }
}
