#if canImport(AppKit)
import AppKit
import Testing

@testable import ListViewKit

private struct NativeBackendItem: Identifiable, Hashable {
    let id: Int
}

@Suite(.serialized)
@MainActor
struct NativeScrollBackendTests {
    @Test
    func effectiveViewportAndVirtualDocumentGeometry() {
        let scroll = ListScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        // Insets belong to NSScrollView; it propagates them to its native clip.
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 12, left: 8, bottom: 20, right: 16)
        scroll.listContentSize = CGSize(width: 999, height: 1_000)

        #expect(scroll.viewportSize.width == scroll.contentView.bounds.width - 24)
        #expect(scroll.viewportSize.height == 240)
        #expect(scroll.rowContainer.frame.width == scroll.viewportSize.width)
        #expect(scroll.rowContainer.frame.height == 1_000)
        #expect(scroll.minimumContentOffset == CGPoint(x: -8, y: -12))
        #expect(scroll.maximumContentOffset == CGPoint(x: -8, y: 780))
    }

    @Test
    func heightCompensationIsAppliedAfterInstallingNewDocumentSize() {
        let scroll = ListScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        scroll.listContentSize = CGSize(width: 320, height: 1_000)
        scroll.setContentOffset(CGPoint(x: 0, y: 400), animated: false)

        scroll.compensateScrollOffset(by: 370)
        scroll.listContentSize = CGSize(width: 320, height: 1_370)

        #expect(abs(scroll.contentOffset.y - 770) < 0.001)
        #expect(abs(scroll.maximumContentOffset.y - 1_130) < 0.001)
    }

    @Test
    func tenThousandRowsKeepMountedViewsBounded() {
        let list = ListView<NativeBackendItem>(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        list.rows {
            ListRow(ListRowView.self)
                .estimatedHeight(60)
                .height { _, _ in 60 }
                .configure { _, _, _ in }
        }
        list.apply((0 ..< 10_000).map(NativeBackendItem.init))
        list.needsLayout = true
        list.layoutSubtreeIfNeeded()

        #expect(list.content.count == 10_000)
        #expect(list.visibleRowViews.count < 40)
        #expect(list.rowContainer.frame.height == 600_000)
    }

    @Test
    func changingOverlayHeightAddsOnlyDocumentTailAndKeepsRowsBehindIt() {
        let list = ListView<NativeBackendItem>(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        list.automaticallyAdjustsContentInsets = false
        list.rows {
            ListRow(ListRowView.self).estimatedHeight(60).height { _, _ in 60 }.configure { _, _, _ in }
        }
        list.apply((0..<100).map(NativeBackendItem.init))
        list.layoutSubtreeIfNeeded()
        list.setContentOffset(CGPoint(x: 0, y: 600), animated: false)
        for overlayHeight: CGFloat in [123, 237, 81] {
            list.bottomContentPadding = overlayHeight
            list.layoutSubtreeIfNeeded()
            #expect(list.contentOffset.y == 600)
            #expect(list.contentInsets.bottom == 0)
            #expect(list.viewportSize.height == 400)
            #expect(list.listContentSize.height == 6_000)
            #expect(list.rowContainer.frame.height == 6_000 + overlayHeight)
            // Rows in the covered part remain mounted for material sampling.
            #expect(list.rowView(for: 16) != nil)
        }
        list.scrollToRow(at: 99, at: .bottom, animated: false)
        #expect(abs(list.rectForRow(at: 99).maxY - list.contentOffset.y - 319) < 0.001)
    }

    @Test
    func nativeLiveScrollPhasesDriveInteractionAndCallback() {
        let scroll = ListScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        var callbackCount = 0
        scroll.onUserScroll = { callbackCount += 1 }

        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        #expect(scroll.hasActiveUserInteraction)
        #expect(scroll.isScrollOffsetOwnedByUser)
        #expect(callbackCount == 1)

        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        #expect(callbackCount == 1)

        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        #expect(!scroll.hasActiveUserInteraction)
        #expect(!scroll.isUserInteractingWithScroll)
    }

    @Test
    func cancellingAnimatedScrollLeavesTheCurrentOffsetInPlace() async throws {
        let scroll = ListScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        scroll.listContentSize = CGSize(width: 320, height: 2_000)
        scroll.setContentOffset(CGPoint(x: 0, y: 100), animated: false)
        scroll.setContentOffset(CGPoint(x: 0, y: 1_000), animated: true)
        try await Task.sleep(for: .milliseconds(70))
        #expect(scroll.contentOffset.y > 100)
        #expect(scroll.contentOffset.y < 1_000)

        scroll.cancelScrollingAnimation()
        let stopped = scroll.contentOffset
        try await Task.sleep(for: .milliseconds(250))

        #expect(abs(scroll.contentOffset.y - stopped.y) < 0.001)
    }
}
#endif
