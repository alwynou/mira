import Testing
import Foundation

@Suite("Conversation reading restoration")
@MainActor
struct ConversationReadingStateTests {
    @Test func teardownGeometryCannotReplacePositionBeforeRestoration() {
        let state = ConversationReadingState()
        state.scrollState.revealHistory()
        state.recordOffset(900)
        state.leave()
        state.recordOffset(0) // Teardown geometry must not replace the saved reading offset.
        state.prepareForDisplay()
        state.recordOffset(0)
        #expect(state.visibleOffset == 900)
        #expect(state.pendingRestoreOffset == 900)
        state.completeRestoration()
        #expect(state.pendingRestoreOffset == nil)
        #expect(state.visibleOffset == 900)
        #expect(!state.scrollState.isAtLatest)
    }

    @Test func newScrollOverridesAnUnfinishedRestoration() {
        let state = ConversationReadingState()
        state.scrollState.revealHistory()
        state.recordOffset(900)
        state.prepareForDisplay()
        state.userStartedScrolling()
        state.recordOffset(120)
        #expect(state.pendingRestoreOffset == nil)
        #expect(state.visibleOffset == 120)
    }

    @Test func returningToConversationDoesNotResumeContentFollowing() {
        let state = ConversationReadingState()
        state.recordOffset(900)
        state.leave()
        state.prepareForDisplay()
        #expect(state.scrollState.isAtLatest)
        #expect(state.pendingRestoreOffset == 900)
    }

    @Test func onlyAnUnvisitedConversationStartsWithoutRestoration() {
        let first = ConversationPageState().readingState
        first.prepareForDisplay()
        #expect(first.pendingRestoreOffset == nil)
        first.recordOffset(420)
        first.leave()
        let second = ConversationPageState().readingState
        second.prepareForDisplay()
        #expect(second.pendingRestoreOffset == nil)
        second.recordOffset(870)
        second.leave()
        let returning = first
        #expect(returning === first)
        returning.prepareForDisplay()
        #expect(returning.pendingRestoreOffset == 420)
        #expect(second.visibleOffset == 870)
    }

    @Test func topContentInsetIsPreserved() {
        let state = ConversationReadingState()
        state.recordOffset(-72)
        state.leave()
        state.prepareForDisplay()
        #expect(state.pendingRestoreOffset == -72)
    }
}
