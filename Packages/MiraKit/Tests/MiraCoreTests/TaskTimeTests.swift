import Foundation
import MiraCore
import Testing

@Suite("Task time and source grounding")
struct TaskTimeTests {
    @Test(arguments: [
        ("提醒我下午6点取快递", "取快递", "下午6点"), // i18n-fixture: Synthetic date-omitted Chinese reminder; no personal conversation content.
        ("下午6点提醒我取快递", "取快递", "下午6点"), // i18n-fixture: Chinese time-first word order.
        ("remind me at 6pm to review notes", "review notes", "6pm"),
        ("please remind me at 18:00 to review notes", "review notes", "18:00")
    ])
    func dateOmittedFutureTimeUsesOriginalLocalDay(_ input: (String, String, String)) throws {
        let sentAt = try #require(ISO8601DateFormatter().date(from: "2026-09-28T07:00:00Z"))
        let (value, arguments) = try proposal(text: input.0, title: input.1, timeQuote: input.2,
                                              time: "18:00", offset: 0, sentAt: sentAt)
        #expect(value.draft.reminderAt?.ISO8601Format() == "2026-09-28T10:00:00Z")
        #expect(TaskCommandInterpreter.reviewReason(value, current: nil, arguments: arguments, at: sentAt) == nil)
        let tomorrow = sentAt.addingTimeInterval(86_400)
        #expect(TaskCommandInterpreter.reviewReason(value, current: nil, arguments: arguments, at: tomorrow) == .timeElapsed)
    }

    @Test func omittedDayArgumentUsesSameLocalDayWithoutAcceptingInventedTomorrow() throws {
        let sentAt = try #require(ISO8601DateFormatter().date(from: "2026-09-28T07:00:00Z"))
        let (original, arguments) = try proposal(text: "remind me at 18:00 to review notes", title: "review notes",
                                                timeQuote: "18:00", time: "18:00", offset: 0, sentAt: sentAt)
        guard case .object(var fields) = arguments else { return }
        fields.removeValue(forKey: "day_offset")
        let implicit = try TaskCommandInterpreter.proposal(arguments: .object(fields), reference: original.evidence,
            workspaceID: nil, operationID: UUID(), at: sentAt)
        #expect(implicit.draft == original.draft)
        #expect(TaskCommandInterpreter.reviewReason(implicit, current: nil, arguments: .object(fields), at: sentAt) == nil)
        fields["day_offset"] = .number(1)
        let invented = try TaskCommandInterpreter.proposal(arguments: .object(fields), reference: original.evidence,
            workspaceID: nil, operationID: UUID(), at: sentAt)
        #expect(TaskCommandInterpreter.reviewReason(invented, current: nil, arguments: .object(fields), at: sentAt) == .timeNotGrounded)
    }

    @Test(arguments: ["2026-09-28T10:00:00Z", "2026-09-28T11:00:00Z"])
    func elapsedDateOmittedTimeDoesNotRollToTomorrow(_ timestamp: String) throws {
        let sentAt = try #require(ISO8601DateFormatter().date(from: timestamp))
        let (value, arguments) = try proposal(text: "remind me at 18:00 to review notes", title: "review notes",
                                              timeQuote: "18:00", time: "18:00", offset: 0, sentAt: sentAt)
        #expect(value.draft.reminderAt?.ISO8601Format() == "2026-09-28T10:00:00Z")
        #expect(TaskCommandInterpreter.reviewReason(value, current: nil, arguments: arguments, at: sentAt) == .timeElapsed)
    }

    @Test(arguments: [
        "remind me next Monday at 18:00 to review notes",
        "remind me on September 30 at 18:00 to review notes",
        "remind me after the appointment at 18:00 to review notes",
        "remind me tomorrow at 18:00 to review notes",
        "下周一下午6点提醒我整理资料" // i18n-fixture: An explicit unsupported weekday must not be treated as an omitted day.
    ])
    func unrecognizedOrContradictoryDateIsNotTreatedAsOmitted(_ text: String) throws {
        let chinese = text.hasPrefix("下周") // i18n-fixture: Selects the authored Chinese fixture.
        let sentAt = try #require(ISO8601DateFormatter().date(from: "2026-09-28T07:00:00Z"))
        let (value, arguments) = try proposal(text: text, title: chinese ? "整理资料" : "review notes", // i18n-fixture: Synthetic source title.
            timeQuote: chinese ? "下午6点" : "18:00", time: "18:00", offset: 0, sentAt: sentAt) // i18n-fixture: Literal Chinese clock phrase.
        #expect(TaskCommandInterpreter.reviewReason(value, current: nil, arguments: arguments, at: sentAt) == .timeNotGrounded)
    }

