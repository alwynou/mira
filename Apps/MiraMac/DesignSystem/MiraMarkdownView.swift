import AppKit
import Litext
import MarkdownView
import SwiftUI

/// The renderer's visual configuration is derived from Mira's shared tokens.
@MainActor
enum MiraMarkdownStyle {
    static func theme(for appearance: NSAppearance) -> MarkdownTheme {
        var theme = MarkdownTheme()
        let bodySize = MiraTheme.Markdown.body

        theme.fonts.body = NSFont.systemFont(ofSize: bodySize)
        theme.fonts.codeInline = NSFont.monospacedSystemFont(ofSize: bodySize, weight: .regular)
        theme.fonts.bold = NSFont.systemFont(ofSize: bodySize, weight: .bold)
        theme.fonts.italic = NSFont.systemFont(ofSize: bodySize).italic
        theme.fonts.code = NSFont.monospacedSystemFont(
            ofSize: MiraTheme.Markdown.code,
            weight: .regular
        )
        theme.maximumCodeBlockHeight = MiraTheme.Markdown.maximumCodeBlockHeight
        theme.fonts.largeTitle = NSFont.systemFont(ofSize: MiraTheme.Markdown.largeHeading, weight: .regular)
        theme.fonts.title = NSFont.systemFont(ofSize: MiraTheme.Markdown.heading, weight: .bold)
        theme.fonts.footnote = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)

        func color(_ value: Color) -> NSColor {
            var resolved = NSColor.clear
            appearance.performAsCurrentDrawingAppearance {
                resolved = NSColor(value)
            }
            return resolved
        }

        theme.colors.body = color(MiraTheme.Colors.text)
        theme.colors.code = color(MiraTheme.Colors.text)
        theme.colors.highlight = color(MiraTheme.Colors.text)
        theme.colors.emphasis = color(MiraTheme.Colors.text)
        theme.colors.codeBackground = color(MiraTheme.Colors.inset)
        theme.colors.selectionBackground = color(MiraTheme.Colors.selected)
            .withAlphaComponent(0.35)

        theme.spacings.paragraph = MiraTheme.Spacing.sm
        theme.spacings.headingBefore = MiraTheme.Spacing.sm
        theme.spacings.general = MiraTheme.Spacing.xs
        theme.spacings.list = MiraTheme.Spacing.xs
        theme.spacings.final = MiraTheme.Spacing.sm

        theme.table.borderColor = color(MiraTheme.Colors.border)
        theme.table.headerBackgroundColor = color(MiraTheme.Colors.inset)
        theme.table.cellBackgroundColor = color(MiraTheme.Colors.surface)
        theme.table.stripeCellBackgroundColor = color(MiraTheme.Colors.inset)
        return theme
    }
}

@MainActor
final class MiraMarkdownView: MarkdownTextView {
    var onLayoutChange: (() -> Void)?

    private static let fadeAttribute = NSAttributedString.Key("miraMarkdownFadeRun")

    private struct FadeBatch {
        let range: NSRange
        let start: TimeInterval
        let delay: TimeInterval
    }

    /// This state is deliberately small. Ranges are UTF-16 ranges because the
    /// renderer and Core Text use UTF-16 offsets; appending text never causes a
    /// previous batch to move.
    private struct FadeState {
        static let duration: TimeInterval = 0.5
        static let maximumLifetime: TimeInterval = 0.6
        static let maximumSpans = 128
        static let maximumAnimatedLength = 2_048

        var batches: [FadeBatch] = []

        mutating func append(previous: String, current: String, enabled: Bool, at now: TimeInterval) {
            guard enabled else {
                finish()
                return
            }

            advance(at: now)
            guard current.hasPrefix(previous) else {
                finish()
                return
            }

            guard current != previous else { return }

            let previousLength = (previous as NSString).length
            let currentLength = (current as NSString).length
            let appendedLength = currentLength - previousLength
            guard appendedLength > 0,
                  appendedLength <= Self.maximumAnimatedLength
            else {
                finish()
                return
            }

            let suffix = (current as NSString).substring(
                with: NSRange(location: previousLength, length: appendedLength)
            )
            let spans = Self.wordSpans(in: suffix, offset: previousLength)
            guard !spans.isEmpty else {
                finish()
                return
            }
            let groupSize = max(1, Int(ceil(Double(spans.count) / Double(Self.maximumSpans))))
            for (index, group) in stride(from: 0, to: spans.count, by: groupSize).enumerated() {
                let upper = min(spans.count, group + groupSize)
                let range = NSRange(
                    location: spans[group].location,
                    length: NSMaxRange(spans[upper - 1]) - spans[group].location
                )
                batches.append(.init(
                    range: range,
                    start: now,
                    delay: min(0.1, Double(index) * 0.02)
                ))
            }
            trim(to: currentLength)
        }

