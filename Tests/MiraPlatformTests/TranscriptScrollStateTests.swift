import Testing

@Suite("Conversation scroll intent")
struct TranscriptScrollStateTests {
    @Test func contentGrowthFollowsUntilTheUserReadsHistory() {
        var state = TranscriptScrollState()
        #expect(state.shouldFollowContentChange())
        state.userScrollChanged(isScrolling: true, isNearBottom: true)
        #expect(!state.shouldFollowContentChange())
        state.userScrollChanged(isScrolling: false, isNearBottom: false)
        #expect(!state.shouldFollowContentChange())
        // Further parsing and the terminal message must not pull the reader down.
        state.userScrollChanged(isScrolling: false, isNearBottom: false)
        #expect(!state.shouldFollowContentChange())
    }

    @Test func returningToBottomAndExplicitJumpRestoreFollowing() {
        var state = TranscriptScrollState()
        state.revealHistory()
        #expect(!state.shouldFollowContentChange())
        state.userScrollChanged(isScrolling: true, isNearBottom: false)
        state.userScrollChanged(isScrolling: false, isNearBottom: true)
        #expect(state.shouldFollowContentChange())
        state.revealHistory()
        state.jumpToLatest()
        #expect(state.shouldFollowContentChange())
    }

    @Test func sourceNavigationDoesNotResumeOnAnUnrelatedIdleCallback() {
        var state = TranscriptScrollState()
        state.revealHistory()
        state.userScrollChanged(isScrolling: false, isNearBottom: true)
        #expect(!state.shouldFollowContentChange())
    }

    @Test func shortContentAndBottomToleranceAreHandled() {
        #expect(TranscriptScrollState.isNearBottom(contentHeight: 200, visibleBottom: 600))
        #expect(TranscriptScrollState.isNearBottom(contentHeight: 1000, visibleBottom: 936))
        #expect(!TranscriptScrollState.isNearBottom(contentHeight: 1000, visibleBottom: 935))
    }
}
