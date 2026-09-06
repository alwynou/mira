#if DEBUG && canImport(AppKit)
import AppKit
import Foundation
import Testing
@testable import SwiftStreamingMarkdown

@MainActor
@Suite("Streaming fade")
struct StreamingFadeTests {
  @Test("append animates only an appended suffix and replacement clears it")
  func appendAndReplacementSemantics() {
    var fade = StreamingFadeState()
    fade.append(previous: "Prefix", current: "Prefix tail", enabled: true, at: 10)

    #expect(fade.batches.count == 1)
    #expect(fade.batches[0].range == NSRange(location: 6, length: 5))
    #expect(fade.batches[0].start == 10)

    fade.append(previous: "Prefix tail", current: "Prefix tail", enabled: true, at: 10.05)
    #expect(fade.batches.count == 1)
    #expect(fade.batches[0].start == 10)

    fade.append(previous: "Prefix tail", current: "Replacement", enabled: true, at: 10.1)
    #expect(fade.batches.isEmpty)

    fade.append(previous: "Replacement", current: "Replacement plus", enabled: true, at: 10.2)
    #expect(fade.batches.count == 1)
    fade.append(previous: "Replacement plus", current: "Replacement plus final", enabled: false, at: 10.25)
    #expect(fade.batches.isEmpty)
  }

  @Test("composed character boundaries are preserved for a split ZWJ suffix")
  func composedCharacterSafeSuffix() {
    let prefix = "Family: "
    let partial = prefix + "👨‍" // i18n-fixture: ZWJ sequence intentionally split across snapshots.
    let family = "👨‍👩‍👧‍👦" // i18n-fixture: ZWJ grapheme cluster boundary fixture.
    let current = prefix + family
    var fade = StreamingFadeState()

    fade.append(previous: partial, current: current, enabled: true, at: 0)

    #expect(fade.batches.count == 1)
    let range = fade.batches[0].range
    #expect(range.location == (prefix as NSString).length)
    #expect(range.length == (family as NSString).length)
    #expect((current as NSString).substring(with: range) == family)
  }

  @Test("opacity and expiration remain finite and bounded")
  func finiteDurationAndOpacity() {
    #expect(StreamingFadeState.duration.isFinite)
    #expect(StreamingFadeState.duration > 0)

    let start = 4.0
    let before = StreamingFadeState.opacity(start: start, at: start - 1)
    let middle = StreamingFadeState.opacity(start: start, at: start + StreamingFadeState.duration / 2)
    let end = StreamingFadeState.opacity(start: start, at: start + StreamingFadeState.duration)

    #expect(before.isFinite)
    #expect(before == 0)
    // Keep upstream's visibly gradual cadence; a fast whole-packet fade is not equivalent.
    #expect(StreamingFadeState.duration == 0.5)
    #expect(StreamingFadeState.opacity(start: start, at: start + 0.1) < 0.2)
    #expect(middle.isFinite)
    #expect(middle > 0 && middle < 1)
    #expect(end.isFinite)
    #expect(end == 1)

    var fade = StreamingFadeState()
    fade.append(previous: "", current: "tail", enabled: true, at: start)
    fade.advance(at: start + StreamingFadeState.maximumLifetime)
    #expect(fade.batches.isEmpty)
  }

  @Test("a burst of deltas stays within the bounded animated tail")
  func boundedBurst() {
    var fade = StreamingFadeState()
    var previous = ""
    for index in 0..<1_000 {
      let current = previous + "x"
      fade.append(previous: previous, current: current, enabled: true, at: Double(index) / 120)
      previous = current
    }

    #expect(fade.batches.count <= StreamingFadeState.maximumBatches)
    #expect(fade.batches.allSatisfy { $0.range.length <= StreamingFadeState.maximumAnimatedLength })
    #expect(fade.batches.reduce(0) { $0 + $1.range.length } <= StreamingFadeState.maximumAnimatedLength)
    #expect(fade.batches.allSatisfy { $0.range.location >= previous.utf16.count - StreamingFadeState.maximumAnimatedLength })
    #expect(fade.batches.allSatisfy { NSMaxRange($0.range) <= previous.utf16.count })
  }