        mutating func advance(at now: TimeInterval) {
            batches.removeAll { now - $0.start >= Self.maximumLifetime }
        }

        mutating func finish() {
            batches.removeAll(keepingCapacity: true)
        }

        func opacity(for range: NSRange, at now: TimeInterval) -> CGFloat {
            guard range.length > 0 else { return 1 }
            var opacity: CGFloat = 1
            for batch in batches {
                let intersection = NSIntersectionRange(range, batch.range)
                guard intersection.length > 0 else { continue }

                let elapsed = now - batch.start
                let value = min(
                    1,
                    max(0, CGFloat((elapsed - batch.delay) / Self.duration))
                )
                opacity = min(opacity, value)
            }
            return opacity
        }

        private mutating func trim(to currentLength: Int) {
            let lowerBound = max(0, currentLength - Self.maximumAnimatedLength)
            batches = batches.compactMap { batch -> FadeBatch? in
                let upperBound = min(currentLength, NSMaxRange(batch.range))
                let location = max(lowerBound, batch.range.location)
                let length = upperBound - location
                guard length > 0 else { return nil }
                return FadeBatch(
                    range: NSRange(location: location, length: length),
                    start: batch.start,
                    delay: batch.delay
                )
            }
            if batches.count > Self.maximumSpans {
                batches.removeFirst(batches.count - Self.maximumSpans)
            }
        }

        private static func wordSpans(in text: String, offset: Int) -> [NSRange] {
            let whitespace = CharacterSet.whitespacesAndNewlines
            var starts: [Int] = []
            var position = offset
            var inWord = false
            for scalar in text.unicodeScalars {
                let isWhitespace = whitespace.contains(scalar)
                if !isWhitespace, !inWord {
                    starts.append(position)
                    inWord = true
                } else if isWhitespace {
                    inWord = false
                }
                position += scalar.utf16.count
            }
            guard !starts.isEmpty else { return [] }
            return starts.indices.map { index in
                let end = index + 1 < starts.count ? starts[index + 1] : offset + (text as NSString).length
                return NSRange(location: starts[index], length: end - starts[index])
            }
        }
    }

    private final class FadeRun: NSObject {
        weak var owner: MiraMarkdownView?
        let originalText: NSAttributedString
        let range: NSRange
        private var nextRunIndex = 0

        init(owner: MiraMarkdownView, originalText: NSAttributedString, range: NSRange) {
            self.owner = owner
            self.originalText = originalText
            self.range = range
        }

        @MainActor
        func draw(in context: CGContext, line: CTLine, lineOrigin: CGPoint) {
            guard let owner else { return }
            let now = ProcessInfo.processInfo.systemUptime
            let glyphRuns = CTLineGetGlyphRuns(line) as NSArray
            var matching: [CTRun] = []
            for index in 0 ..< glyphRuns.count {
                let run = glyphRuns[index] as! CTRun
                let attributes = CTRunGetAttributes(run) as? [NSAttributedString.Key: Any]
                if let marker = attributes?[MiraMarkdownView.fadeAttribute] as? FadeRun, marker === self {
                    matching.append(run)
                }
            }
            guard !matching.isEmpty else { return }
            // Litext invokes this action once for each matching run in line order.
            // Drawing just that run preserves fallback fonts without double alpha.
            let glyphRun = matching[nextRunIndex % matching.count]
            nextRunIndex = (nextRunIndex + 1) % matching.count
            let attributes = CTRunGetAttributes(glyphRun) as? [NSAttributedString.Key: Any]
            let alpha = owner.fadeState.opacity(for: range, at: now)
            let glyphCount = CTRunGetGlyphCount(glyphRun)
            guard glyphCount > 0,
                  let nsFont = attributes?[.font] as? NSFont,
                  let color = originalText.attribute(
                      .foregroundColor,
                      at: 0,
                      effectiveRange: nil
                  ) as? NSColor
            else { return }
            let font = nsFont as CTFont

            var glyphs = [CGGlyph](repeating: 0, count: glyphCount)
            var positions = [CGPoint](repeating: .zero, count: glyphCount)
            CTRunGetGlyphs(glyphRun, CFRangeMake(0, 0), &glyphs)
            CTRunGetPositions(glyphRun, CFRangeMake(0, 0), &positions)
            context.saveGState()
            // CTLineDraw leaves its text position at the last line. Glyph positions
            // below already include the line origin, so do not apply it twice.
            context.textPosition = .zero
            context.setAlpha(alpha)
            context.setFillColor(color.cgColor)
            for positionIndex in positions.indices {
                positions[positionIndex].x += lineOrigin.x
                positions[positionIndex].y += lineOrigin.y
            }
            CTFontDrawGlyphs(font, glyphs, positions, glyphCount, context)
            context.restoreGState()
        }
    }

