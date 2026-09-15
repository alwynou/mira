import AppKit
import ListViewKit

/// The transcript retains its full viewport behind the floating input surface.
@MainActor
enum TranscriptViewportLayout {
    @discardableResult
    static func setTopOverlayHeight(_ height: CGFloat, in list: ListScrollView) -> Bool {
        // SwiftUI passes the measured header occlusion explicitly.
        // AppKit's automatic adjustment would overwrite this owned inset.
        list.automaticallyAdjustsContentInsets = false
        let overlay = height.isFinite ? max(0, ceil(height)) : 0
        let inset = overlay + MiraTheme.Spacing.xl
        guard list.contentInsets.top != inset else { return false }
        let previousOffset = list.contentOffset
        let wasAtTop = abs(previousOffset.y - list.minimumContentOffset.y) < 0.5
        list.contentInsets.top = inset
        list.setContentOffset(wasAtTop ? list.minimumContentOffset : previousOffset, animated: false)
        return true
    }

    @discardableResult
    static func setBottomOverlayHeight(_ height: CGFloat, in list: ListScrollView, followingLatest: Bool) -> Bool {
        list.automaticallyAdjustsContentInsets = false
        // Reserve only a document tail. A native bottom inset would treat the
        // floating composer as scroll chrome and shorten the scrollbar track.
        let inset = height.isFinite ? max(0, ceil(height)) : 0
        guard list.bottomContentPadding != inset else { return false }
        list.bottomContentPadding = inset
        if followingLatest { list.setContentOffset(list.maximumContentOffset, animated: false) }
        return true
    }

    static func isNearLatest(in list: ListScrollView) -> Bool {
        TranscriptScrollState.isNearBottom(
            contentHeight: list.listContentSize.height,
            visibleBottom: list.contentOffset.y + list.viewportSize.height - list.bottomContentPadding
        )
    }

    static func distanceToLatest(in list: ListScrollView) -> CGFloat {
        list.listContentSize.height - (list.contentOffset.y + list.viewportSize.height - list.bottomContentPadding)
    }
}
