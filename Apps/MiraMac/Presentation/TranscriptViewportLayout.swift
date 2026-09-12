import AppKit
import ListViewKit

/// The transcript retains its full viewport behind the floating input surface.
@MainActor
enum TranscriptViewportLayout {
    @discardableResult
    static func setTopOverlayHeight(_ height: CGFloat, in list: ListScrollView) -> Bool {
        let overlay = height.isFinite ? max(0, ceil(height)) : 0
        let inset = overlay + MiraTheme.Spacing.xl
        guard list.contentInsets.top != inset else { return false }
        list.contentInsets.top = inset
        return true
    }

    @discardableResult
    static func setBottomOverlayHeight(_ height: CGFloat, in list: ListScrollView, followingLatest: Bool) -> Bool {
        let inset = height.isFinite ? max(0, ceil(height)) : 0
        guard list.contentInsets.bottom != inset else { return false }
        list.contentInsets.bottom = inset
        if followingLatest { list.setContentOffset(list.maximumContentOffset, animated: false) }
        return true
    }

    static func isNearLatest(in list: ListScrollView) -> Bool {
        TranscriptScrollState.isNearBottom(
            contentHeight: list.contentSize.height,
            visibleBottom: list.contentOffset.y + list.bounds.height - list.contentInsets.bottom
        )
    }

    static func distanceToLatest(in list: ListScrollView) -> CGFloat {
        list.contentSize.height - (list.contentOffset.y + list.bounds.height - list.contentInsets.bottom)
    }
}