    private var fadeState = FadeState()
    private var fadeTimer: Timer?
    private var previousSource = ""
    private var hasRenderedContent = false
    private var lastContent: MarkdownContent?
    private var lastTheme: MarkdownTheme?
    private var lastLocaleIdentifier: String?
    private var displayLocale = Locale(identifier: "en")
    private var isUpdatingNativeContent = false

    override init(viewProvider: ReusableViewProvider = .init()) {
        super.init(viewProvider: viewProvider)
        throttleInterval = nil
        linkHandler = Self.defaultLinkHandler
        textLabelView.setAccessibilityElement(true)
        textLabelView.setAccessibilityRole(.staticText)
    }

    private static let defaultLinkHandler: (LinkPayload, NSRange, CGPoint) -> Void = { payload, _, _ in
        let url: URL?
        switch payload {
        case let .url(value):
            url = value
        case let .string(value):
            url = URL(string: value)
        }

        guard let url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return }
        NSWorkspace.shared.open(url)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func decorate(inlineText text: NSAttributedString, theme: MarkdownTheme) -> NSAttributedString {
        let safe = NSMutableAttributedString(attributedString: text)
        return Self.applyPresentationPolicy(in: safe) ? safe : text
    }

    func apply(
        content: MarkdownContent,
        source: String,
        theme: MarkdownTheme,
        locale: Locale,
        isStreaming: Bool,
        reduceMotion: Bool
    ) {
        displayLocale = locale
        let previousSelection = textLabelView.selectionRange
        let previousRenderedString = textLabelView.attributedText.string
        let oldSource = previousSource
        let sameConfiguration = lastContent === content
            && lastTheme == theme
            && lastLocaleIdentifier == locale.identifier

        let shouldAnimate = isStreaming && !reduceMotion && hasRenderedContent
        if sameConfiguration {
            if shouldAnimate {
                fadeState.advance(at: ProcessInfo.processInfo.systemUptime)
                startFadeTimerIfNeeded()
            } else if reduceMotion {
                // Reduce Motion is an explicit request to remove transient
                // drawing state immediately, including on a status-only update.
                finishFades()
            }
            // A terminal status update can arrive while the final streamed
            // words are still fading. Keep the current document, attachments,
            // selection, and timer alive so completion does not flash the row.
            previousSource = source
            return
        }

        if !shouldAnimate { fadeState.finish() }
        setContentImmediately(Self.preparingMathImages(in: content), theme: theme)
        let rendered = NSMutableAttributedString(attributedString: textLabelView.attributedText)
        let strippedUnsafeLinks = Self.applyPresentationPolicy(in: rendered)
        var installedFade = false
        if shouldAnimate {
            let currentRenderedString = rendered.string
            // MarkdownView adds a synthetic terminal newline to every paragraph.
            // A continuing paragraph replaces that separator with appended text.
            let previousPrefix: String
            if !currentRenderedString.hasPrefix(previousRenderedString), previousRenderedString.hasSuffix("\n") {
                previousPrefix = String(previousRenderedString.dropLast())
            } else { previousPrefix = previousRenderedString }
            fadeState.append(
                previous: previousPrefix,
                current: currentRenderedString,
                enabled: true,
                at: ProcessInfo.processInfo.systemUptime
            )
            installedFade = Self.installFadeAttributes(
                in: rendered,
                owner: self,
                state: fadeState
            )
        }
        if strippedUnsafeLinks || installedFade {
            textLabelView.attributedText = rendered
            needsLayout = true
        }
        textLabelView.setAccessibilityValue(source)
        lastContent = content
        lastTheme = theme
        lastLocaleIdentifier = locale.identifier
        hasRenderedContent = true
        previousSource = source

        if let previousSelection,
           source == oldSource || source.hasPrefix(oldSource),
           let preserved = MiraMarkdownView.preservedSelection(
               previousSelection,
               oldText: previousRenderedString,
               newText: textLabelView.attributedText.string
           ) {
            textLabelView.selectionRange = preserved
        } else if previousSelection != nil {
            textLabelView.selectionRange = nil
        }

        if fadeState.batches.isEmpty {
            fadeTimer?.invalidate()
            fadeTimer = nil
        } else {
            startFadeTimerIfNeeded()
        }
        invalidateIntrinsicContentSize()
        onLayoutChange?()
    }