  @Test("large simultaneous chunks trim the total retained tail")
  func largeBurstBudget() {
    var fade = StreamingFadeState()
    var text = ""
    for index in 0..<20 {
      let next = text + String(repeating: "x", count: 1_000)
      fade.append(previous: text, current: next, enabled: true, at: Double(index) * 0.001)
      text = next
      #expect(fade.batches.reduce(0) { $0 + $1.range.length } <= StreamingFadeState.maximumAnimatedLength)
      #expect(fade.batches.allSatisfy { $0.range.location >= text.utf16.count - StreamingFadeState.maximumAnimatedLength })
    }
  }

  @Test("the UTF-16 budget also rejects one oversized composed character")
  func oversizedComposedCharacterDoesNotExceedTailBudget() {
    let oversized = "A" + String(repeating: "\u{301}", count: StreamingFadeState.maximumAnimatedLength + 512) // i18n-fixture: One grapheme with many combining marks tests the UTF-16 cap.
    var fade = StreamingFadeState()

    fade.append(previous: "", current: oversized, enabled: true, at: 1)

    #expect(fade.batches.isEmpty)
    #expect(fade.batches.allSatisfy { $0.range.length <= StreamingFadeState.maximumAnimatedLength })
    #expect(fade.batches.reduce(0) { $0 + $1.range.length } <= StreamingFadeState.maximumAnimatedLength)
    #expect(fade.batches.allSatisfy { NSMaxRange($0.range) <= oversized.utf16.count })
  }

  @Test("injected display ticks advance through multiple frames and finish")
  func injectedManagerTicks() {
    let start = 10.0
    let storage = NSTextStorage(string: "Streaming tail")
    let manager = StreamingFadeLayoutManager()
    let container = NSTextContainer(size: NSSize(width: 320, height: 80))
    manager.addTextContainer(container)
    storage.addLayoutManager(manager)
    manager.ensureLayout(for: container)
    manager.fade.append(previous: "Streaming", current: "Streaming tail", enabled: true, at: start)
    manager.prepareDrawingSpans()

    manager.advance(at: start + 0.04)
    #expect(manager.frameTime == start + 0.04)
    #expect(manager.fade.batches.count == 1)
    manager.advance(at: start + 0.12)
    #expect(manager.frameTime == start + 0.12)
    #expect(manager.fade.batches.count == 1)
    manager.advance(at: start + StreamingFadeState.maximumLifetime)
    #expect(manager.frameTime == start + StreamingFadeState.maximumLifetime)
    #expect(manager.fade.batches.isEmpty)
    manager.finish()
    #expect(manager.fade.batches.isEmpty)
  }

  @Test("display ticks preserve attributed text and cached measurement")
  func displayTickPreservesStorageAndMeasurement() {
    let view = ParagraphNSView()
    view.setFrameSize(NSSize(width: 360, height: 120))
    let link = URL(string: "https://example.com")!
    let initial = NSMutableAttributedString(string: "Stable prefix")
    initial.addAttribute(.font, value: NSFont.systemFont(ofSize: 18), range: NSRange(location: 0, length: initial.length))
    initial.addAttribute(.foregroundColor, value: NSColor.systemBlue, range: NSRange(location: 0, length: initial.length))
    view.setParagraphContents(initial, animatedByWord: false)

    let updated = NSMutableAttributedString(string: "Stable prefix animated tail")
    updated.addAttribute(.font, value: NSFont.systemFont(ofSize: 18), range: NSRange(location: 0, length: updated.length))
    updated.addAttribute(.foregroundColor, value: NSColor.systemBlue, range: NSRange(location: 0, length: updated.length))
    let tailRange = NSRange(location: ("Stable prefix " as NSString).length, length: ("animated tail" as NSString).length)
    updated.addAttribute(.foregroundColor, value: NSColor.systemRed, range: tailRange)
    updated.addAttribute(.link, value: link, range: tailRange)
    view.setParagraphContents(updated, animatedByWord: true)

    guard let storage = view.textStorage,
          let manager = view.layoutManager as? StreamingFadeLayoutManager else {
      Issue.record("Paragraph view did not expose its streaming layout manager.")
      return
    }
    let beforeTick = NSAttributedString(attributedString: storage)
    _ = view.measureSize(fittingWidth: 320)
    let countBeforeTick = view.debugMeasurementCount

    let start = manager.fade.batches.first!.start
    for frame in 1...12 {
      manager.advance(at: start + Double(frame) / 60)
      _ = view.measureSize(fittingWidth: 320)
    }
    #expect(!manager.fade.batches.isEmpty)
    #expect(storage.isEqual(to: beforeTick))
    // An unchanged final snapshot must reveal the tail immediately.
    view.setParagraphContents(updated, animatedByWord: false)
    #expect(manager.fade.batches.isEmpty)
    #expect((storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)?.isEqual(NSColor.systemBlue) == true)
    #expect((storage.attribute(.foregroundColor, at: tailRange.location, effectiveRange: nil) as? NSColor)?.isEqual(NSColor.systemRed) == true)
    #expect((storage.attribute(.link, at: tailRange.location, effectiveRange: nil) as? URL) == link)
    _ = view.measureSize(fittingWidth: 320)
    #expect(view.debugMeasurementCount == countBeforeTick)
  }

