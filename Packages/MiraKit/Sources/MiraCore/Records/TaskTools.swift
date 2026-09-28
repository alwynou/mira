import Foundation

public enum TaskTools {
    public static var mutationDefinition: ToolDefinition {
        func string(_ maximum: Int) -> JSONValue { .object(["type": .string("string"), "maxLength": .number(Double(maximum))]) }
        return .init(name: "task.change", description: "Create or change a local task and optional one-time reminder requested by the user. Interpret the request using the visible conversation, including short follow-up confirmations and corrections; do not require the user to repeat the whole task. Normalize the title, notes and time from that context. The host attaches the actual invoking user message as source evidence automatically. Use task.list to identify an existing target and its current revision; never guess IDs. For a reminder provide remind=true, local time HH:mm and either day_offset (today=0, tomorrow=1) or date YYYY-MM-DD. task.list returns authoritative reference_time and time_zone from the original invoking message, even for an empty list; use that clock instead of Bash. A clock without a date defaults to that local day. Never roll an elapsed time to tomorrow without the user's intent. If the conversation leaves intent, target or time ambiguous, ask a concise clarification instead of guessing or creating repeated proposals. Do not turn quoted examples, negated requests or hypothetical statements into actions. Recurring and conditional reminders are unsupported; explain that limit instead of creating a one-time substitute. Missing, invalid or elapsed reminder times produce an actionable review proposal. Edits supply complete desired title/notes/date; complete/cancel preserve existing details. A saved record is not proof of notification delivery: only delivery_state=scheduled confirms system scheduling. Explain any returned review_reason and next step accurately.", inputSchema: .object([
            "type": .string("object"), "additionalProperties": .bool(false),
            "properties": .object([
                "operation": .object(["type": .string("string"), "enum": .array(TaskOperation.allCases.map { .string($0.rawValue) })]),
                "title": string(512), "notes": string(8_192),
                "task_id": string(36), "expected_revision": .object(["type": .string("integer"), "minimum": .number(1), "maximum": .number(1_000_000)]),
                "remind": .object(["type": .string("boolean")]), "time": string(5), "date": string(10),
                "day_offset": .object(["type": .string("integer"), "minimum": .number(0), "maximum": .number(3660)])
            ]), "required": .array(["operation", "title", "remind"].map(JSONValue.string))
        ]))
    }

    public static var summarySchema: JSONValue {
        object([
            "id": string(36), "revision": .object(["type": .string("integer"), "minimum": .number(1), "maximum": .number(1_000_000)]),
            "title": string(512), "notes": string(512), "status": string(32),
            "due_at": string(64), "reminder_at": string(64), "time_zone": string(128), "delivery_state": string(32)
        ], required: ["id", "revision", "title", "notes", "status", "time_zone", "delivery_state"])
    }

    public static var mutationResultSchema: JSONValue {
        object(["record_saved": .object(["type": .string("boolean")]), "task": summarySchema,
                "proposal_id": string(36), "requires_review": .object(["type": .string("boolean")]),
                "requires_time_clarification": .object(["type": .string("boolean")]),
                "review_reason": .object(["type": .string("string"), "enum": .array(TaskReviewReason.allCases.map { .string($0.rawValue) })]), "message": string(512)],
               required: ["record_saved"])
    }

    static var listResultSchema: JSONValue {
        object(["reference_time": string(64), "time_zone": string(128),
                "tasks": .object(["type": .string("array"), "items": summarySchema, "maxItems": .number(50)]),
                "truncated": .object(["type": .string("boolean")])],
               required: ["reference_time", "time_zone", "tasks", "truncated"])
    }

    public static func summary(_ task: MiraTask) throws -> JSONValue {
        try task.draft.validate()
        var fields: [String: JSONValue] = [
            "id": .string(task.id.rawValue.uuidString.lowercased()), "revision": .number(Double(task.revision)),
            "title": .string(task.draft.title), "notes": .string(String(task.draft.notes.unicodeScalars.prefix(512))),
            "status": .string(task.status.rawValue), "time_zone": .string(task.draft.timeZoneID),
            "delivery_state": .string(task.deliveryState.rawValue)
        ]
        if let date = task.draft.dueAt { fields["due_at"] = .string(date.ISO8601Format()) }
        if let date = task.draft.reminderAt { fields["reminder_at"] = .string(date.ISO8601Format()) }
        return .object(fields)
    }

    private static func string(_ maximum: Int) -> JSONValue {
        .object(["type": .string("string"), "maxLength": .number(Double(maximum))])
    }
    private static func object(_ properties: [String: JSONValue], required: [String]) -> JSONValue {
        .object(["type": .string("object"), "properties": .object(properties),
                 "required": .array(required.map(JSONValue.string)), "additionalProperties": .bool(false)])
    }

}
