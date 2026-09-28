import Foundation
import MiraCore
import Testing

@Suite("Structured task times")
struct TaskTimeTests {
    private let sentAt = Date(timeIntervalSince1970: 1_790_578_800) // 2026-09-28 15:00 in Shanghai.

    @Test(arguments: [
        "提醒我下午7点去取快递", // i18n-fixture: Natural Chinese instruction with a verb outside the normalized title.
        "帮我在下午七点半处理一下快递吧", // i18n-fixture: Conversational phrasing and partial hours belong to model interpretation.
        "Add a task called \"Parcel pickup\" for this evening",
        "Yes, today please"
    ])
    func modelNormalizesLanguageWithoutASecondSentenceParser(_ text: String) throws {
        let (value, arguments) = try proposal(text: text, title: "Parcel pickup", time: "19:30")
        #expect(value.draft.reminderAt?.ISO8601Format() == "2026-09-28T11:30:00Z")
        #expect(value.evidence.quote == text)
        #expect(TaskCommandInterpreter.reviewReason(value, arguments: arguments, at: sentAt) == nil)
    }

    @Test(arguments: [0, 1, 7, 30])
    func normalizedRelativeDateIsNotLimitedToLiteralDayWords(_ offset: Int) throws {
        let (value, arguments) = try proposal(text: "At the agreed time, please", time: "19:00", offset: offset)
        let expected = try TaskTimeResolver.resolve(date: nil, dayOffset: offset, time: "19:00", reference: sentAt, timeZoneID: "Asia/Shanghai")
        #expect(value.draft.reminderAt == expected)
        #expect(TaskCommandInterpreter.reviewReason(value, arguments: arguments, at: sentAt) == nil)
    }

    @Test func normalizedDateDoesNotHaveToBePrintedInUserMessage() throws {
        let (value, arguments) = try proposal(text: "Next Wednesday at half past six", time: "18:30", date: "2026-09-30")
        #expect(value.draft.reminderAt?.ISO8601Format() == "2026-09-30T10:30:00Z")
        #expect(TaskCommandInterpreter.reviewReason(value, arguments: arguments, at: sentAt) == nil)
    }

    @Test func retriesRetainOriginalLocalDateAndRejectElapsedReminders() throws {
        let (value, arguments) = try proposal(text: "At seven please", time: "19:00")
        #expect(value.draft.reminderAt?.ISO8601Format() == "2026-09-28T11:00:00Z")
        #expect(TaskCommandInterpreter.reviewReason(value, arguments: arguments, at: sentAt) == nil)
        #expect(TaskCommandInterpreter.reviewReason(value, arguments: arguments, at: sentAt.addingTimeInterval(86_400)) == .timeElapsed)
        let (past, pastArguments) = try proposal(text: "At nine please", time: "09:00")
        #expect(TaskCommandInterpreter.reviewReason(past, arguments: pastArguments, at: sentAt) == .timeElapsed)
    }

    @Test(arguments: [nil, "25:00", "18:60", "seven"])
    func missingOrInvalidClockRequiresReview(_ time: String?) throws {
        let (value, arguments) = try proposal(text: "Remind me later", time: time)
        #expect(value.draft.reminderAt == nil)
        #expect(value.requiresTimeClarification)
        #expect(TaskCommandInterpreter.reviewReason(value, arguments: arguments, at: sentAt) == .timeUnclear)
    }

    @Test func invalidOrConflictingDateRequiresReview() throws {
        for (date, offset) in [("2026-02-30", nil), ("2026-09-30", 1)] as [(String, Int?)] {
            let (value, arguments) = try proposal(text: "At the agreed date", time: "18:00", offset: offset, date: date)
            #expect(value.draft.reminderAt == nil)
            #expect(TaskCommandInterpreter.reviewReason(value, arguments: arguments, at: sentAt) == .timeUnclear)
        }
    }

    @Test func dateUsesEvidenceTimeZoneAndRejectsDSTOverlap() throws {
        let lateUTC = try #require(ISO8601DateFormatter().date(from: "2026-09-29T02:00:00Z"))
        let (value, arguments) = try proposal(text: "At eleven please", time: "23:00", reference: lateUTC, timeZone: "America/Los_Angeles")
        #expect(value.draft.reminderAt?.ISO8601Format() == "2026-09-29T06:00:00Z")
        #expect(TaskCommandInterpreter.reviewReason(value, arguments: arguments, at: lateUTC) == nil)
        let fall = try #require(ISO8601DateFormatter().date(from: "2026-11-01T04:30:00Z"))
        let (ambiguous, args) = try proposal(text: "At one thirty", time: "01:30", reference: fall, timeZone: "America/New_York")
        #expect(ambiguous.requiresTimeClarification)
        #expect(TaskCommandInterpreter.reviewReason(ambiguous, arguments: args, at: fall) == .timeUnclear)
    }

    @Test func relativeDayUsesOriginalDateAndZoneAcrossConfirmationDelay() throws {
        let sourceDate = try #require(ISO8601DateFormatter().date(from: "2026-09-07T15:30:00Z"))
        let value = try TaskTimeResolver.resolve(date: nil, dayOffset: 1, time: "09:00", reference: sourceDate, timeZoneID: "Asia/Shanghai")
        #expect(value.ISO8601Format() == "2026-09-08T01:00:00Z")
    }

    @Test func invalidDatesAndDSTGapsRequireClarification() throws {
        for date in ["2026-02-30", "2026-13-01", "2026-03-08"] {
            #expect(throws: MiraError.self) {
                try TaskTimeResolver.resolve(date: date, dayOffset: nil, time: "02:30", reference: sentAt, timeZoneID: "America/New_York")
            }
        }
    }

    private func proposal(text: String, title: String = "Review notes", time: String?, offset: Int? = nil,
                          date: String? = nil, reference: Date? = nil, timeZone: String = "Asia/Shanghai") throws -> (TaskProposal, JSONValue) {
        var fields: [String: JSONValue] = ["operation": .string("create"), "title": .string(title), "remind": .bool(true)]
        if let time { fields["time"] = .string(time) }
        if let offset { fields["day_offset"] = .number(Double(offset)) }
        if let date { fields["date"] = .string(date) }
        let arguments = JSONValue.object(fields)
        let evidence = TaskEvidence(source: syntheticEvidenceReference(), quote: text, sentAt: reference ?? sentAt, timeZoneID: timeZone)
        return (try TaskCommandInterpreter.proposal(arguments: arguments, reference: evidence, workspaceID: nil, operationID: UUID(), at: evidence.sentAt), arguments)
    }

    private func syntheticEvidenceReference() -> SessionEvidenceReference {
        .init(sessionID: .init(), originalExecutionID: .init(), userMessageID: .init(), admissionEventID: UUID(), admissionSequence: 1)
    }
}