  @Test("bitmap drawing changes only the newly appended tail")
  func bitmapTailFadeLeavesPrefixUnchanged() {
    let prefix = "Prefix "
    let tail = "Tail"
    let text = prefix + tail
    let attributed = NSMutableAttributedString(string: text)
    attributed.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 20, weight: .regular), range: NSRange(location: 0, length: attributed.length))
    attributed.addAttribute(.foregroundColor, value: NSColor.black, range: NSRange(location: 0, length: attributed.length))

    let storage = NSTextStorage(attributedString: attributed)
    let manager = StreamingFadeLayoutManager()
    let container = NSTextContainer(size: NSSize(width: 320, height: 80))
    container.lineFragmentPadding = 0
    manager.addTextContainer(container)
    storage.addLayoutManager(manager)
    manager.ensureLayout(for: container)
    manager.fade.append(previous: prefix, current: text, enabled: true, at: 0)
    manager.prepareDrawingSpans()

    let prefixGlyphs = manager.glyphRange(forCharacterRange: NSRange(location: 0, length: (prefix as NSString).length), actualCharacterRange: nil)
    let tailGlyphs = manager.glyphRange(forCharacterRange: NSRange(location: (prefix as NSString).length, length: (tail as NSString).length), actualCharacterRange: nil)
    let prefixRect = manager.boundingRect(forGlyphRange: prefixGlyphs, in: container)
    let tailRect = manager.boundingRect(forGlyphRange: tailGlyphs, in: container)
    let xSplit = (prefixRect.maxX + tailRect.minX) / 2 + 16
    let start = render(manager: manager, size: NSSize(width: 320, height: 80), frameTime: 0)
    let middle = render(manager: manager, size: NSSize(width: 320, height: 80), frameTime: StreamingFadeState.duration / 2)
    let end = render(manager: manager, size: NSSize(width: 320, height: 80), frameTime: StreamingFadeState.maximumLifetime)
    let tailStart = min(320, Int(xSplit.rounded(.up)))

    #expect(pixelDifference(start, end, xRange: 0..<max(0, Int(xSplit.rounded(.down)))) == 0)
    #expect(pixelDifference(start, middle, xRange: tailStart..<320) > 0)
    #expect(pixelDifference(middle, end, xRange: tailStart..<320) > 0)
  }

  @Test("words in one provider packet reveal progressively")
  func wordStaggerIsVisibleWithinOnePacket() {
    let prefix = "Prefix "
    let content = NSMutableAttributedString(string: prefix + "Alpha Beta Gamma")
    content.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 20, weight: .regular), range: NSRange(location: 0, length: content.length))
    content.addAttribute(.foregroundColor, value: NSColor.black, range: NSRange(location: 0, length: content.length))
    let storage = NSTextStorage(attributedString: content)
    let manager = StreamingFadeLayoutManager()
    let container = NSTextContainer(size: NSSize(width: 640, height: 80))
    container.lineFragmentPadding = 0
    manager.addTextContainer(container)
    storage.addLayoutManager(manager)
    manager.ensureLayout(for: container)
    manager.fade.append(previous: prefix, current: content.string, enabled: true, at: 0)
    manager.prepareDrawingSpans()
    let alphaRange = (content.string as NSString).range(of: "Alpha")
    let gammaRange = (content.string as NSString).range(of: "Gamma")
    let alpha = manager.boundingRect(forGlyphRange: manager.glyphRange(forCharacterRange: alphaRange, actualCharacterRange: nil), in: container)
    let gamma = manager.boundingRect(forGlyphRange: manager.glyphRange(forCharacterRange: gammaRange, actualCharacterRange: nil), in: container)
    let initial = render(manager: manager, size: NSSize(width: 640, height: 80), frameTime: 0)
    let revealing = render(manager: manager, size: NSSize(width: 640, height: 80), frameTime: 0.05)
    #expect(pixelDifference(initial, revealing, xRange: Int(alpha.minX + 16)..<Int(alpha.maxX + 16)) > 0)
    #expect(pixelDifference(initial, revealing, xRange: Int(gamma.minX + 16)..<Int(gamma.maxX + 16)) == 0)
  }

  @Test("attachments remain outside fade drawing spans")
  func attachmentsRemainUnchanged() {
    let attachment = NSTextAttachment()
    let icon = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { rect in
      NSColor.systemRed.setFill()
      rect.fill()
      return true
    }
    attachment.attachmentCell = NSTextAttachmentCell(imageCell: icon)
    let attributed = NSMutableAttributedString(string: "Prefix ")
    attributed.append(NSAttributedString(attachment: attachment))
    attributed.append(NSAttributedString(string: " tail"))
    attributed.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 20, weight: .regular), range: NSRange(location: 0, length: attributed.length))
    let storage = NSTextStorage(attributedString: attributed)
    let manager = StreamingFadeLayoutManager()
    let container = NSTextContainer(size: NSSize(width: 320, height: 80))
    container.lineFragmentPadding = 0
    manager.addTextContainer(container)
    storage.addLayoutManager(manager)
    manager.ensureLayout(for: container)

    let attachmentLocation = ("Prefix " as NSString).length
    let attachmentRange = NSRange(location: attachmentLocation, length: 1)
    manager.fade.append(previous: "Prefix ", current: attributed.string, enabled: true, at: 0)
    manager.prepareDrawingSpans()
    let glyphs = manager.glyphRange(forCharacterRange: attachmentRange, actualCharacterRange: nil)
    let rect = manager.boundingRect(forGlyphRange: glyphs, in: container)
    let start = render(manager: manager, size: NSSize(width: 320, height: 80), frameTime: 0)
    let end = render(manager: manager, size: NSSize(width: 320, height: 80), frameTime: StreamingFadeState.maximumLifetime)
    #expect(rect.width > 0)
    #expect(pixelDifference(start, end, xRange: Int(rect.minX + 16)..<Int(rect.maxX + 16)) == 0)
    #expect(pixelDifference(start, end, xRange: Int(rect.maxX + 17)..<320) > 0)
    #expect((storage.attribute(.attachment, at: attachmentLocation, effectiveRange: nil) as? NSTextAttachment) === attachment)
  }

  @Test("the first parsed document disables update fades until the next parse")
  func parsedUpdateState() async {
    let controller = MarkdownViewController()
    #expect(controller.hasParsedUpdate == false)

    await controller.parse(text: "First successful parse")
    #expect(controller.renderable != nil)
    #expect(controller.hasParsedUpdate == false)

    await controller.parse(text: "Second successful parse")
    let secondDocument = controller.renderable
    #expect(secondDocument != nil)
    #expect(controller.hasParsedUpdate == true)

    let cancelled = Task { @MainActor in
      await controller.parse(text: "Cancelled parse")
    }
    cancelled.cancel()
    await cancelled.value

    #expect(controller.renderable == secondDocument)
    #expect(controller.hasParsedUpdate == true)
  }

  @Test("expired fades render identically to a fresh plain layout")
  func expiredFadeMatchesPlainLayout() {
    let fixtures: [(previous: String, current: String)] = [
      ("of", "office"),
      ("Cafe", "Cafe\u{301}"), // i18n-fixture: Combining mark completes a grapheme across updates.
      ("Team 👨‍", "Team 👨‍👩‍👧‍👦"), // i18n-fixture: ZWJ family sequence completes across updates.
      ("مرحبا ", "مرحبا بالعالم"), // i18n-fixture: Arabic right-to-left shaping fixture.
      ("東京", "東京タワー") // i18n-fixture: Japanese CJK shaping fixture.
    ]

    for fixture in fixtures {
      let attributed = NSMutableAttributedString(string: fixture.current)
      attributed.addAttribute(.font, value: NSFont.systemFont(ofSize: 22), range: NSRange(location: 0, length: attributed.length))
      attributed.addAttribute(.foregroundColor, value: NSColor.black, range: NSRange(location: 0, length: attributed.length))
      if fixture.current == "office" {
        attributed.addAttribute(.ligature, value: 1, range: NSRange(location: 0, length: attributed.length))
      }

      let animatedStorage = NSTextStorage(attributedString: attributed)
      let animatedManager = StreamingFadeLayoutManager()
      let animatedContainer = NSTextContainer(size: NSSize(width: 640, height: 120))
      animatedContainer.lineFragmentPadding = 0
      animatedManager.addTextContainer(animatedContainer)
      animatedStorage.addLayoutManager(animatedManager)
      animatedManager.ensureLayout(for: animatedContainer)
      animatedManager.fade.append(previous: fixture.previous, current: fixture.current, enabled: true, at: 0)
      animatedManager.prepareDrawingSpans()

      let plainStorage = NSTextStorage(attributedString: attributed)
      let plainManager = NSLayoutManager()
      let plainContainer = NSTextContainer(size: NSSize(width: 640, height: 120))
      plainContainer.lineFragmentPadding = 0
      plainManager.addTextContainer(plainContainer)
      plainStorage.addLayoutManager(plainManager)
      plainManager.ensureLayout(for: plainContainer)

      let atDuration = render(manager: animatedManager, size: NSSize(width: 640, height: 120), frameTime: StreamingFadeState.maximumLifetime)
      animatedManager.advance(at: StreamingFadeState.maximumLifetime)
      #expect(animatedManager.fade.batches.isEmpty)
      let expired = render(manager: animatedManager, size: NSSize(width: 640, height: 120), frameTime: StreamingFadeState.maximumLifetime)
      let baseline = render(manager: plainManager, size: NSSize(width: 640, height: 120), frameTime: 0)
      #expect(pixelDifference(atDuration, baseline, xRange: 0..<640) == 0)
      #expect(pixelDifference(expired, baseline, xRange: 0..<640) == 0)
    }
  }

  @Test("dismantling a paragraph finishes its pending fade")
  func dismantleFinishesPendingFade() {
    let view = ParagraphNSView()
    view.setParagraphContents(NSMutableAttributedString(string: "Pending tail"), animatedByWord: true)
    let manager = view.layoutManager as! StreamingFadeLayoutManager
    #expect(!manager.fade.batches.isEmpty)
    ParagraphView.dismantleNSView(view, coordinator: ParagraphView.Coordinator())
    #expect(manager.fade.batches.isEmpty)
  }

  private func render(manager: NSLayoutManager, size: NSSize, frameTime: TimeInterval) -> NSBitmapImageRep {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
                                  samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                  bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    NSColor.white.setFill()
    NSRect(origin: .zero, size: size).fill()
    if let fadeManager = manager as? StreamingFadeLayoutManager {
      fadeManager.frameTime = frameTime
    }
    manager.drawGlyphs(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs), at: NSPoint(x: 16, y: 16))
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap
  }

  private func pixelDifference(_ lhs: NSBitmapImageRep, _ rhs: NSBitmapImageRep, xRange: Range<Int>) -> Int {
    guard let left = lhs.bitmapData, let right = rhs.bitmapData else { return .max }
    var difference = 0
    for y in 0..<lhs.pixelsHigh {
      for x in xRange {
        let offset = y * lhs.bytesPerRow + x * 4
        for component in 0..<4 {
          difference += abs(Int(left[offset + component]) - Int(right[offset + component]))
        }
      }
    }
    return difference
  }
}
#endif
