import Foundation

/// User intent is separate from content growth: a growing answer is not a scroll gesture.
struct TranscriptScrollState: Equatable {
    private(set) var isAtLatest = true
    private(set) var isUserScrolling = false
    private(set) var hasPendingJumpToLatest = false

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

    func shouldKeepBottomAlignedDuringResize() -> Bool {
        isAtLatest && !isUserScrolling
    }

    static func isNearBottom(contentHeight: Double, visibleBottom: Double) -> Bool {
        contentHeight - visibleBottom <= 64
    }
}
