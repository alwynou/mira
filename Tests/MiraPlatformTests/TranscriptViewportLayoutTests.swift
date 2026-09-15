import AppKit
import ListViewKit
import Testing

@MainActor
@Suite("Transcript viewport layout", .serialized)
struct TranscriptViewportLayoutTests {
    @Test("the first row clears the native titlebar without moving historical reading")
    func titlebarClearancePreservesHistory() {
        let list = makeList(contentHeight: 1_200, viewportHeight: 760)
        #expect(TranscriptViewportLayout.setTopOverlayHeight(52, in: list))
        list.setContentOffset(list.minimumContentOffset, animated: false)
        #expect(-list.contentOffset.y == 52 + MiraTheme.Spacing.xl)

        list.setContentOffset(CGPoint(x: 0, y: 240), animated: false)
        #expect(TranscriptViewportLayout.setTopOverlayHeight(64, in: list))
        #expect(list.contentOffset.y == 240)
        #expect(list.bottomContentPadding == 0)

        TranscriptViewportLayout.setBottomOverlayHeight(180, in: list, followingLatest: true)
        #expect(list.contentOffset.y + list.viewportSize.height - list.bottomContentPadding == 1_200)
    }

    @Test("latest content clears a floating overlay")
    func latestContentClearsBottomOverlay() {
        let list = makeList(contentHeight: 1_200, viewportHeight: 300)

        #expect(TranscriptViewportLayout.setBottomOverlayHeight(160, in: list, followingLatest: true))
        #expect(list.bottomContentPadding == 160)
        #expect(list.contentInsets.bottom == 0)
        #expect(list.contentView.frame.height == 300)
        #expect(list.rowContainer.frame.height == 1_360)
        #expect(list.listContentSize.height == 1_200)
        #expect(list.contentOffset.y == list.maximumContentOffset.y)
        #expect(list.contentOffset.y + list.viewportSize.height - list.bottomContentPadding == 1_200)
        #expect(TranscriptViewportLayout.isNearLatest(in: list))
    }

    @Test("following retargets when the overlay grows and shrinks")
    func followingRetargetsDynamicOverlayHeight() {
        let list = makeList(contentHeight: 1_200, viewportHeight: 300)

        #expect(TranscriptViewportLayout.setBottomOverlayHeight(80, in: list, followingLatest: true))
        #expect(list.contentOffset.y == 980)

        #expect(TranscriptViewportLayout.setBottomOverlayHeight(220, in: list, followingLatest: true))
        #expect(list.contentOffset.y == 1_120)
        #expect(TranscriptViewportLayout.setBottomOverlayHeight(40, in: list, followingLatest: true))
        #expect(list.contentOffset.y == 940)
        #expect(TranscriptViewportLayout.isNearLatest(in: list))
    }

    @Test("paused reading keeps its offset and does not treat covered content as latest")
    func pausedReadingPreservesOffsetAndAccountsForOcclusion() {
        let list = makeList(contentHeight: 1_200, viewportHeight: 300)
        list.setContentOffset(list.maximumContentOffset, animated: false)
        let pausedOffset = list.contentOffset.y

        #expect(TranscriptViewportLayout.setBottomOverlayHeight(160, in: list, followingLatest: false))
        #expect(list.contentOffset.y == pausedOffset)
        #expect(!TranscriptViewportLayout.isNearLatest(in: list))
        list.setContentOffset(CGPoint(x: 0, y: list.maximumContentOffset.y - 65), animated: false)
        #expect(!TranscriptViewportLayout.isNearLatest(in: list))
        list.setContentOffset(CGPoint(x: 0, y: list.maximumContentOffset.y - 64), animated: false)
        #expect(TranscriptViewportLayout.isNearLatest(in: list))
    }

    @Test("zero and short content remain in bounds with an overlay")
    func zeroAndShortContentRemainInBounds() {
        let zero = makeList(contentHeight: 0, viewportHeight: 300)
        #expect(TranscriptViewportLayout.setBottomOverlayHeight(180, in: zero, followingLatest: true))
        #expect(zero.contentOffset.y == zero.maximumContentOffset.y)
        #expect(zero.contentOffset.y >= zero.minimumContentOffset.y)
        #expect(zero.contentOffset.y <= zero.maximumContentOffset.y)
        #expect(TranscriptViewportLayout.isNearLatest(in: zero))

        let short = makeList(contentHeight: 120, viewportHeight: 300)
        #expect(TranscriptViewportLayout.setBottomOverlayHeight(180, in: short, followingLatest: true))
        #expect(short.contentOffset.y == short.maximumContentOffset.y)
        #expect(short.contentOffset.y >= short.minimumContentOffset.y)
        #expect(short.contentOffset.y <= short.maximumContentOffset.y)
        #expect(TranscriptViewportLayout.isNearLatest(in: short))
    }

    @Test("latest target follows a viewport resize")
    func latestTargetFollowsViewportResize() {
        let list = makeList(contentHeight: 1_200, viewportHeight: 300)
        #expect(TranscriptViewportLayout.setBottomOverlayHeight(160, in: list, followingLatest: true))

        list.frame.size.height = 500
        list.layoutSubtreeIfNeeded()
        list.setContentOffset(list.maximumContentOffset, animated: false)

        #expect(list.contentOffset.y == 860)
        #expect(list.contentOffset.y + list.viewportSize.height - list.bottomContentPadding == 1_200)
        #expect(TranscriptViewportLayout.isNearLatest(in: list))
    }

    private func makeList(contentHeight: CGFloat, viewportHeight: CGFloat) -> ListScrollView {
        _ = NSApplication.shared
        let list = ListScrollView(frame: CGRect(x: 0, y: 0, width: 640, height: viewportHeight))
        list.listContentSize = CGSize(width: 640, height: contentHeight)
        list.layoutSubtreeIfNeeded()
        return list
    }
}
