//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//

#if canImport(AppKit)
import AppKit
import iosMath
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers

private struct CachedParagraphNSViewSize {
  let size: CGSize
  let targetWidth: CGFloat
  let contentRevision: Int
}

class ParagraphNSView: NSTextView {
  private static let jsonEncoder = JSONEncoder()

  private(set) var paragraphContents: NSMutableAttributedString = NSMutableAttributedString()
  private(set) var lineSpacing: CGFloat?
  private var fadeAnimationDisplayLink: CADisplayLink?
  private var fadeManager: StreamingFadeLayoutManager? { layoutManager as? StreamingFadeLayoutManager }
  private var lastLayoutWidth: CGFloat?
  private var sizeCache: [CachedParagraphNSViewSize] = []
  private var contentRevision = 0
  #if DEBUG
  private(set) var debugMeasurementCount = 0
  #endif

  var textContextMenu: TextContextMenu?
  var markdownController: MarkdownController?

  var onUrlTap: (URL) -> Void = { NSWorkspace.shared.open($0) }

  convenience init() {
    let textStorage = NSTextStorage()
    let layoutManager = StreamingFadeLayoutManager()
    textStorage.addLayoutManager(layoutManager)
    let textContainer = NSTextContainer(containerSize: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
    textContainer.widthTracksTextView = true
    textContainer.heightTracksTextView = false
    layoutManager.addTextContainer(textContainer)
    self.init(frame: .zero, textContainer: textContainer)
  }

  override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
    super.init(frame: frameRect, textContainer: container)
    setupView()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setupView()
  }

  deinit {
    tearDownDisplayLink()
  }

