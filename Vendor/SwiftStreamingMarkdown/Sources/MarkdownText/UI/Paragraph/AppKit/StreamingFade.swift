// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License. Mira's incremental drawing extension.

import Foundation

/// Only the recent appended tail participates in animation, regardless of reply size.
struct StreamingFadeState {
  struct Batch {
    let range: NSRange
    let start: TimeInterval
  }

  static let duration = ParagraphAnimationConstants.fadeInDuration
  static let wordStagger = ParagraphAnimationConstants.delayBetweenWordsRatio
  static let maximumLifetime = duration + wordStagger
  static let maximumBatches = 8
  static let maximumAnimatedLength = 2048
  private(set) var batches: [Batch] = []

  mutating func append(previous: String, current: String, enabled: Bool, at time: TimeInterval) {
    advance(at: time)
    guard enabled, current.utf16.starts(with: previous.utf16) else { finish(); return }
    let oldLength = (previous as NSString).length
    let newText = current as NSString
    guard newText.length > oldLength else { return }
    let limit = max(0, newText.length - Self.maximumAnimatedLength)
    // Align the retained tail forward so even a large composed cluster cannot
    // extend the animation budget. Normal provider chunks can split a cluster.
    let cluster = newText.rangeOfComposedCharacterSequence(at: limit)
    let lowerBound = cluster.location < limit ? NSMaxRange(cluster) : limit
    guard lowerBound < newText.length else { finish(); return }
    var range = newText.rangeOfComposedCharacterSequences(for:
      NSRange(location: max(oldLength, lowerBound), length: newText.length - max(oldLength, lowerBound)))
    range = NSIntersectionRange(range, NSRange(location: lowerBound, length: newText.length - lowerBound))
    // A changed grapheme replaces its earlier batch instead of overlapping it.
    batches = batches.compactMap { batch in
      guard NSMaxRange(batch.range) <= range.location else { return nil }
      let clipped = NSIntersectionRange(batch.range, NSRange(location: lowerBound, length: newText.length - lowerBound))
      return clipped.length > 0 ? Batch(range: clipped, start: batch.start) : nil
    }
    batches.append(Batch(range: range, start: time))
    if batches.count > Self.maximumBatches { batches.removeFirst(batches.count - Self.maximumBatches) }
  }

  mutating func advance(at time: TimeInterval) {
    batches.removeAll { time >= $0.start + Self.maximumLifetime }
  }

  mutating func finish() { batches.removeAll(keepingCapacity: true) }

  static func opacity(start: TimeInterval, at time: TimeInterval) -> CGFloat {
    let progress = min(1, max(0, (time - start) / duration))
    return paragraphEaseOut(CGFloat(progress))
  }
}

#if canImport(AppKit)
import AppKit
import QuartzCore

/// Alpha is applied while drawing glyphs. Animation never edits text storage,
/// regenerates attributed strings, or invalidates paragraph measurement.
final class StreamingFadeLayoutManager: NSLayoutManager {
  var fade = StreamingFadeState()
  var frameTime: TimeInterval = 0
  private struct DrawingSpan {
    let glyphs: NSRange
    let start: TimeInterval
  }
  private var drawingSpans: [DrawingSpan] = []
  private static let maximumGroupsPerBatch = 16
  private static let maximumDrawingSpans = 128

  /// Resolve characters to glyphs once per text update, never on animation frames.
  /// Attachments retain their native drawing and are excluded from the fade.
  func prepareDrawingSpans() {
    drawingSpans.removeAll(keepingCapacity: true)
    guard let textStorage else { return }
    for batch in fade.batches {
      let range = NSIntersectionRange(batch.range, NSRange(location: 0, length: textStorage.length))
      guard range.length > 0 else { continue }
      // Match upstream's word-by-word timing while limiting the number of draw
      // operations for unusually large provider packets. Word splitting is never
      // performed on a display-link frame.
      let words = textStorage.splitIntoWords(withIn: range)
      let stride = max(1, Int(ceil(Double(words.count) / Double(Self.maximumGroupsPerBatch))))
      let groupCount = max(1, Int(ceil(Double(words.count) / Double(stride))))
      for offset in Swift.stride(from: 0, to: words.count, by: stride) {
        let first = words[offset]
        let last = words[min(offset + stride, words.count) - 1]
        let group = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
        let start = batch.start + Double(offset / stride) * StreamingFadeState.wordStagger / Double(groupCount)
        textStorage.enumerateAttribute(.attachment, in: group) { attachment, part, _ in
          guard attachment == nil else { return }
          let glyphs = self.glyphRange(forCharacterRange: part, actualCharacterRange: nil)
          self.insertDrawingSpan(glyphs: glyphs, start: start)
        }
      }
    }
  }

