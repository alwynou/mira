import Foundation
import Observation

/// Retains reading intent when the transcript leaves the window's detail column.
@MainActor @Observable
final class ConversationReadingState {
    struct NativeAnchor {
        let id: String
        let offset: CGFloat
    }
    @ObservationIgnored var nativeAnchor: NativeAnchor?
    @ObservationIgnored var expandedThinkingIDs: Set<String> = []
    var scrollState = TranscriptScrollState()
    @ObservationIgnored private var isVisible = true
    @ObservationIgnored var visibleOffset: CGFloat = 0
    @ObservationIgnored private(set) var pendingRestoreOffset: CGFloat?

    func prepareForDisplay() {
        pendingRestoreOffset = scrollState.isAtLatest ? nil : visibleOffset
        isVisible = true
    }

    func takeRestorationOffset(maximumOffset: CGFloat) -> CGFloat? {
        guard let offset = pendingRestoreOffset, maximumOffset >= offset else { return nil }
        pendingRestoreOffset = nil
        return offset
    }

    func recordOffset(_ offset: CGFloat) {
        guard isVisible, pendingRestoreOffset == nil else { return }
        visibleOffset = max(0, offset)
    }

    func userStartedScrolling() { pendingRestoreOffset = nil }

    func leave() {
        isVisible = false
        scrollState.userScrollChanged(isScrolling: false, isNearBottom: false)
    }
}