    private static func preparingMathImages(in content: MarkdownContent) -> MarkdownContent {
        guard !content.rendered.isEmpty else { return content }
        let rendered = content.rendered.mapValues { item -> RenderedTextContent in
            guard let image = item.image else { return item }
            let size = image.size
            // SwiftMath supplies lazily drawn NSImages. An existing image can
            // still have empty geometry or fail to produce pixels. MarkdownView
            // asserts if that conversion fails inside its line drawing callback.
            guard size.width.isFinite, size.height.isFinite,
                  size.width > 0, size.height > 0,
                  let bitmap = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            else {
                return RenderedTextContent(image: nil, text: item.text)
            }
            // Resolve once before layout/drawing and retain an immutable bitmap,
            // including through upstream table and async highlight rebuilds.
            let drawable = NSImage(cgImage: bitmap, size: size)
            drawable.isTemplate = true
            return RenderedTextContent(image: drawable, text: item.text)
        }
        return MarkdownContent(
            blocks: content.blocks, rendered: rendered,
            highlightMaps: content.highlightMaps, locale: content.locale
        )
    }

    override func prepareForReuse() {
        finishFades()
        super.prepareForReuse()
        super.reset()
        textLabelView.selectionRange = nil
        previousSource = ""
        textLabelView.setAccessibilityValue("")
        hasRenderedContent = false
        lastContent = nil
        lastTheme = nil
        lastLocaleIdentifier = nil
    }

    func fittingHeight(width: CGFloat) -> CGFloat {
        guard width.isFinite, width > 0 else { return 0 }
        let height = boundingSize(for: width).height
        return height.isFinite ? max(0, height) : 0
    }

    override func layout() {
        guard !isUpdatingNativeContent else { return }
        isUpdatingNativeContent = true
        defer { isUpdatingNativeContent = false }
        // Normalize the document before upstream positions its native blocks.
        // Highlight completions can rebuild the document outside apply().
        let document = NSMutableAttributedString(attributedString: textLabelView.attributedText)
        if Self.applyPresentationPolicy(in: document) { textLabelView.attributedText = document }
        super.layout()
        updateNativeContent(in: self)
    }

    private func updateNativeContent(in view: NSView) {
        if let scroll = view as? NSScrollView, scroll.accessibilityIdentifier() == "markdown.codeBlock" {
            scroll.setAccessibilityIdentifier("conversation.codeBlock")
        }
        if let label = view as? TextLabelView {
            let safe = NSMutableAttributedString(attributedString: label.attributedText)
            // Native code/table controls own their text metrics. Only enforce links here.
            if Self.applyLinkPolicy(in: safe) { label.attributedText = safe }
        }
        if let button = view as? NSButton, button.action == NSSelectorFromString("handleCopy:") {
            let title = L10n.string("Copy", locale: displayLocale)
            button.setAccessibilityLabel(title)
            button.toolTip = title
        }
        for child in view.subviews { updateNativeContent(in: child) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            finishFades()
        }
    }

    @MainActor
    private final class FadeTimerTarget: NSObject {
        weak var owner: MiraMarkdownView?
        init(owner: MiraMarkdownView) { self.owner = owner }
        @objc func tick(_ timer: Timer) {
            guard let owner else { timer.invalidate(); return }
            if owner.textLabelView.selectionRange != nil {
                owner.finishFades()
                return
            }
            owner.fadeState.advance(at: ProcessInfo.processInfo.systemUptime)
            owner.textLabelView.needsDisplay = true
            if owner.fadeState.batches.isEmpty {
                owner.finishFades()
            }
        }
    }

