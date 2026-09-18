import Foundation
import MiraCore
import Testing

@Suite("Task time and source grounding")
struct TaskTimeTests {
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
        #expect(TaskCommandInterpreter.canCommitDirectly(proposal, current: nil, arguments: arguments))
        let (wrong, wrongArguments) = try self.proposal(text: text, title: title, timeQuote: quote, time: "16:00", offset: 1)
        #expect(!TaskCommandInterpreter.canCommitDirectly(wrong, current: nil, arguments: wrongArguments))
    }

    @Test(arguments: [
        ("remind me tomorrow at 3:30pm to review notes", "tomorrow at 3:30pm"),
        ("remind me tomorrow at three thirty pm to review notes", "tomorrow at three thirty pm"),
        ("remind me tomorrow at 11pm to review notes", "tomorrow at 11pm")
    ])
    func partialHourOrDifferentHourCannotAutoCommit(_ input: (String, String)) throws {
        let (value, arguments) = try proposal(text: input.0, title: "review notes", timeQuote: input.1, time: "15:00", offset: 1)
        #expect(!TaskCommandInterpreter.canCommitDirectly(value, current: nil, arguments: arguments))
    }

    @Test func numericClockWithContradictoryPeriodCannotAutoCommit() throws {
        let text = "remind me tomorrow at 09:00 pm to review notes"
        let (value, arguments) = try proposal(text: text, title: "review notes", timeQuote: "tomorrow at 09:00 pm", time: "09:00", offset: 1)
        #expect(!TaskCommandInterpreter.canCommitDirectly(value, current: nil, arguments: arguments))
    }

    @Test func contradictoryMultipleTimesCannotAutoCommit() throws {
        let text = "remind me tomorrow at 09:00 or 10:00 to review notes"
        let (value, arguments) = try proposal(text: text, title: "review notes", timeQuote: "tomorrow at 09:00", time: "09:00", offset: 1)
        #expect(!TaskCommandInterpreter.canCommitDirectly(value, current: nil, arguments: arguments))
    }

    @Test func writtenPartialMinutesCannotAutoCommitEvenWhenNormalized() throws {
        let text = "remind me tomorrow at three thirty pm to review notes"
        let (value, arguments) = try proposal(text: text, title: "review notes", timeQuote: "tomorrow at three thirty pm", time: "15:30", offset: 1)
        #expect(!TaskCommandInterpreter.canCommitDirectly(value, current: nil, arguments: arguments))
    }

    @Test(arguments: ["03:00", "15:00"])
    func numericClockRespectsSourcePeriod(time: String) throws {
        let (value, arguments) = try proposal(text: "remind me tomorrow afternoon at 3:00 to review notes",
                                             title: "review notes", timeQuote: "tomorrow afternoon at 3:00", time: time, offset: 1)
        #expect(TaskCommandInterpreter.canCommitDirectly(value, current: nil, arguments: arguments) == (time == "15:00"))
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
        #expect(!TaskCommandInterpreter.canCommitDirectly(value, current: nil, arguments: arguments))
    }

    @Test func ungroundedDayCannotAutoCommit() throws {
        let (value, arguments) = try proposal(text: "remind me tomorrow at 09:00 to review notes", title: "review notes", timeQuote: "at 09:00", time: "09:00", offset: 2)
        #expect(!TaskCommandInterpreter.canCommitDirectly(value, current: nil, arguments: arguments))
    }

    @Test func hypotheticalAndRecurringCommandsCannotCommit() throws {
        let (value, arguments) = try proposal(text: "If I asked, remind me tomorrow at 09:00 to review notes", title: "review notes", timeQuote: "tomorrow at 09:00", time: "09:00", offset: 1)
        #expect(!TaskCommandInterpreter.canCommitDirectly(value, current: nil, arguments: arguments))
        #expect(throws: MiraError.self) {
            try proposal(text: "remind me every morning at 09:00 to review notes", title: "review notes", timeQuote: "morning at 09:00", time: "09:00", offset: 1)
        }
        #expect(throws: MiraError.self) {
            try proposal(text: "remind me each weekday at 09:00 to review notes", title: "review notes", timeQuote: "weekday at 09:00", time: "09:00", offset: 1)
        }
    }

    private func proposal(text: String, title: String, timeQuote: String, time: String, offset: Int) throws -> (TaskProposal, JSONValue) {
        let arguments: JSONValue = .object(["operation": .string("create"), "title": .string(title), "quote": .string(text), "remind": .bool(true), "time_quote": .string(timeQuote), "time": .string(time), "day_offset": .number(Double(offset))])
        let reference = TaskEvidence(source: syntheticEvidenceReference(), quote: text,
                                     sentAt: Date(timeIntervalSince1970: 1_788_761_400), timeZoneID: "Asia/Shanghai")
        return (try TaskCommandInterpreter.proposal(arguments: arguments, reference: reference, workspaceID: nil, operationID: UUID(), at: reference.sentAt), arguments)
    }

    private func syntheticEvidenceReference() -> SessionEvidenceReference {
        let sessionID = ConversationID()
        let batchID = UUID()
        let body = SessionContent(id: UUID(), kind: .userText, bytes: Data("x".utf8))
        return .init(sessionID: sessionID, originalExecutionID: ExecutionID(), userMessageID: MessageID(),
                     admissionEventID: UUID(), admissionSequence: 1)
    }
}
