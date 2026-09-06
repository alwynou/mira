import Foundation

public enum MiraTaskTag: Sendable {}
public typealias MiraTaskID = EntityID<MiraTaskTag>

public enum MiraTaskStatus: String, Codable, Sendable, CaseIterable {
    case open, inProgress, completed, cancelled
    public var isTerminal: Bool { self == .completed || self == .cancelled }
}

public enum ReminderDeliveryState: String, Codable, Sendable, CaseIterable {
    case none, pending, scheduled, permissionRequired, failed, elapsed, paused, cancelled
}

public struct TaskDraft: Codable, Sendable, Equatable {
    public var title: String
    public var notes: String
    public var dueAt: Date?
    public var reminderAt: Date?
    public var timeZoneID: String
    public init(title: String, notes: String = "", dueAt: Date? = nil, reminderAt: Date? = nil, timeZoneID: String = TimeZone.current.identifier) {
        self.title = title; self.notes = notes; self.dueAt = dueAt
        self.reminderAt = reminderAt; self.timeZoneID = timeZoneID
    }
    public func validate() throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              title.utf8.count <= 512, notes.utf8.count <= 8_192,
              TimeZone(identifier: timeZoneID) != nil,
              [dueAt, reminderAt].compactMap({ $0 }).allSatisfy({ $0.timeIntervalSince1970.isFinite && abs($0.timeIntervalSince1970) < 253_402_300_799 }) else {
            throw MiraError(.invalidInput, "The task title, notes, or time is invalid.")
        }
    }
}

public struct TaskEvidence: Codable, Sendable, Equatable {
    public var messageID: MessageID
    public var conversationID: ConversationID
    public var quote: String
    public var sentAt: Date
    public var timeZoneID: String
    public init(messageID: MessageID, conversationID: ConversationID, quote: String, sentAt: Date, timeZoneID: String) {
        self.messageID = messageID; self.conversationID = conversationID; self.quote = quote
        self.sentAt = sentAt; self.timeZoneID = timeZoneID
    }
}

public struct MiraTask: Identifiable, Codable, Sendable, Equatable {
    public var id: MiraTaskID
    public var workspaceID: WorkspaceID?
    public var draft: TaskDraft
    public var status: MiraTaskStatus
    public var revision: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var completedAt: Date?
    public var evidence: TaskEvidence?
    public var deliveryState: ReminderDeliveryState
    public var deliveryRevision: Int?
    public var deliveryError: MiraError?
    public init(id: MiraTaskID = .init(), workspaceID: WorkspaceID?, draft: TaskDraft, status: MiraTaskStatus = .open, revision: Int = 1, createdAt: Date, updatedAt: Date, evidence: TaskEvidence? = nil) {
        self.id = id; self.workspaceID = workspaceID; self.draft = draft; self.status = status
        self.revision = revision; self.createdAt = createdAt; self.updatedAt = updatedAt; self.evidence = evidence
        completedAt = status == .completed ? updatedAt : nil
        deliveryState = draft.reminderAt == nil ? .none : (status.isTerminal ? .cancelled : .pending)
        deliveryRevision = nil; deliveryError = nil
    }
}

public struct TaskRevision: Codable, Sendable, Identifiable {
    public var id: UUID
    public var task: MiraTask
    public var operation: String
    public var actor: String
    public var changedAt: Date
    public init(id: UUID = UUID(), task: MiraTask, operation: String, actor: String, changedAt: Date) {
        self.id = id; self.task = task; self.operation = operation; self.actor = actor; self.changedAt = changedAt
    }
}

public enum TaskProposalState: String, Codable, Sendable { case pending, accepted, rejected }
public enum TaskOperation: String, Codable, Sendable, CaseIterable { case create, update, complete, cancel }

/// A frozen interpretation, independent of memory candidates and foreground execution lifetime.
public struct TaskProposal: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var workspaceID: WorkspaceID?
    public var operation: TaskOperation
    public var taskID: MiraTaskID?
    public var expectedRevision: Int?
    public var draft: TaskDraft
    public var evidence: TaskEvidence
    public var state: TaskProposalState
    public var requiresTimeClarification: Bool
    public var createdAt: Date
    public init(id: UUID, workspaceID: WorkspaceID?, operation: TaskOperation, taskID: MiraTaskID?, expectedRevision: Int?, draft: TaskDraft, evidence: TaskEvidence, requiresTimeClarification: Bool, createdAt: Date) {
        self.id = id; self.workspaceID = workspaceID; self.operation = operation; self.taskID = taskID
        self.expectedRevision = expectedRevision; self.draft = draft; self.evidence = evidence
        self.requiresTimeClarification = requiresTimeClarification; self.createdAt = createdAt; state = .pending
    }
}

public struct TaskWriteReceipt: Sendable, Codable {
    public var task: MiraTask?
    public var proposal: TaskProposal?
    public init(task: MiraTask? = nil, proposal: TaskProposal? = nil) { self.task = task; self.proposal = proposal }
}

/// Resolves a wall-clock minute against the source date, rejecting DST gaps and overlaps.
public enum TaskTimeResolver {
    public static func resolve(date: String?, dayOffset: Int?, time: String, reference: Date, timeZoneID: String) throws -> Date {
        guard let zone = TimeZone(identifier: timeZoneID), (date == nil) != (dayOffset == nil) else { throw invalid }
        let clock = time.split(separator: ":", omittingEmptySubsequences: false)
        guard clock.count == 2, clock.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isNumber) }),
              let hour = Int(clock[0]), let minute = Int(clock[1]), (0...23).contains(hour), (0...59).contains(minute) else { throw invalid }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let target: DateComponents
        if let date {
            let parts = date.split(separator: "-", omittingEmptySubsequences: false)
            guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
                  let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]), (1970...9998).contains(year) else { throw invalid }
            target = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: 0)
        } else {
            guard let dayOffset, (0...3660).contains(dayOffset), let day = calendar.date(byAdding: .day, value: dayOffset, to: reference) else { throw invalid }
            let fields = calendar.dateComponents([.year, .month, .day], from: day)
            target = DateComponents(year: fields.year, month: fields.month, day: fields.day, hour: hour, minute: minute, second: 0)
        }
        guard let approximate = calendar.date(from: target) else { throw invalid }
        let start = calendar.startOfDay(for: approximate).addingTimeInterval(-1)
        guard let first = calendar.nextDate(after: start, matching: target, matchingPolicy: .strict, repeatedTimePolicy: .first),
              let last = calendar.nextDate(after: start, matching: target, matchingPolicy: .strict, repeatedTimePolicy: .last),
              first == last, calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: first) == target else { throw invalid }
        return first
    }
    private static var invalid: MiraError { .init(.invalidInput, "The reminder time is missing, invalid, or ambiguous. Choose an exact date and time.") }
}