  // MARK: - Appearance

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    AppAppearance.update(appearance: effectiveAppearance)
  }

  // MARK: - Intrinsic Content Size

  override var intrinsicContentSize: NSSize {
    let targetWidth = measurementWidth
    return measureSize(fittingWidth: targetWidth)
  }

  private var measurementWidth: CGFloat {
    var width = bounds.width
    if width <= 0 || !width.isFinite {
      width = NSScreen.main?.frame.width ?? 800
    }
    return width
  }

  /// Measures the size required to lay out the current content within `width`.
  ///
  /// Uses a dedicated, throwaway layout stack instead of the view's own text container.
  /// The display container has `widthTracksTextView = true`, so its width follows the
  /// view's frame width regardless of any `containerSize` we set. When the view is
  /// measured before it has been given a frame (e.g. mid navigation transition) that
  /// tracked width is `0`, which yields a zero height and collapses the paragraph. A
  /// standalone container whose width we set directly always measures correctly.
  func measureSize(fittingWidth width: CGFloat) -> CGSize {
    if width.isFinite,
       let cachedSize = sizeCache.first(where: {
         $0.targetWidth == width && $0.contentRevision == contentRevision
       }) {
      return cachedSize.size
    }

    #if DEBUG
    debugMeasurementCount += 1
    #endif
    guard let textStorage, textStorage.length > 0, width > 0, width.isFinite else {
      return cacheMeasurement(.zero, for: width)
    }
    let measuringTextStorage = NSTextStorage(attributedString: textStorage)
    let measuringLayoutManager = NSLayoutManager()
    let measuringContainer = NSTextContainer(size: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude))
    measuringContainer.lineFragmentPadding = 0
    measuringContainer.maximumNumberOfLines = 0
    measuringContainer.lineBreakMode = .byWordWrapping
    measuringLayoutManager.addTextContainer(measuringContainer)
    measuringTextStorage.addLayoutManager(measuringLayoutManager)
    measuringLayoutManager.ensureLayout(for: measuringContainer)
    let usedRect = measuringLayoutManager.usedRect(for: measuringContainer)
    return cacheMeasurement(
      CGSize(width: usedRect.width.rounded(.up), height: usedRect.height.rounded(.up)),
      for: width
    )
  }

  private func cacheMeasurement(_ size: CGSize, for width: CGFloat) -> CGSize {
    guard width.isFinite else { return size }
    let measurement = CachedParagraphNSViewSize(
      size: size,
      targetWidth: width,
      contentRevision: contentRevision
    )
    sizeCache.removeAll {
      $0.targetWidth == width && $0.contentRevision == contentRevision
    }
    sizeCache.insert(measurement, at: 0)
    if sizeCache.count > 4 {
      sizeCache.removeLast()
    }
    return size
  }

  override func layout() {
    super.layout()
    let width = measurementWidth
    if lastLayoutWidth != width {
      // Measurement proposals may differ from the final frame. Comparing against the
      // last proposal would invalidate forever even when the actual frame is stable.
      lastLayoutWidth = width
      invalidateIntrinsicContentSize()
    }
    startStreamingFadeIfVisible()
  }

  // MARK: - Content Update

  func setParagraphContents(_ newContents: NSMutableAttributedString, lineSpacing: CGFloat? = nil, animatedByWord: Bool) {
    AppAppearance.update(appearance: effectiveAppearance)

    if !animatedByWord { finishStreamingFade() }
    guard paragraphContents != newContents || self.lineSpacing != lineSpacing else { return }
    let previousText = paragraphContents.string
    self.paragraphContents = newContents
    self.lineSpacing = lineSpacing
    contentRevision += 1
    sizeCache.removeAll(keepingCapacity: true)

    let finalString: NSMutableAttributedString
    if lineSpacing != nil {
      finalString = applyLineSpacing(to: newContents, lineSpacing: lineSpacing)
    } else {
      finalString = newContents
    }

    textStorage?.setAttributedString(finalString)

    configureAccessibility(for: finalString)

    invalidateIntrinsicContentSize()

    let time = CACurrentMediaTime()
    fadeManager?.frameTime = time
    fadeManager?.fade.append(previous: previousText, current: finalString.string, enabled: animatedByWord, at: time)
    fadeManager?.prepareDrawingSpans()
    // Evicted batches must be fully visible even if the provider sends a burst.
    needsDisplay = true
    startStreamingFadeIfVisible()
  }

  // MARK: - Line Spacing

  private func applyLineSpacing(to attributedString: NSMutableAttributedString, lineSpacing: CGFloat?) -> NSMutableAttributedString {
    let result = NSMutableAttributedString(attributedString: attributedString)
    if let lineSpacing {
      let paragraphStyle = NSMutableParagraphStyle()
      paragraphStyle.lineSpacing = lineSpacing
      paragraphStyle.alignment = .left
      result.addAttribute(.paragraphStyle, value: paragraphStyle, range: NSRange(location: 0, length: result.length))
    }
    return result
  }

  // MARK: - View Setup

  private func setupView() {
    if NSTextAttachment.textAttachmentViewProviderClass(forFileType: UTType.data.identifier) == nil {
      NSTextAttachment.registerViewProviderClass(LatexViewProvider.self, forFileType: UTType.data.identifier)
    }

    isEditable = false
    isSelectable = true
    drawsBackground = false
    textContainer?.lineFragmentPadding = 0
    textContainer?.widthTracksTextView = true
    textContainer?.heightTracksTextView = false
    textContainer?.maximumNumberOfLines = 0
    textContainer?.lineBreakMode = .byWordWrapping

    isVerticallyResizable = true
    isHorizontallyResizable = false

    linkTextAttributes = [:]

    setContentHuggingPriority(.defaultHigh, for: .vertical)
    setContentCompressionResistancePriority(.defaultHigh, for: .vertical)
    setContentHuggingPriority(.defaultLow, for: .horizontal)
    setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
  }

  // MARK: - Accessibility

  private func generateAccessibilityContent(from attributedString: NSAttributedString) -> (label: String?, actions: [() -> Void])? {
    var labelComponents: [String] = []
    var hasAttachments = false
    let fullRange = NSRange(location: 0, length: attributedString.length)

    attributedString.enumerateAttributes(in: fullRange, options: []) { attrs, range, _ in
      if let attachment = attrs[.attachment] as? InlineCitationAttachment,
         let citationData = attachment.citationData {
        labelComponents.append(citationData.accessibilityLabel)
        hasAttachments = true
      } else {
        let text = attributedString.attributedSubstring(from: range).string
        if !text.isEmpty {
          labelComponents.append(text)
        }
      }
    }

    guard hasAttachments else { return nil }
    let label = labelComponents.isEmpty ? nil : labelComponents.joined()
    return (label: label, actions: [])
  }

  private func configureAccessibility(for attributedString: NSAttributedString) {
    if let content = generateAccessibilityContent(from: attributedString) {
      setAccessibilityLabel(content.label)
    } else {
      setAccessibilityLabel(attributedString.string)
    }
  }

  // MARK: - Display-only Streaming Animation

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window == nil { finishStreamingFade() }
    else { startStreamingFadeIfVisible() }
  }

  private func startStreamingFadeIfVisible() {
    guard let manager = fadeManager, !manager.fade.batches.isEmpty, window != nil else { return }
    guard !isHiddenOrHasHiddenAncestor, !hasTextSelection else {
      finishStreamingFade()
      return
    }
    // Window attachment can precede the first layout. Wait for visible geometry;
    // the next layout expires stale batches before creating a display link.
    guard !visibleRect.isEmpty, fadeAnimationDisplayLink == nil else { return }
    manager.advance(at: CACurrentMediaTime())
    guard !manager.fade.batches.isEmpty else { return }
    let link = displayLink(target: StreamingFadeDisplayTarget(view: self), selector: #selector(StreamingFadeDisplayTarget.tick))
    link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
    link.add(to: .main, forMode: .common)
    fadeAnimationDisplayLink = link
  }

  func advanceStreamingFade(at time: TimeInterval) {
    guard let manager = fadeManager else { return }
    // Redraw the old ranges once at full opacity before retiring them.
    manager.advance(at: time)
    if manager.fade.batches.isEmpty { tearDownDisplayLink() }
    if window == nil || visibleRect.isEmpty || isHiddenOrHasHiddenAncestor || hasTextSelection {
      finishStreamingFade()
    }
  }

  func finishStreamingFade() {
    tearDownDisplayLink()
    fadeManager?.finish()
  }

  private var hasTextSelection: Bool {
    selectedRanges.contains { $0.rangeValue.length > 0 }
  }

  private func tearDownDisplayLink() {
    fadeAnimationDisplayLink?.invalidate()
    fadeAnimationDisplayLink = nil
  }

  func setTextContextMenu(_ menu: TextContextMenu?) {
    textContextMenu = menu
  }

  func setMarkdownController(_ controller: MarkdownController?) {
    markdownController = controller
  }

  // MARK: - Link Clicks

  // swiftlint:disable:next no_any
  override func clicked(onLink link: Any, at charIndex: Int) {
    if let url = link as? URL {
      onUrlTap(url)
    } else if let string = link as? String, let url = URL.fromMixedEncodingString(string) {
      onUrlTap(url)
    }
  }

  // MARK: - Context Menu

  override func menu(for event: NSEvent) -> NSMenu? {
    guard let textContextMenu, let textStorage else {
      return super.menu(for: event)
    }

    let selectedRange = self.selectedRange()
    let clampedRange = NSIntersectionRange(selectedRange, NSRange(location: 0, length: textStorage.length))
    let selectedText = textStorage.attributedSubstring(from: clampedRange).string

    // Start from the native context menu so system items (Copy, Look Up,
    // Translate, Share, Services, …) are preserved, then inject the configured
    // groups at the top, above the system items.
    let menu = super.menu(for: event) ?? NSMenu()

    var injected: [NSMenuItem] = []
    // The built-in "Select more text" group (when enabled) is prepended by
    // `MarkdownRenderConfig.resolvedTextContextMenu`, so it renders first.
    for group in textContextMenu.menuGroups {
      if group.displayInline {
        for item in group.items {
          injected.append(makeMenuItem(for: item, selectedText: selectedText))
        }
      } else {
        let submenu = NSMenu(title: group.title ?? "")
        for item in group.items {
          submenu.addItem(makeMenuItem(for: item, selectedText: selectedText))
        }
        let submenuItem = NSMenuItem(title: group.title ?? "", action: nil, keyEquivalent: "")
        submenuItem.submenu = submenu
        injected.append(submenuItem)
      }
      injected.append(.separator())
    }

    // Insert the block in order at the top; its trailing separator divides it
    // from the native items (Copy, …) that follow.
    var insertAt = 0
    for item in injected {
      menu.insertItem(item, at: insertAt)
      insertAt += 1
    }

    // Notify controller of menu appearance (excluding the built-in item)
    if let markdownController {
      for group in textContextMenu.menuGroups {
        for item in group.items where item.id != TextSelectionConfig.selectMoreItemID {
          markdownController.onContextMenuAppear(id: item.id, selectedContent: selectedText)
        }
      }
    }

    return menu
  }

  private func makeMenuItem(for item: TextContextMenuItem, selectedText: String) -> NSMenuItem {
    if item.id == TextSelectionConfig.selectMoreItemID {
      let menuItem = NSMenuItem(title: item.title, action: #selector(selectMoreTextTapped), keyEquivalent: "")
      menuItem.target = self
      return menuItem
    }
    let menuItem = NSMenuItem(title: item.title, action: #selector(contextMenuItemTapped(_:)), keyEquivalent: "")
    menuItem.representedObject = ContextMenuAction(id: item.id, selectedText: selectedText)
    menuItem.target = self
    return menuItem
  }

  @objc private func selectMoreTextTapped() {
    markdownController?.requestTextSelection()
  }

  @objc private func contextMenuItemTapped(_ sender: NSMenuItem) {
    guard let action = sender.representedObject as? ContextMenuAction else { return }
    markdownController?.onContextMenuTap(id: action.id, selectedContent: action.selectedText)
  }
}

// MARK: - Context Menu Action Helper

private struct ContextMenuAction {
  let id: String
  let selectedText: String
}

#endif
