import Foundation
import MiraCore
import Testing

struct TranscriptPresentationTests {
    private let call = CanonicalToolCall(id: "call-1", name: "knowledge.search", arguments: "private input")

    @Test func finalAnswerAppearsOnlyOutsideTheProcess() throws {
        let observation = try ToolResult(status: .succeeded, text: "Returned excerpt").observation()
        let trace = [
            CanonicalMessage(role: .assistant, text: "Searching the source.", toolCalls: [call]),
            CanonicalMessage(role: .tool, text: observation, toolCallID: call.id),
            CanonicalMessage(role: .assistant, text: "The final answer.")
        ]
        let projection = TranscriptPresentation(text: "Searching the source.\n\nThe final answer.", trace: trace)
        #expect(projection.answer == "The final answer.")
        #expect(projection.rounds.map(\.intermediateText) == ["Searching the source.", ""])
        #expect(projection.rounds[0].tools[0].output == "Returned excerpt")
        #expect(projection.rounds[0].tools[0].name == "knowledge.search")
        #expect(trace[0].toolCalls?[0].arguments == "private input")
    }

    @Test func draftAheadOfTraceKeepsOnlyTheLiveSuffix() throws {
        let trace = [
            CanonicalMessage(role: .assistant, text: "Searching.", toolCalls: [call]),
            CanonicalMessage(role: .tool, text: try ToolResult(status: .succeeded, text: "Found").observation(), toolCallID: call.id)
        ]
        #expect(TranscriptPresentation(text: "Searching.\n\nA growing answer", trace: trace).answer == "A growing answer")
        #expect(TranscriptPresentation(text: "Searching.", trace: trace).answer.isEmpty)
    }

    @Test func interruptedToolCallNeverFabricatesAResultOrFinalAnswer() {
        let projection = TranscriptPresentation(text: "Checking.", trace: [
            .init(role: .assistant, text: "Checking.", toolCalls: [call])
        ])
        #expect(projection.answer.isEmpty)
        #expect(projection.pendingTools.count == 1)
        #expect(projection.rounds[0].tools[0].output == nil)
    }

    @Test func thinkingOnlyAndPurgedToolTracePreserveVisibleText() {
        let reasoning = ReasoningContent(format: .openAIContent, text: "Visible reasoning", isComplete: false)
        let thinking = TranscriptPresentation(text: "", trace: [.init(role: .assistant, text: "", reasoning: reasoning)])
        #expect(thinking.isThinking)
        #expect(thinking.rounds[0].thinking == "Visible reasoning")
        #expect(thinking.answer.isEmpty)

        let purged = TranscriptPresentation(text: "Earlier reply.\n\nRetained final reply.", trace: [
            .init(role: .assistant, text: "Earlier reply."),
            .init(role: .assistant, text: "Retained final reply.")
        ])
        #expect(purged.answer == "Retained final reply.")
        #expect(purged.rounds[0].intermediateText == "Earlier reply.")
        #expect(purged.rounds.allSatisfy { $0.tools.isEmpty })
    }

    @Test func plainRepliesAndTraceAheadOfDraftDoNotDuplicateContent() {
        #expect(TranscriptPresentation(text: "Plain reply", trace: []).answer == "Plain reply")
        let trace = [CanonicalMessage(role: .assistant, text: "Completed intermediate.", toolCalls: [call])]
        #expect(TranscriptPresentation(text: "Completed inter", trace: trace).answer.isEmpty)
    }
}
