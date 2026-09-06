import Foundation
import Testing
import MiraCore

@Suite("Conversation stream buffer")
@MainActor
struct ConversationStreamBufferTests {
    @Test func burstPublishesLatestCumulativeUnicodeSnapshot() async throws {
        let buffer = ConversationStreamBuffer(interval: .milliseconds(20))
        let id = ExecutionID()
        // Unicode fixture verifies that coalescing preserves user/model output verbatim.
        buffer.receiveDraft("你", for: id) // i18n-fixture: Preserve cumulative Unicode model output verbatim.
        buffer.receiveDraft("你好，世界 🌏", for: id) // i18n-fixture: Preserve cumulative Unicode model output verbatim.
        #expect(buffer.drafts[id] == nil)

        try await Task.sleep(for: .milliseconds(100))

        #expect(buffer.drafts[id] == "你好，世界 🌏") // i18n-fixture: Preserve cumulative Unicode model output verbatim.
        #expect(Array(try #require(buffer.drafts[id]).utf8) == Array("你好，世界 🌏".utf8)) // i18n-fixture: Preserve cumulative Unicode model output verbatim.
    }

    @Test func flushPublishesEmptyFinalSnapshotAndCancelsPendingBatch() async throws {
        let buffer = ConversationStreamBuffer(interval: .seconds(1))
        let id = ExecutionID()
        buffer.receiveDraft("partial", for: id)
        buffer.receiveDraft("", for: id)
        buffer.flush()
        #expect(buffer.drafts[id] == "")

        try await Task.sleep(for: .milliseconds(20))
        #expect(buffer.drafts[id] == "")
    }

    @Test func authoritativeReplaceClearsPendingContentsImmediately() async throws {
        let buffer = ConversationStreamBuffer(interval: .milliseconds(50))
        let id = ExecutionID()
        buffer.receiveDraft("stale", for: id)
        buffer.receiveThinking([.init(role: .assistant, text: "stale")], for: id)
        buffer.replace(drafts: [:], thinkingTraces: [:])
        #expect(buffer.drafts.isEmpty)
        #expect(buffer.thinkingTraces.isEmpty)

        try await Task.sleep(for: .milliseconds(120))
        #expect(buffer.drafts.isEmpty)
        #expect(buffer.thinkingTraces.isEmpty)
    }

    @Test func executionsRemainIsolatedAndThinkingOnlyCreatesEmptyDraft() async throws {
        let buffer = ConversationStreamBuffer(interval: .milliseconds(20))
        let first = ExecutionID(), second = ExecutionID()
        let trace: [CanonicalMessage] = [.init(role: .assistant, text: "", reasoning: .init(format: .openAIContent, text: "thinking"))]
        buffer.receiveThinking(trace, for: first)
        buffer.receiveDraft("second", for: second)
        buffer.flush()

        #expect(buffer.drafts[first] == "")
        #expect(buffer.thinkingTraces[first] == trace)
        #expect(buffer.drafts[second] == "second")
        #expect(buffer.thinkingTraces[second] == nil)
    }

    @Test func thinkingDoesNotReplaceAnExistingDraft() {
        let buffer = ConversationStreamBuffer(interval: .seconds(1))
        let id = ExecutionID()
        buffer.receiveDraft("answer", for: id)
        buffer.flush()
        buffer.receiveThinking([.init(role: .assistant, text: "", reasoning: .init(format: .openAIContent, text: "more"))], for: id)
        buffer.flush()

        #expect(buffer.drafts[id] == "answer")
        #expect(buffer.thinkingTraces[id]?.first?.reasoning?.text == "more")
    }
}
