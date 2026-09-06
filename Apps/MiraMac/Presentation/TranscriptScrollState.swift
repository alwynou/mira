import Foundation

/// User intent is separate from content growth: a growing answer is not a scroll gesture.
struct TranscriptScrollState: Equatable {
    private(set) var followsLatest = true
    private(set) var isUserScrolling = false

    mutating func userScrollChanged(isScrolling: Bool, isNearBottom: Bool) {
        if isScrolling {
            isUserScrolling = true
            followsLatest = false
        } else if isUserScrolling {
            isUserScrolling = false
            followsLatest = isNearBottom
        }
    }

    mutating func revealHistory() { followsLatest = false }
    mutating func jumpToLatest() { followsLatest = true }

    func shouldFollowContentChange() -> Bool { followsLatest && !isUserScrolling }

    static func isNearBottom(contentHeight: Double, visibleBottom: Double) -> Bool {
        contentHeight - visibleBottom <= 64
    }
}
