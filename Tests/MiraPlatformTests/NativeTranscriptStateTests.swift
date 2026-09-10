import Foundation
import MiraCore
import Testing

@Suite("Native transcript state")
struct NativeTranscriptStateTests {
    @Test func unchangedRowsAreNotReportedForUpdate() {
        var state = NativeTranscriptState()
        let first = item(id: "first", text: "Earlier")
        let second = item(id: "second", text: "Latest")

        _ = state.apply([first, second])
        let change = state.apply([first, second])

        #expect(!change.structureChanged)
        #expect(change.updated.isEmpty)
        #expect(change.removed.isEmpty)
    }

    @Test func draftToTerminalKeepsRowIdentityAndAdvancesRevision() throws {
        var state = NativeTranscriptState()
        let draft = item(id: "execution", text: "partial", status: nil, isStreaming: true)
        let draftChange = state.apply([draft])
        let draftToken = try #require(draftChange.updated.first)

        let terminal = item(id: "execution", text: "complete", status: .committed, isStreaming: false)
        let terminalChange = state.apply([terminal])
        let terminalToken = try #require(terminalChange.updated.first)

        #expect(terminalToken.id == draftToken.id)
        #expect(terminalToken.revision > draftToken.revision)
        #expect(state.tokens == [terminalToken])
    }

    @Test func deletionAndPrivacyPurgeClearThinkingExpansion() {
        var state = NativeTranscriptState()
        let visible = item(id: "visible", text: "Answer")
        let deleted = item(id: "deleted", text: "Removed answer")

        _ = state.apply([visible, deleted])
        state.toggleThinking("visible")
        state.toggleThinking("deleted")
        #expect(state.expandedThinking == ["visible", "deleted"])

        let purged = item(id: "visible", text: "Private answer", bodyPurgedAt: true)
        let purgeChange = state.apply([purged, deleted])
        #expect(purgeChange.removed.isEmpty)
        #expect(purgeChange.updated.map(\.id) == ["visible"])
        #expect(!state.expandedThinking.contains("visible"))
        #expect(state.expandedThinking == ["deleted"])

        let deletion = state.apply([purged])
        #expect(deletion.removed == ["deleted"])
        #expect(state.expandedThinking.isEmpty)

        state.toggleThinking("visible")
        #expect(state.expandedThinking.isEmpty)
    }

    @Test func deletionAndReinsertDoNotReuseStaleRevision() throws {
        var state = NativeTranscriptState()
        let original = item(id: "message", text: "Original")
        let originalChange = state.apply([original])
        let originalToken = try #require(originalChange.updated.first)

        let deletion = state.apply([])
        #expect(deletion.removed == ["message"])

        let replacementChange = state.apply([item(id: "message", text: "Replacement")])
        let replacementToken = try #require(replacementChange.updated.first)

        #expect(replacementToken.id == originalToken.id)
        #expect(replacementToken.revision > originalToken.revision)
        #expect(replacementChange.updated == [replacementToken])
    }

    @Test func reorderingKeepsTokensStableButReportsStructureChange() {
        var state = NativeTranscriptState()
        let first = item(id: "first", text: "First")
        let second = item(id: "second", text: "Second")
        let third = item(id: "third", text: "Third")

        _ = state.apply([first, second, third])
        let before = state.tokens
        let change = state.apply([third, first, second])

        #expect(change.structureChanged)
        #expect(change.updated.isEmpty)
        #expect(change.removed.isEmpty)
        #expect(state.tokens == [before[2], before[0], before[1]])
    }

    private func item(
        id: String,
        text: String,
        status: MessageStatus? = .committed,
        isStreaming: Bool = false,
        bodyPurgedAt: Bool = false
    ) -> TranscriptItem {
        TranscriptItem(
            id: id,
            role: .assistant,
            text: text,
            status: status,
            isStreaming: isStreaming,
            bodyPurgedAt: bodyPurgedAt ? Date(timeIntervalSince1970: 1) : nil
        )
    }
}
