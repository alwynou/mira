import Testing

@Suite("Conversation reading restoration")
@MainActor
struct ConversationReadingStateTests {
    @Test func readingHistoryWaitsForMarkdownLayoutToReachSavedOffset() {
        let state = ConversationReadingState()
        state.scrollState.revealHistory()
        state.recordOffset(900)
        state.leave()
        state.recordOffset(0) // Teardown geometry must not replace the saved reading offset.
        state.prepareForDisplay()
        state.recordOffset(0)
        #expect(state.takeRestorationOffset(maximumOffset: 400) == nil)
        #expect(state.visibleOffset == 900)
        #expect(state.pendingRestoreOffset == 900)
        let restoration = state.takeRestorationOffset(maximumOffset: 1400)
        #expect(state.pendingRestoreOffset == nil)
        #expect(restoration == 900)
        #expect(state.takeRestorationOffset(maximumOffset: 1400) == nil)
        #expect(!state.scrollState.isAtLatest)
    }

    @Test func newScrollOverridesAnUnfinishedRestoration() {
        let state = ConversationReadingState()
        state.scrollState.revealHistory()
        state.recordOffset(900)
        state.prepareForDisplay()
        state.userStartedScrolling()
        state.recordOffset(120)
        #expect(state.takeRestorationOffset(maximumOffset: 1400) == nil)
        #expect(state.pendingRestoreOffset == nil)
        #expect(state.visibleOffset == 120)
    }

    @Test func returningToConversationDoesNotResumeContentFollowing() {
        let state = ConversationReadingState()
        state.recordOffset(900)
        state.leave()
        state.prepareForDisplay()
        #expect(state.scrollState.isAtLatest)
        #expect(state.pendingRestoreOffset == nil)
    }
}