    @Test func implicitDateUsesEvidenceTimeZoneAndRejectsDSTOverlap() throws {
        let sentAt = try #require(ISO8601DateFormatter().date(from: "2026-09-29T02:00:00Z"))
        let (value, arguments) = try proposal(text: "remind me at 23:00 to review notes", title: "review notes",
            timeQuote: "23:00", time: "23:00", offset: 0, sentAt: sentAt, timeZone: "America/Los_Angeles")
        #expect(value.draft.reminderAt?.ISO8601Format() == "2026-09-29T06:00:00Z")
        #expect(TaskCommandInterpreter.reviewReason(value, current: nil, arguments: arguments, at: sentAt) == nil)
        let fall = try #require(ISO8601DateFormatter().date(from: "2026-11-01T04:30:00Z"))
        let (ambiguous, args) = try proposal(text: "remind me at 01:30 to review notes", title: "review notes",
            timeQuote: "01:30", time: "01:30", offset: 0, sentAt: fall, timeZone: "America/New_York")
        #expect(ambiguous.requiresTimeClarification)
        #expect(TaskCommandInterpreter.reviewReason(ambiguous, current: nil, arguments: args, at: fall) == .timeUnclear)
    }

    @Test func relativeDayUsesOriginalDateAndZoneAcrossConfirmationDelay() throws {
        let sourceDate = try #require(ISO8601DateFormatter().date(from: "2026-09-07T15:30:00Z"))
        let value = try TaskTimeResolver.resolve(date: nil, dayOffset: 1, time: "09:00", reference: sourceDate, timeZoneID: "Asia/Shanghai")
        #expect(value.ISO8601Format() == "2026-09-08T01:00:00Z")
        // The source timestamp is an input, never a confirmation-time clock read.
        let replay = try TaskTimeResolver.resolve(date: nil, dayOffset: 1, time: "09:00", reference: sourceDate, timeZoneID: "Asia/Shanghai")
        #expect(replay == value)
    }

