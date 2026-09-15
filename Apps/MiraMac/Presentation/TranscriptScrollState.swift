import Foundation

/// User intent is separate from content growth: a growing answer is not a scroll gesture.
struct TranscriptScrollState: Equatable {
    private(set) var isAtLatest = true
    private(set) var isUserScrolling = false
    private(set) var hasPendingJumpToLatest = false
    private(set) var showsJumpToLatest = false

    mutating func userScrollChanged(isScrolling: Bool, isNearBottom: Bool) {
        if isScrolling {
            isUserScrolling = true
            hasPendingJumpToLatest = false
            isAtLatest = false
        } else if isUserScrolling {
            isUserScrolling = false
            isAtLatest = isNearBottom
        }
    }

    mutating func revealHistory() {
        isAtLatest = false
        hasPendingJumpToLatest = false
    }

    /// Requests one explicit positioning operation. Streaming growth must not
    /// turn this into a continuing follow mode.
    mutating func jumpToLatest() {
        hasPendingJumpToLatest = true
        showsJumpToLatest = false
    }

    mutating func consumePendingJumpToLatest() -> Bool {
        guard hasPendingJumpToLatest else { return false }
        hasPendingJumpToLatest = false
        return true
    }

    mutating func updateVisiblePosition(isNearLatest: Bool) {
        guard !isUserScrolling else { return }
        isAtLatest = isNearLatest
    }

    /// Small layout/rounding differences near the bottom must not toggle the action.
    mutating func updateJumpVisibility(distanceToLatest: Double) {
        guard distanceToLatest.isFinite else { return }
        if distanceToLatest >= 8 {
            showsJumpToLatest = true
        } else if distanceToLatest <= 2 {
            showsJumpToLatest = false
        }
    }

    func shouldKeepBottomAlignedDuringResize() -> Bool {
        isAtLatest && !isUserScrolling
    }

    static func isNearBottom(contentHeight: Double, visibleBottom: Double) -> Bool {
        contentHeight - visibleBottom <= 64
    }
}
