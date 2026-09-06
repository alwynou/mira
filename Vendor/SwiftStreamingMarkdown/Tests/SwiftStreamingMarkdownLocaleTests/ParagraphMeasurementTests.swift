#if DEBUG && canImport(AppKit)
import AppKit
import Foundation
import Testing
@testable import SwiftStreamingMarkdown

@MainActor
@Suite("AppKit paragraph measurement")
struct ParagraphMeasurementTests {
  private func contents(_ text: String) -> NSMutableAttributedString {
    NSMutableAttributedString(string: text)
  }

  @Test("reuses a same-width measurement")
  func reusesSameWidthMeasurement() {
    let view = ParagraphNSView()
    view.setParagraphContents(contents("A paragraph that is long enough to wrap at a narrow width."), animatedByWord: false)

    let first = view.measureSize(fittingWidth: 180)
    let countAfterFirst = view.debugMeasurementCount
    let second = view.measureSize(fittingWidth: 180)

    #expect(first == second)
    #expect(view.debugMeasurementCount == countAfterFirst)

    _ = view.measureSize(fittingWidth: 320)
    _ = view.measureSize(fittingWidth: 640)
    let countAfterAlternatingWidths = view.debugMeasurementCount
    _ = view.measureSize(fittingWidth: 320)
    #expect(view.debugMeasurementCount == countAfterAlternatingWidths)
  }

  @Test("stable frames do not invalidate after different sizing proposals")
  func stableFrameDoesNotInvalidate() {
    let view = InvalidationCountingParagraph()
    view.setParagraphContents(contents("A paragraph with wrapping text and several measurement proposals."), animatedByWord: false)
    view.setFrameSize(NSSize(width: 180, height: 100))
    view.layout()
    let count = view.invalidationCount
    for _ in 0..<10 {
      _ = view.measureSize(fittingWidth: 640)
      view.layout()
    }
    #expect(view.invalidationCount == count)
  }

  @Test("invalidates measurement after content and width changes")
  func invalidatesAfterContentAndWidthChanges() {
    let view = ParagraphNSView()
    view.setParagraphContents(contents("Initial content that wraps."), animatedByWord: false)
    view.setFrameSize(NSSize(width: 180, height: 0))
    _ = view.intrinsicContentSize
    let initialCount = view.debugMeasurementCount

    view.setParagraphContents(contents("Updated content that also wraps differently."), animatedByWord: false)
    _ = view.intrinsicContentSize
    #expect(view.debugMeasurementCount == initialCount + 1)

    view.setFrameSize(NSSize(width: 260, height: 0))
    view.layout()
    _ = view.intrinsicContentSize
    #expect(view.debugMeasurementCount == initialCount + 2)
  }

  @Test("recovers when a zero-width view receives a real width")
  func recoversFromZeroWidth() {
    let view = ParagraphNSView()
    view.setParagraphContents(contents("Text measured before the view receives its final width."), animatedByWord: false)
    view.setFrameSize(NSSize(width: 0, height: 0))
    _ = view.intrinsicContentSize
    let countAfterFallbackWidth = view.debugMeasurementCount

    view.setFrameSize(NSSize(width: 220, height: 0))
    view.layout()
    let measured = view.intrinsicContentSize

    #expect(measured.width > 0)
    #expect(measured.height > 0)
    #expect(view.debugMeasurementCount == countAfterFallbackWidth + 1)
  }

  @Test("measures Unicode content as a finite nonempty paragraph")
  func measuresUnicodeContent() {
    let view = ParagraphNSView()
    view.setParagraphContents(contents("中文 · e\u{301} · 🧠"), animatedByWord: false) // i18n-fixture: Unicode text layout.
    view.setFrameSize(NSSize(width: 160, height: 0))

    let measured = view.intrinsicContentSize

    #expect(measured.width.isFinite)
    #expect(measured.height.isFinite)
    #expect(measured.height > 0)
  }

  @Test("preserves empty measurement and recovers after it")
  func preservesEmptyMeasurement() {
    let view = ParagraphNSView()
    view.setFrameSize(NSSize(width: 160, height: 0))
    view.setParagraphContents(contents("content"), animatedByWord: false)
    _ = view.intrinsicContentSize

    view.setParagraphContents(contents(""), animatedByWord: false)
    let empty = view.intrinsicContentSize
    #expect(empty == .zero)

    view.setParagraphContents(contents("content again"), animatedByWord: false)
    let recovered = view.intrinsicContentSize
    #expect(recovered.height > 0)
  }
}
@MainActor
private final class InvalidationCountingParagraph: ParagraphNSView {
  var invalidationCount = 0
  override func invalidateIntrinsicContentSize() {
    invalidationCount += 1
    super.invalidateIntrinsicContentSize()
  }
}
#endif
