import Foundation

/// Model interpretation is a proposal. Only source-grounded commands skip UI review.
public enum TaskCommandInterpreter {
    private struct IntentPatterns: Decodable {
        var create: [String]; var update: [String]; var complete: [String]; var cancel: [String]
        var veto: [String]; var unsupported: [String]; var relativeDays: [[String]]; var periods: [String: [String]]
    }
    private static let patterns: IntentPatterns? = {
        guard let url = Bundle.module.url(forResource: "TaskIntentPatterns", withExtension: "json") else { return nil }
        return try? JSONDecoder().decode(IntentPatterns.self, from: Data(contentsOf: url))
    }()

    public static func proposal(arguments: JSONValue, reference: TaskEvidence, workspaceID: WorkspaceID?, operationID: UUID, at: Date) throws -> TaskProposal {
        guard let operation = arguments["operation"]?.stringValue.flatMap(TaskOperation.init(rawValue:)),
              let title = arguments["title"]?.stringValue, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              arguments["quote"]?.stringValue == reference.quote else { throw invalid }
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
        if let patterns, patterns.unsupported.contains(where: { matches($0, reference.quote.lowercased()) }) {
            throw MiraError(.unsupported, "Only one-time reminders with an exact time are supported. Recurring and conditional reminders require a different schedule.")
        }
        let wantsReminder = arguments["remind"] == .bool(true)
        let timeQuote = arguments["time_quote"]?.stringValue
        let time = arguments["time"]?.stringValue
        let date = arguments["date"]?.stringValue
        let offset: Int? = { if case .number(let value) = arguments["day_offset"], value.isFinite, value.rounded() == value, (0...3660).contains(value) { return Int(value) }; return nil }()
        var dueAt: Date?
        var unclear = false
        if wantsReminder || time != nil || date != nil || offset != nil {
            if let timeQuote, !timeQuote.isEmpty, reference.quote.contains(timeQuote), let time,
               let resolved = try? TaskTimeResolver.resolve(date: date, dayOffset: offset, time: time, reference: reference.sentAt, timeZoneID: reference.timeZoneID) {
                dueAt = resolved
            } else { unclear = true }
        }
        let draft = TaskDraft(title: title, notes: arguments["notes"]?.stringValue ?? "", dueAt: dueAt, reminderAt: wantsReminder ? dueAt : nil, timeZoneID: reference.timeZoneID)
        try draft.validate()
        return .init(id: operationID, workspaceID: workspaceID, operation: operation, taskID: taskID, expectedRevision: expectedRevision, draft: draft, evidence: reference, requiresTimeClarification: unclear && wantsReminder, createdAt: at)
    }

    public static func canCommitDirectly(_ proposal: TaskProposal, current: MiraTask?, arguments: JSONValue) -> Bool {
        guard let patterns else { return false }
        let text = proposal.evidence.quote.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard text.utf8.count <= 4_096, !patterns.veto.contains(where: { matches($0, text) }) else { return false }
        let rules: [String]
        switch proposal.operation {
        case .create: rules = patterns.create
        case .update: rules = patterns.update
        case .complete: rules = patterns.complete
        case .cancel: rules = patterns.cancel
        }
        guard rules.contains(where: { matches($0, text) }) else { return false }
        // An exact title anchors the concrete target; pronouns and paraphrases stay reviewable.
        guard text.contains((current?.draft.title ?? proposal.draft.title).lowercased()) else { return false }
        if proposal.operation == .create || proposal.operation == .update {
            guard text.contains(proposal.draft.title.lowercased()), proposal.draft.notes.isEmpty || text.contains(proposal.draft.notes.lowercased()) else { return false }
            if arguments["time"] != nil || arguments["date"] != nil || arguments["day_offset"] != nil || arguments["remind"] == .bool(true) {
                guard proposal.draft.dueAt != nil else { return false }
                guard let quote = arguments["time_quote"]?.stringValue, let clock = arguments["time"]?.stringValue,
                      sourceTimeMatches(timeQuote: quote.lowercased(), source: proposal.evidence.quote.lowercased(), time: clock, date: arguments["date"]?.stringValue, dayOffset: arguments["day_offset"], patterns: patterns) else { return false }
            }
        }
        return true
    }