    @Test(arguments: [("2026-03-08", "02:30"), ("2026-11-01", "01:30"), ("2026-02-30", "09:00"), ("2026-13-01", "09:00"), ("2026-10-01", "25:00")])
    func invalidOrAmbiguousWallTimesRequireReview(_ input: (String, String)) {
        #expect(throws: MiraError.self) {
            try TaskTimeResolver.resolve(date: input.0, dayOffset: nil, time: input.1, reference: .now, timeZoneID: "America/New_York")
        }
    }

    @Test func directChineseAfternoonCommandGroundsExactHour() throws {
        let text = "明天下午三点提醒我交材料" // i18n-fixture: ordinary Chinese reminder command with a written hour.
        let quote = "明天下午三点" // i18n-fixture: exact source time phrase.
        let title = "交材料" // i18n-fixture: original task content.
        let (proposal, arguments) = try proposal(text: text, title: title, timeQuote: quote, time: "15:00", offset: 1)
        #expect(TaskCommandInterpreter.reviewReason(proposal, current: nil, arguments: arguments, at: proposal.evidence.sentAt) == nil)
        let (wrong, wrongArguments) = try self.proposal(text: text, title: title, timeQuote: quote, time: "16:00", offset: 1)
        #expect(TaskCommandInterpreter.reviewReason(wrong, current: nil, arguments: wrongArguments, at: wrong.evidence.sentAt) != nil)
    }

    @Test(arguments: [
        ("remind me tomorrow at 3:30pm to review notes", "tomorrow at 3:30pm"),
        ("remind me tomorrow at three thirty pm to review notes", "tomorrow at three thirty pm"),
        ("remind me tomorrow at 11pm to review notes", "tomorrow at 11pm")
    ])
    func partialHourOrDifferentHourCannotAutoCommit(_ input: (String, String)) throws {
        let (value, arguments) = try proposal(text: input.0, title: "review notes", timeQuote: input.1, time: "15:00", offset: 1)
        #expect(TaskCommandInterpreter.reviewReason(value, current: nil, arguments: arguments, at: value.evidence.sentAt) != nil)
    }

    @Test func numericClockWithContradictoryPeriodCannotAutoCommit() throws {
        let text = "remind me tomorrow at 09:00 pm to review notes"
        let (value, arguments) = try proposal(text: text, title: "review notes", timeQuote: "tomorrow at 09:00 pm", time: "09:00", offset: 1)
        #expect(TaskCommandInterpreter.reviewReason(value, current: nil, arguments: arguments, at: value.evidence.sentAt) != nil)
    }

    @Test func contradictoryMultipleTimesCannotAutoCommit() throws {
        let text = "remind me tomorrow at 09:00 or 10:00 to review notes"
        let (value, arguments) = try proposal(text: text, title: "review notes", timeQuote: "tomorrow at 09:00", time: "09:00", offset: 1)
        #expect(TaskCommandInterpreter.reviewReason(value, current: nil, arguments: arguments, at: value.evidence.sentAt) != nil)
    }

    @Test func writtenPartialMinutesCannotAutoCommitEvenWhenNormalized() throws {
        let text = "remind me tomorrow at three thirty pm to review notes"
        let (value, arguments) = try proposal(text: text, title: "review notes", timeQuote: "tomorrow at three thirty pm", time: "15:30", offset: 1)
        #expect(TaskCommandInterpreter.reviewReason(value, current: nil, arguments: arguments, at: value.evidence.sentAt) != nil)
    }

    @Test(arguments: ["03:00", "15:00"])
    func numericClockRespectsSourcePeriod(time: String) throws {
        let (value, arguments) = try proposal(text: "remind me tomorrow afternoon at 3:00 to review notes",
                                             title: "review notes", timeQuote: "tomorrow afternoon at 3:00", time: time, offset: 1)
        #expect((TaskCommandInterpreter.reviewReason(value, current: nil, arguments: arguments, at: value.evidence.sentAt) == nil) == (time == "15:00"))
    }

    @Test func contradictoryMultipleDatesCannotAutoCommit() throws {
        let text = "remind me on 2026-09-08 or 2026-09-09 at 09:00 to review notes"
        let arguments: JSONValue = .object([
            "operation": .string("create"), "title": .string("review notes"), "quote": .string(text),
            "remind": .bool(true), "time_quote": .string("2026-09-08 at 09:00"),
            "time": .string("09:00"), "date": .string("2026-09-08")
        ])
        let reference = TaskEvidence(source: syntheticEvidenceReference(), quote: text,
                                     sentAt: Date(timeIntervalSince1970: 1_788_761_400), timeZoneID: "Asia/Shanghai")
        let value = try TaskCommandInterpreter.proposal(arguments: arguments, reference: reference, workspaceID: nil, operationID: UUID(), at: reference.sentAt)
        #expect(TaskCommandInterpreter.reviewReason(value, current: nil, arguments: arguments, at: value.evidence.sentAt) != nil)
    }

    @Test func ungroundedDayCannotAutoCommit() throws {
        let (value, arguments) = try proposal(text: "remind me tomorrow at 09:00 to review notes", title: "review notes", timeQuote: "at 09:00", time: "09:00", offset: 2)
        #expect(TaskCommandInterpreter.reviewReason(value, current: nil, arguments: arguments, at: value.evidence.sentAt) != nil)
    }

    @Test func hypotheticalAndRecurringCommandsCannotCommit() throws {
        let (value, arguments) = try proposal(text: "If I asked, remind me tomorrow at 09:00 to review notes", title: "review notes", timeQuote: "tomorrow at 09:00", time: "09:00", offset: 1)
        #expect(TaskCommandInterpreter.reviewReason(value, current: nil, arguments: arguments, at: value.evidence.sentAt) != nil)
        #expect(throws: MiraError.self) {
            try proposal(text: "remind me every morning at 09:00 to review notes", title: "review notes", timeQuote: "morning at 09:00", time: "09:00", offset: 1)
        }
        #expect(throws: MiraError.self) {
            try proposal(text: "remind me each weekday at 09:00 to review notes", title: "review notes", timeQuote: "weekday at 09:00", time: "09:00", offset: 1)
        }
    }

    private func proposal(text: String, title: String, timeQuote: String, time: String, offset: Int, sentAt: Date = Date(timeIntervalSince1970: 1_788_761_400), timeZone: String = "Asia/Shanghai") throws -> (TaskProposal, JSONValue) {
        let arguments: JSONValue = .object(["operation": .string("create"), "title": .string(title), "quote": .string(text), "remind": .bool(true), "time_quote": .string(timeQuote), "time": .string(time), "day_offset": .number(Double(offset))])
        let reference = TaskEvidence(source: syntheticEvidenceReference(), quote: text,
                                     sentAt: sentAt, timeZoneID: timeZone)
        return (try TaskCommandInterpreter.proposal(arguments: arguments, reference: reference, workspaceID: nil, operationID: UUID(), at: reference.sentAt), arguments)
    }

    private func syntheticEvidenceReference() -> SessionEvidenceReference {
        let sessionID = ConversationID()
        return .init(sessionID: sessionID, originalExecutionID: ExecutionID(), userMessageID: MessageID(),
                     admissionEventID: UUID(), admissionSequence: 1)
    }
}
