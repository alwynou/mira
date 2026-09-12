import Testing

@Suite("Conversation scroll intent")
struct TranscriptScrollStateTests {
    @Test func contentGrowthNeverStartsAnAutomaticFollow() {
        var state = TranscriptScrollState()
        state.updateVisiblePosition(isNearLatest: true)
        #expect(state.isAtLatest)
        // Content growth does not call a state transition; geometry reports the
        // reader's actual position when the layout settles.
        state.updateVisiblePosition(isNearLatest: false)
        #expect(!state.isAtLatest)
    }

    @Test func returningToBottomAndExplicitJumpUpdateVisiblePosition() {
        var state = TranscriptScrollState()
        state.revealHistory()
        #expect(!state.isAtLatest)
        state.userScrollChanged(isScrolling: true, isNearBottom: false)
        state.userScrollChanged(isScrolling: false, isNearBottom: true)
        #expect(state.isAtLatest)
        state.revealHistory()
        state.jumpToLatest()
        #expect(state.hasPendingJumpToLatest)
        let consumedJump = state.consumePendingJumpToLatest()
        #expect(consumedJump)
        #expect(!state.hasPendingJumpToLatest)
        state.updateVisiblePosition(isNearLatest: true)
        #expect(state.isAtLatest)
    }

    @Test func streamingGrowthAfterExplicitJumpDoesNotFollowAgain() {
        var state = TranscriptScrollState()
        state.revealHistory()
        state.jumpToLatest()
        let consumedJump = state.consumePendingJumpToLatest()
        #expect(consumedJump)
        state.updateVisiblePosition(isNearLatest: true)
        #expect(state.isAtLatest)
        state.updateVisiblePosition(isNearLatest: false)
        #expect(!state.isAtLatest)
    }

    @Test func bottomAlignmentForResizePreservesOnlyCurrentBottomIntent() {
        var state = TranscriptScrollState()
        #expect(state.shouldKeepBottomAlignedDuringResize())
        state.updateVisiblePosition(isNearLatest: false)
        #expect(!state.shouldKeepBottomAlignedDuringResize())
        state.jumpToLatest()
        #expect(!state.shouldKeepBottomAlignedDuringResize())
        let consumedJump = state.consumePendingJumpToLatest()
        #expect(consumedJump)
        state.updateVisiblePosition(isNearLatest: true)
        #expect(state.shouldKeepBottomAlignedDuringResize())
    }

    @Test func sourceNavigationDoesNotResumeOnAnUnrelatedIdleCallback() {
        var state = TranscriptScrollState()
        state.revealHistory()
        state.userScrollChanged(isScrolling: false, isNearBottom: true)
        #expect(!state.isAtLatest)
    }

    @Test func shortContentAndBottomToleranceAreHandled() {
        #expect(TranscriptScrollState.isNearBottom(contentHeight: 200, visibleBottom: 600))
        #expect(TranscriptScrollState.isNearBottom(contentHeight: 1000, visibleBottom: 936))
        #expect(!TranscriptScrollState.isNearBottom(contentHeight: 1000, visibleBottom: 935))
    }

    @Test func jumpVisibilityIsIndependentOfScrollingAndLatestState() {
        var state = TranscriptScrollState()
        state.updateJumpVisibility(distanceToLatest: 8)
        #expect(state.showsJumpToLatest)

        state.userScrollChanged(isScrolling: true, isNearBottom: false)
        state.userScrollChanged(isScrolling: false, isNearBottom: true)
        state.updateVisiblePosition(isNearLatest: true)
        #expect(state.showsJumpToLatest)

        state.updateJumpVisibility(distanceToLatest: 2)
        #expect(!state.showsJumpToLatest)
        state.revealHistory()
        #expect(!state.isAtLatest)
        #expect(!state.showsJumpToLatest)
    }

    @Test func jumpVisibilityUsesHysteresisAtBothThresholds() {
        var state = TranscriptScrollState()
        state.updateJumpVisibility(distanceToLatest: 7.9)
        #expect(!state.showsJumpToLatest)
        state.updateJumpVisibility(distanceToLatest: 8)
        #expect(state.showsJumpToLatest)

        for distance in [7.9, 4, 2.1] {
            state.updateJumpVisibility(distanceToLatest: distance)
            #expect(state.showsJumpToLatest)
        }
        state.updateJumpVisibility(distanceToLatest: 2)
        #expect(!state.showsJumpToLatest)
        state.updateJumpVisibility(distanceToLatest: 4)
        #expect(!state.showsJumpToLatest)
        state.updateJumpVisibility(distanceToLatest: 8)
        #expect(state.showsJumpToLatest)
    }

    @Test func explicitJumpHidesTheButtonImmediately() {
        var state = TranscriptScrollState()
        state.updateJumpVisibility(distanceToLatest: 256)
        #expect(state.showsJumpToLatest)

        state.jumpToLatest()

        #expect(!state.showsJumpToLatest)
        #expect(state.hasPendingJumpToLatest)
    }

    @Test func invalidJumpGeometryDoesNotChangeVisibility() {
        var state = TranscriptScrollState()
        for distance in [Double.nan, .infinity, -.infinity] {
            state.updateJumpVisibility(distanceToLatest: distance)
            #expect(!state.showsJumpToLatest)
        }
        state.updateJumpVisibility(distanceToLatest: 8)
        #expect(state.showsJumpToLatest)
        for distance in [Double.nan, .infinity, -.infinity] {
            state.updateJumpVisibility(distanceToLatest: distance)
            #expect(state.showsJumpToLatest)
        }
    }
}