    private static func sourceTimeMatches(timeQuote: String, source: String, time: String, date: String?, dayOffset: JSONValue?, patterns: IntentPatterns) -> Bool {
        let clock = time.split(separator: ":")
        guard clock.count == 2, let hour = Int(clock[0]), let minute = Int(clock[1]) else { return false }
        guard !timeQuote.isEmpty, source.contains(timeQuote) else { return false }
        if let date {
            guard source.contains(date), countMatches("(?<![0-9])\\d{4}-\\d{2}-\\d{2}(?![0-9])", in: source) == 1 else { return false }
            guard !hasRelativeDay(in: source, patterns: patterns) else { return false }
        }
        else {
            guard case .number(let offset) = dayOffset, (0...2).contains(offset), offset.rounded() == offset else { return false }
            let index = Int(offset)
            guard patterns.relativeDays.indices.contains(index), patterns.relativeDays[index].contains(where: { matches($0, source) }) else { return false }
            guard matchingRelativeDayCount(in: source, patterns: patterns) == 1 else { return false }
            guard countMatches("(?<![0-9])\\d{4}-\\d{2}-\\d{2}(?![0-9])", in: source) == 0 else { return false }
        }

        let numericClockPattern = "(?<![0-9])(?:[01]?[0-9]|2[0-3]):[0-5][0-9](?:\\s*(?:a\\.?\\s*m\\.?|p\\.?\\s*m\\.?))?(?![A-Za-z0-9])"
        let numericClocks = matchingStrings(numericClockPattern, in: source)
        let writtenHours = (1...12).filter { patterns.periods["hour\($0)"]?.contains(where: { matches($0, source) }) == true }
        guard numericClocks.count + writtenHours.count <= 1 else { return false }
        if let numericClock = numericClocks.first {
            let parts = numericClock.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let sourceHour = Int(parts[0]), parts[1].count >= 2,
                  let sourceMinute = Int(parts[1].prefix(2)) else { return false }
            let suffix = parts[1].dropFirst(2).lowercased()
            let normalizedSuffix = suffix.filter { $0 == "a" || $0 == "p" || $0 == "m" }
            let statedPeriods = ["am", "pm"].filter { patterns.periods[$0]?.contains(where: { matches($0, source) }) == true }
            guard statedPeriods.count <= 1 else { return false }
            let expectedHour: Int
            if normalizedSuffix.contains("pm") { expectedHour = sourceHour == 12 ? 12 : sourceHour + 12 }
            else if normalizedSuffix.contains("am") { expectedHour = sourceHour == 12 ? 0 : sourceHour }
            else if statedPeriods == ["pm"], sourceHour < 12 { expectedHour = sourceHour + 12 }
            else if statedPeriods == ["am"], sourceHour == 12 { expectedHour = 0 }
            else { expectedHour = sourceHour }
            if let period = statedPeriods.first {
                guard (expectedHour >= 12 ? "pm" : "am") == period else { return false }
            }
            return hour == expectedHour && minute == sourceMinute
        }

        guard !matches(patterns.periods["partialMinute"]?.joined(separator: "|") ?? "(?!)", source) else { return false }
        // Numeric or written hours are handled by resource patterns, not translated prompts.
        let period = hour >= 12 ? "pm" : "am"
        let matchingPeriods = ["am", "pm"].filter { patterns.periods[$0]?.contains(where: { matches($0, source) }) == true }
        guard matchingPeriods == [period] else { return false }
        let localHour = hour % 12 == 0 ? 12 : hour % 12
        let matchingHours = (1...12).filter { patterns.periods["hour\($0)"]?.contains(where: { matches($0, source) }) == true }
        guard minute == 0, matchingHours == [localHour] else { return false }
        return true
    }

    private static func hasRelativeDay(in text: String, patterns: IntentPatterns) -> Bool {
        patterns.relativeDays.contains { $0.contains(where: { matches($0, text) }) }
    }

    private static func matchingRelativeDayCount(in text: String, patterns: IntentPatterns) -> Int {
        patterns.relativeDays.filter { $0.contains(where: { matches($0, text) }) }.count
    }

    private static func matchingStrings(_ pattern: String, in text: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.matches(in: text, range: range).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }

    private static func countMatches(_ pattern: String, in text: String) -> Int {
        matchingStrings(pattern, in: text).count
    }

    private static func matches(_ pattern: String, _ text: String) -> Bool { text.range(of: pattern, options: .regularExpression) != nil }
    private static var invalid: MiraError { .init(.invalidInput, "The task proposal is incomplete or does not match the current user message.") }
}