  private func insertDrawingSpan(glyphs: NSRange, start: TimeInterval) {
    guard glyphs.length > 0 else { return }
    // A ligature can belong to adjacent character batches. Draw it once, using
    // the newest batch's start time, instead of blending it twice.
    drawingSpans = drawingSpans.flatMap { existing -> [DrawingSpan] in
      guard NSIntersectionRange(existing.glyphs, glyphs).length > 0 else { return [existing] }
      var pieces: [DrawingSpan] = []
      if existing.glyphs.location < glyphs.location {
        pieces.append(DrawingSpan(glyphs: NSRange(location: existing.glyphs.location,
          length: glyphs.location - existing.glyphs.location), start: existing.start))
      }
      if NSMaxRange(existing.glyphs) > NSMaxRange(glyphs) {
        pieces.append(DrawingSpan(glyphs: NSRange(location: NSMaxRange(glyphs),
          length: NSMaxRange(existing.glyphs) - NSMaxRange(glyphs)), start: existing.start))
      }
      return pieces
    }
    drawingSpans.append(DrawingSpan(glyphs: glyphs, start: start))
    drawingSpans.sort { $0.glyphs.location < $1.glyphs.location }
    if drawingSpans.count > Self.maximumDrawingSpans {
      drawingSpans.removeFirst(drawingSpans.count - Self.maximumDrawingSpans)
    }
  }

  func advance(at time: TimeInterval) {
    frameTime = time
    redrawAnimatedTail()
    fade.advance(at: time)
    drawingSpans.removeAll { time >= $0.start + StreamingFadeState.duration }
  }

  func finish() {
    redrawAnimatedTail()
    fade.finish()
    drawingSpans.removeAll(keepingCapacity: true)
  }

  override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
    guard !drawingSpans.isEmpty, let context = NSGraphicsContext.current?.cgContext else {
      super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
      return
    }
    var cursor = glyphsToShow.location
    let end = NSMaxRange(glyphsToShow)
    for span in drawingSpans {
      let mapped = span.glyphs
      let lower = max(cursor, mapped.location)
      let upper = min(end, NSMaxRange(mapped))
      guard upper > lower else { continue }
      if lower > cursor { super.drawGlyphs(forGlyphRange: NSRange(location: cursor, length: lower - cursor), at: origin) }
      context.saveGState()
      context.setAlpha(StreamingFadeState.opacity(start: span.start, at: frameTime))
      super.drawGlyphs(forGlyphRange: NSRange(location: lower, length: upper - lower), at: origin)
      context.restoreGState()
      cursor = upper
    }
    if cursor < end { super.drawGlyphs(forGlyphRange: NSRange(location: cursor, length: end - cursor), at: origin) }
  }

  func redrawAnimatedTail() {
    guard let first = fade.batches.first, let last = fade.batches.last else { return }
    invalidateDisplay(forCharacterRange: NSRange(location: first.range.location, length: NSMaxRange(last.range) - first.range.location))
  }
}

/// CADisplayLink retains its target; the proxy breaks the link back to the text view.
final class StreamingFadeDisplayTarget: NSObject {
  weak var view: ParagraphNSView?
  init(view: ParagraphNSView) { self.view = view }
  @objc func tick(_ link: CADisplayLink) { view?.advanceStreamingFade(at: link.targetTimestamp) }
}
#endif