    private func startFadeTimerIfNeeded() {
        guard fadeTimer == nil, !fadeState.batches.isEmpty else { return }
        let target = FadeTimerTarget(owner: self)
        let timer = Timer(timeInterval: 1.0 / 60.0, target: target,
                          selector: #selector(FadeTimerTarget.tick(_:)), userInfo: nil, repeats: true)
        fadeTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func finishFades() {
        fadeState.finish()
        fadeTimer?.invalidate()
        fadeTimer = nil
        let current = NSMutableAttributedString(attributedString: textLabelView.attributedText)
        var runs: [(NSRange, FadeRun)] = []
        current.enumerateAttribute(Self.fadeAttribute, in: NSRange(location: 0, length: current.length)) { value, range, _ in
            if let marker = value as? FadeRun { runs.append((range, marker)) }
        }
        for (range, marker) in runs {
            current.removeAttribute(Self.fadeAttribute, range: range)
            current.removeAttribute(.litextLineDrawingAction, range: range)
            if let color = marker.originalText.attribute(.foregroundColor, at: 0, effectiveRange: nil) {
                current.addAttribute(.foregroundColor, value: color, range: range)
            } else {
                current.removeAttribute(.foregroundColor, range: range)
            }
        }
        // An asynchronous upstream rebuild may have replaced all fade markers.
        // Never restore an older document or its attachment reservations over it.
        if !runs.isEmpty {
            let selection = textLabelView.selectionRange
            textLabelView.attributedText = current
            textLabelView.selectionRange = selection
            needsLayout = true
        }
        textLabelView.needsDisplay = true
    }

    private static func installFadeAttributes(
        in document: NSMutableAttributedString,
        owner: MiraMarkdownView,
        state: FadeState
    ) -> Bool {
        var installed = false
        for batch in state.batches {
            document.enumerateAttribute(.litextAttachment, in: batch.range, options: []) { value, range, _ in
                if value != nil { return }
                let original = document.attributedSubstring(from: range)
                var attributeRanges: [NSRange] = []
                original.enumerateAttributes(
                    in: NSRange(location: 0, length: original.length),
                    options: []
                ) { attributes, subrange, _ in
                    guard attributes[.litextLineDrawingAction] == nil, attributes[.link] == nil else { return }
                    attributeRanges.append(NSRange(
                        location: range.location + subrange.location,
                        length: subrange.length
                    ))
                }
                for subrange in attributeRanges {
                    let original = document.attributedSubstring(from: subrange)
                    guard original.length > 0 else { continue }
                    let marker = FadeRun(owner: owner, originalText: original, range: subrange)
                    let action = TextLabel.LineDrawingAction { [weak marker] context, line, lineOrigin in
                        MainActor.assumeIsolated {
                            marker?.draw(in: context, line: line, lineOrigin: lineOrigin)
                        }
                    }
                    document.addAttribute(Self.fadeAttribute, value: marker, range: subrange)
                    document.addAttribute(.foregroundColor, value: NSColor.clear, range: subrange)
                    document.addAttribute(.litextLineDrawingAction, value: action, range: subrange)
                    installed = true
                }
            }
        }
        return installed
    }

    private static func applyPresentationPolicy(in document: NSMutableAttributedString) -> Bool {
        let linksChanged = applyLinkPolicy(in: document)
        var paragraphs: [(NSRange, NSParagraphStyle)] = []
        document.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: document.length)) { value, range, _ in
            guard let style = value as? NSParagraphStyle, style.lineSpacing > MiraTheme.Markdown.lineSpacing,
                  let compact = style.mutableCopy() as? NSMutableParagraphStyle else { return }
            compact.lineSpacing = MiraTheme.Markdown.lineSpacing
            paragraphs.append((range, compact))
        }
        for (range, style) in paragraphs { document.addAttribute(.paragraphStyle, value: style, range: range) }
        return linksChanged || !paragraphs.isEmpty
    }

    private static func applyLinkPolicy(in document: NSMutableAttributedString) -> Bool {
        var unsafeRanges: [NSRange] = []
        var linkRanges: [NSRange] = []
        document.enumerateAttribute(.link, in: NSRange(location: 0, length: document.length), options: []) { value, range, _ in
            guard let value else { return }
            let url: URL?
            if let value = value as? URL {
                url = value
            } else if let value = value as? String {
                url = URL(string: value)
            } else {
                url = nil
            }
            guard let scheme = url?.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
                unsafeRanges.append(range)
                return
            }
            if document.attribute(.underlineStyle, at: range.location, effectiveRange: nil) as? Int != NSUnderlineStyle.single.rawValue {
                linkRanges.append(range)
            }
        }
        for range in linkRanges {
            document.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        }
        for range in unsafeRanges {
            document.removeAttribute(.link, range: range)
        }
        return !unsafeRanges.isEmpty || !linkRanges.isEmpty
    }

    private static func preservedSelection(
        _ selection: NSRange,
        oldText: String,
        newText: String
    ) -> NSRange? {
        let commonLength = commonPrefixLength(oldText, newText)
        guard NSMaxRange(selection) <= commonLength else { return nil }
        return selection
    }

    private static func commonPrefixLength(_ lhs: String, _ rhs: String) -> Int {
        let left = Array(lhs.utf16)
        let right = Array(rhs.utf16)
        var index = 0
        while index < left.count, index < right.count, left[index] == right[index] {
            index += 1
        }
        return index
    }

}
