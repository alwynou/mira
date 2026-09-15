import AppKit
import Litext
import MarkdownView
import Testing

@MainActor
@Suite("Mira Markdown renderer")
struct MiraMarkdownViewTests {
    private func theme(_ name: NSAppearance.Name = .aqua) -> MarkdownTheme {
        MiraMarkdownStyle.theme(for: NSAppearance(named: name) ?? NSAppearance(named: .aqua)!)
    }

    private func content(_ source: String, theme: MarkdownTheme, locale: Locale = Locale(identifier: "en")) -> MarkdownContent {
        MarkdownContent(markdown: source, theme: theme, locale: locale)
    }

    private func renderedBitmap(_ view: MiraMarkdownView, width: CGFloat) -> Data? {
        let height = max(1, view.fittingHeight(width: width).rounded(.up))
        view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap.tiffRepresentation
    }

    private func advanceFadeClockWithoutTimers() {
        // Keep drawing callbacks installed to verify their fully opaque glyphs.
        Thread.sleep(forTimeInterval: 0.7)
    }

    private func textLabels(in view: NSView) -> [TextLabelView] {
        var labels: [TextLabelView] = []
        if let label = view as? TextLabelView {
            labels.append(label)
        }
        for child in view.subviews {
            labels.append(contentsOf: textLabels(in: child))
        }
        return labels
    }

    private func buttons(in view: NSView) -> [NSButton] {
        var result: [NSButton] = []
        if let button = view as? NSButton {
            result.append(button)
        }
        for child in view.subviews {
            result.append(contentsOf: buttons(in: child))
        }
        return result
    }

    @Test("undrawable formula images fall back to verbatim LaTeX before native drawing",
          arguments: [false, true])
    func undrawableMathFallsBack(inTable: Bool) throws {
        _ = NSApplication.shared
        let theme = theme()
        let source = inTable ? "| Formula |\n| --- |\n| $x^2$ |" : "Before $x^2$ after."
        let parsed = content(source, theme: theme)
        #expect(!parsed.rendered.isEmpty)
        for size in [CGSize.zero, CGSize(width: 20, height: 0), CGSize(width: 20, height: 20)] {
            // Positive dimensions without representations also fail CGImage conversion.
            let image = NSImage(size: size)
            image.isTemplate = true
            #expect(image.cgImage(forProposedRect: nil, context: nil, hints: nil) == nil)
            let injected = MarkdownContent(
                blocks: parsed.blocks,
                rendered: parsed.rendered.mapValues { RenderedTextContent(image: image, text: $0.text) },
                highlightMaps: parsed.highlightMaps, locale: parsed.locale
            )
            let view = MiraMarkdownView()
            view.apply(content: injected, source: source, theme: theme,
                       locale: parsed.locale, isStreaming: false, reduceMotion: false)
            _ = try #require(renderedBitmap(view, width: 320))
            #expect(textLabels(in: view).contains { $0.attributedText.string.contains("x^2") })
            #expect(injected.rendered.values.allSatisfy { $0.image === image })
            // Repeated layout/draw and reuse must never reinstall the unsafe image.
            _ = try #require(renderedBitmap(view, width: 720))
            view.prepareForReuse()
            view.apply(content: injected, source: source, theme: theme,
                       locale: parsed.locale, isStreaming: false, reduceMotion: false)
            _ = try #require(renderedBitmap(view, width: 320))
        }
    }

    @Test("empty formula geometry from SwiftMath safely draws as text")
    func zeroHeightFormula() throws {
        _ = NSApplication.shared
        let theme = theme()
        let source = #"Before $\quad$ after."#
        let parsed = content(source, theme: theme)
        let image = try #require(parsed.rendered.values.first?.image)
        #expect(image.size.height == 0)
        let view = MiraMarkdownView()
        view.apply(content: parsed, source: source, theme: theme,
                   locale: parsed.locale, isStreaming: false, reduceMotion: false)
        _ = try #require(renderedBitmap(view, width: 320))
        #expect(view.textLabelView.attributedText.string.contains(#"\quad"#))
    }

    @Test("normal formulas survive redraw, streaming, appearance, locale, and selection",
          arguments: [false, true])
    func drawableMathRemainsVisible(dark: Bool) throws {
        _ = NSApplication.shared
        let theme = theme(dark ? .darkAqua : .aqua)
        let locale = Locale(identifier: dark ? "zh-Hans" : "en")
        let view = MiraMarkdownView()
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let prefix = "Stable prefix."
        let source = prefix + #" Formula $\frac{a}{b} + x^2$ and $\quad$ tail."#
            + "\n\n| Formula |\n| --- |\n| $y^2$ |\n\n```swift\nlet value = 1\n```"
        view.apply(content: content(prefix, theme: theme), source: prefix, theme: theme,
                   locale: locale, isStreaming: false, reduceMotion: false)
        view.textLabelView.selectionRange = NSRange(location: 0, length: 6)
        let parsed = content(source, theme: theme, locale: locale)
        view.apply(content: parsed, source: source, theme: theme,
                   locale: locale, isStreaming: true, reduceMotion: false)
        #expect(view.textLabelView.selectionRange == NSRange(location: 0, length: 6))
        for width: CGFloat in [320, 720, 320] {
            _ = try #require(renderedBitmap(view, width: width))
            // A normal formula still has a drawing action, not the raw-text fallback.
            let actions = textLabels(in: view).flatMap { $0.layoutRuns(matching: .litextLineDrawingAction) }
            #expect(!actions.isEmpty)
            #expect(!view.textLabelView.attributedText.string.contains(#"\frac"#))
            #expect(view.textLabelView.attributedText.string.contains(#"\quad"#))
        }
        // Upstream's unkeyed notification synchronously rebuilds stored content.
        // This is its pinned notification contract, rather than a timing assumption.
        NotificationCenter.default.post(
            name: Notification.Name("wiki.qaq.MarkdownView.CodeHighlighter.highlightDidUpdate"), object: nil
        )
        _ = try #require(renderedBitmap(view, width: 320))
        view.apply(content: parsed, source: source, theme: theme,
                   locale: locale, isStreaming: false, reduceMotion: false)
        _ = try #require(renderedBitmap(view, width: 320))
    }

    @Test("terminal content has stable text and finite fitting height")
    func terminalContentParityAndMeasurement() {
        _ = NSApplication.shared
        let view = MiraMarkdownView()
        let theme = theme()
        let markdown = "# Heading\n\nA paragraph with **strong text** and a [safe link](https://example.com)."

        view.apply(
            content: content(markdown, theme: theme),
            source: markdown,
            theme: theme,
            locale: Locale(identifier: "en"),
            isStreaming: false,
            reduceMotion: false
        )

        #expect(view.textLabelView.attributedText.string.contains("Heading"))
        #expect(view.textLabelView.attributedText.string.contains("safe link"))
        #expect(view.fittingHeight(width: 480).isFinite)
        #expect(view.fittingHeight(width: 480) > 0)
        #expect(view.fittingHeight(width: .infinity) == 0)
    }

    @Test("unsafe links are inert while normal HTTP links remain link regions")
    func linkSchemeBoundary() {
        _ = NSApplication.shared
        let view = MiraMarkdownView()
        let theme = theme()
        let markdown = "[safe](https://example.com) [unsafe](javascript:alert(1)) [local](file:///tmp/mira)"
        view.apply(
            content: content(markdown, theme: theme), source: markdown, theme: theme,
            locale: Locale(identifier: "en"), isStreaming: false, reduceMotion: false
        )

        let rendered = view.textLabelView.attributedText
        let safeRange = (rendered.string as NSString).range(of: "safe")
        let unsafeRange = (rendered.string as NSString).range(of: "unsafe")
        let localRange = (rendered.string as NSString).range(of: "local")
        #expect(rendered.attribute(.link, at: safeRange.location, effectiveRange: nil) != nil)
        #expect(rendered.attribute(.link, at: unsafeRange.location, effectiveRange: nil) == nil)
        #expect(rendered.attribute(.link, at: localRange.location, effectiveRange: nil) == nil)
    }

    @Test("unsafe links in table cells are inert after nested layout")
    func tableLinkSchemeBoundary() throws {
        _ = NSApplication.shared
        let view = MiraMarkdownView()
        let theme = theme()
        let markdown = "| Links |\n| --- |\n| [safe](https://example.com) [unsafe](javascript:alert(1)) |"
        view.apply(
            content: content(markdown, theme: theme), source: markdown, theme: theme,
            locale: Locale(identifier: "en"), isStreaming: false, reduceMotion: false
        )
        _ = try #require(renderedBitmap(view, width: 360))

        let nestedLabels = textLabels(in: view).filter { $0 !== view.textLabelView }
        let tableLabels = nestedLabels.filter {
            $0.attributedText.string.contains("safe") || $0.attributedText.string.contains("unsafe")
        }
        let safeLabel = try #require(tableLabels.first { $0.attributedText.string.contains("safe") })
        let unsafeLabel = try #require(tableLabels.first { $0.attributedText.string.contains("unsafe") })
        let safeRange = (safeLabel.attributedText.string as NSString).range(of: "safe")
        let unsafeRange = (unsafeLabel.attributedText.string as NSString).range(of: "unsafe")
        #expect(safeLabel.attributedText.attribute(.link, at: safeRange.location, effectiveRange: nil) != nil)
        #expect(unsafeLabel.attributedText.attribute(.link, at: unsafeRange.location, effectiveRange: nil) == nil)
    }

    @Test("English code copy control keeps its localized label")
    func codeCopyControlLabel() throws {
        _ = NSApplication.shared
        let view = MiraMarkdownView()
        let theme = theme()
        let markdown = "```swift\nlet value = 1\n```"
        view.apply(
            content: content(markdown, theme: theme), source: markdown, theme: theme,
            locale: Locale(identifier: "en"), isStreaming: false, reduceMotion: false
        )
        _ = try #require(renderedBitmap(view, width: 420))

        let copyButtons = buttons(in: view).filter {
            $0.action == NSSelectorFromString("handleCopy:")
        }
        let hasEnglishLabel = copyButtons.contains {
            $0.title == "Copy" || $0.toolTip == "Copy"
        }
        #expect(!copyButtons.isEmpty)
        #expect(hasEnglishLabel)
    }

    @Test("appended streaming content preserves a stable prefix selection")
    func prefixSelectionSurvivesAppend() {
        _ = NSApplication.shared
        let view = MiraMarkdownView()
        let theme = theme()
        let first = "Stable prefix"
        let second = "Stable prefix and appended tail"

        view.apply(
            content: content(first, theme: theme), source: first, theme: theme,
            locale: Locale(identifier: "en"), isStreaming: true, reduceMotion: false
        )
        view.textLabelView.selectionRange = NSRange(location: 0, length: 6)
        view.apply(
            content: content(second, theme: theme), source: second, theme: theme,
            locale: Locale(identifier: "en"), isStreaming: true, reduceMotion: false
        )

        #expect(view.textLabelView.selectionRange == NSRange(location: 0, length: 6))
        #expect(view.textLabelView.attributedText.string.contains("appended tail"))
    }

    @Test("theme and locale changes rebuild without invalid height")
    func themeAndLocaleChanges() {
        _ = NSApplication.shared
        let view = MiraMarkdownView()
        let light = theme(.aqua)
        let dark = theme(.darkAqua)
        let markdown = "中文内容\n\n- one\n- two" // i18n-fixture: Simplified Chinese renderer and locale coverage.

        view.apply(
            content: content(markdown, theme: light, locale: Locale(identifier: "en")),
            source: markdown, theme: light, locale: Locale(identifier: "en"),
            isStreaming: false, reduceMotion: false
        )
        let lightHeight = view.fittingHeight(width: 320)
        view.apply(
            content: content(markdown, theme: dark, locale: Locale(identifier: "zh-Hans")),
            source: markdown, theme: dark, locale: Locale(identifier: "zh-Hans"),
            isStreaming: false, reduceMotion: false
        )

        #expect(view.fittingHeight(width: 320).isFinite)
        #expect(view.fittingHeight(width: 320) > 0)
        #expect(lightHeight.isFinite)
    }

    @Test("reduced motion, terminal updates, and reuse clear transient state")
    func terminalAndReuseState() {
        _ = NSApplication.shared
        let view = MiraMarkdownView()
        let theme = theme()
        let first = "Initial answer"
        let second = "Initial answer with a tail"

        view.apply(
            content: content(first, theme: theme), source: first, theme: theme,
            locale: Locale(identifier: "en"), isStreaming: false, reduceMotion: false
        )
        view.apply(
            content: content(second, theme: theme), source: second, theme: theme,
            locale: Locale(identifier: "en"), isStreaming: true, reduceMotion: false
        )
        view.apply(
            content: content(second, theme: theme), source: second, theme: theme,
            locale: Locale(identifier: "en"), isStreaming: false, reduceMotion: false
        )
        #expect(view.textLabelView.attributedText.string.contains("tail"))

        view.textLabelView.selectionRange = NSRange(location: 0, length: 4)
        view.apply(
            content: content(second, theme: theme), source: second, theme: theme,
            locale: Locale(identifier: "en"), isStreaming: true, reduceMotion: true
        )
        view.prepareForReuse()
        #expect(view.textLabelView.selectionRange == nil)
        #expect(view.fittingHeight(width: 400) == 0)
    }

    @Test("streaming mixed-script wrapping settles to canonical rendering")
    func streamingFadeSettlesWithoutContentLoss() async throws {
        _ = NSApplication.shared
        let theme = theme()
        let first = "Prefix"
        let second = "Prefix " + String(repeating: "ASCII mixed 中日韩 words ", count: 14) // i18n-fixture: Mixed-script wrapping and fallback glyph coverage.
        let view = MiraMarkdownView()
        view.apply(
            content: content(first, theme: theme), source: first, theme: theme,
            locale: Locale(identifier: "en"), isStreaming: false, reduceMotion: false
        )
        let streamedContent = content(second, theme: theme)
        view.apply(
            content: streamedContent, source: second, theme: theme,
            locale: Locale(identifier: "en"), isStreaming: true, reduceMotion: false
        )

        let initialFade = try #require(renderedBitmap(view, width: 260))
        advanceFadeClockWithoutTimers()
        let opaqueFade = try #require(renderedBitmap(view, width: 260))
        try await Task.sleep(for: .milliseconds(30))
        let settled = try #require(renderedBitmap(view, width: 260))
        let settledAgain = try #require(renderedBitmap(view, width: 260))

        let canonical = MiraMarkdownView()
        canonical.apply(
            content: content(second, theme: theme), source: second, theme: theme,
            locale: Locale(identifier: "en"), isStreaming: false, reduceMotion: false
        )
        #expect(canonical.textLabelView.attributedText.string == second.trimmingCharacters(in: .whitespacesAndNewlines) + "\n")
        let expected = try #require(renderedBitmap(canonical, width: 260))
        #expect(!initialFade.elementsEqual(expected))
        #expect(opaqueFade.elementsEqual(expected))
        #expect(settled.elementsEqual(expected))
        #expect(settledAgain.elementsEqual(expected))
        #expect(settledAgain.elementsEqual(settled))
    }

    @Test("terminal code blocks expose their complete content", arguments: [false, true])
    func terminalCodeBlockFits(dark: Bool) async throws {
        _ = NSApplication.shared
        let view = MiraMarkdownView()
        let theme = theme(dark ? .darkAqua : .aqua)
        let locale = Locale(identifier: dark ? "zh-Hans" : "en")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView?.addSubview(view)
        window.orderFront(nil)
        defer { window.close() }
        // Escaped CJK scalars are synthetic font-fallback geometry fixtures.
        let lines = (1...45).map { $0.isMultiple(of: 3) ? "" : "Line \($0): " + String(repeating: "\u{4E2D}\u{6587} example ", count: 12) }
        let whole = "Heading\n\n```\n" + lines.joined(separator: "\n") + "\n```"
        let snapshots = stride(from: 120, to: whole.count, by: 600).map { String(whole.prefix($0)) }
            + [whole, whole + "\n\nFollowing paragraph."]
        for source in snapshots {
            view.apply(content: content(source, theme: theme), source: source, theme: theme,
                       locale: locale, isStreaming: source != whole, reduceMotion: false)
            for width: CGFloat in [320, 760] {
                _ = renderedBitmap(view, width: width)
                try await Task.sleep(for: .milliseconds(100))
                _ = renderedBitmap(view, width: width)
                let key = NSAttributedString.Key("contextView")
                let run = try #require(view.textLabelView.layoutRuns(matching: key).last)
                let block = try #require(run.attributes[key] as? NSView)
                #expect(block.frame.maxY <= view.bounds.maxY + 1,
                        "Block \(block.frame) exceeds document \(view.bounds)")
                let label = try #require(textLabels(in: block).first { $0.attributedText.string.contains("Line 1:") })
                let scroll = try #require(label.enclosingScrollView)
                #expect(block.frame.height <= MiraTheme.Markdown.maximumCodeBlockHeight)
                if source.count >= whole.count {
                    #expect(block.frame.height == MiraTheme.Markdown.maximumCodeBlockHeight)
                    #expect(label.bounds.height > scroll.contentView.bounds.height)
                }
                #expect(scroll.hasVerticalScroller && scroll.hasHorizontalScroller)
                let bottom = max(-scroll.contentInsets.top,
                    label.bounds.maxY - scroll.contentView.bounds.height + scroll.contentInsets.bottom)
                scroll.contentView.scroll(to: CGPoint(x: -scroll.contentInsets.left, y: bottom))
                scroll.reflectScrolledClipView(scroll.contentView)
                let visible = label.convert(scroll.contentView.bounds, from: scroll.contentView)
                let scrollerClearance = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .overlay)
                #expect(visible.maxY - label.intrinsicContentSize.height >= scrollerClearance,
                        "Bottom \(visible) must reveal the final glyphs above the horizontal scroller")
                let horizontalScroller = try #require(scroll.horizontalScroller)
                let scrollerFrame = label.convert(horizontalScroller.bounds, from: horizontalScroller)
                #expect(scrollerFrame.minY >= label.intrinsicContentSize.height - 1,
                        "Horizontal scroller \(scrollerFrame) must not cover the final code line")
                let gutter = try #require(block.subviews.compactMap { $0 as? NSClipView }.first)
                #expect(abs(gutter.bounds.minY - (scroll.contentView.bounds.minY + scroll.contentInsets.top)) < 1)
                let right = label.bounds.maxX - scroll.contentView.bounds.width + scroll.contentInsets.right
                scroll.contentView.scroll(to: CGPoint(x: max(0, right), y: bottom))
                let rightVisible = label.convert(scroll.contentView.bounds, from: scroll.contentView)
                #expect(rightVisible.maxX >= label.bounds.maxX)
                let runs = label.layoutRuns(matching: .font)
                #expect(runs.map { NSMaxRange($0.stringRange) }.max() == label.attributedText.length)
                #expect(attachmentOverlaps(in: view).isEmpty)
            }
        }
    }

    @Test("streamed code and tables never cover following text", arguments: [false, true])
    func streamedAttachmentsKeepTheirReservedHeight(reduceMotion: Bool) async throws {
        _ = NSApplication.shared
        let view = MiraMarkdownView()
        let theme = theme()
        let locale = Locale(identifier: "en")
        let source = "Stable completed prefix.\n\n" + (1...3).map { section in
            """
            ## Section \(section)

            ```bash
            # Synthetic local example
            echo "first line"
            echo "second line"
            echo "third line"
            echo "fourth line"
            echo "fifth line"
            echo "sixth line"
            echo "seventh line"
            echo "eighth line"
            ```

            ### Text after code \(section)

            This paragraph must be below the complete code block.

            | First | Second |
            | --- | --- |
            | A wrapping synthetic table value | Other content |
            | Short | Value |

            Text after the table.

            """
        }.joined(separator: "\n\n")
        let characters = Array(source)
        for end in stride(from: 48, to: characters.count + 48, by: 48) {
            let snapshot = String(characters.prefix(min(end, characters.count)))
            view.apply(content: content(snapshot, theme: theme), source: snapshot, theme: theme,
                       locale: locale, isStreaming: true, reduceMotion: reduceMotion)
            _ = renderedBitmap(view, width: 420)
            try await Task.sleep(for: .milliseconds(60))
            _ = renderedBitmap(view, width: 420)
            let overlaps = attachmentOverlaps(in: view)
            #expect(overlaps.isEmpty, "Overlaps after streaming prefix \(end): \(overlaps)")
            if !overlaps.isEmpty { return }
        }
        try await Task.sleep(for: .milliseconds(800))
        view.apply(content: content(source, theme: theme), source: source, theme: theme,
                   locale: locale, isStreaming: false, reduceMotion: reduceMotion)
        for width: CGFloat in [420, 720, 320, 420] {
            _ = renderedBitmap(view, width: width)
            let overlaps = attachmentOverlaps(in: view)
            #expect(overlaps.isEmpty, "Terminal overlaps at width \(width): \(overlaps)")
        }
    }

    private func attachmentOverlaps(in view: MiraMarkdownView) -> [String] {
        // This upstream attribute identifies the native block occupying a text line.
        let contextKey = NSAttributedString.Key("contextView")
        let contexts = view.textLabelView.layoutRuns(matching: contextKey)
        let contextLines = Set(contexts.map(\.lineIndex))
        let lines = view.textLabelView.layoutRuns(matching: .font).filter {
            !contextLines.contains($0.lineIndex)
                && !view.textLabelView.attributedText.attributedSubstring(from: $0.stringRange)
                    .string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return contexts.flatMap { context -> [String] in
            guard let block = context.attributes[contextKey] as? NSView, !block.isHidden else { return [] }
            return lines.compactMap { line in
                let frame = CGRect(x: line.lineRect.minX,
                                   y: view.textLabelView.bounds.height - line.lineRect.maxY,
                                   width: line.lineRect.width, height: line.lineRect.height)
                    .offsetBy(dx: view.textLabelView.frame.minX, dy: view.textLabelView.frame.minY)
                guard block.frame.intersection(frame).height > 1 else { return nil }
                return "\(type(of: block)) \(block.frame) covers line \(line.lineIndex) \(frame)"
            }
        }
    }

    @Test("Reduce Motion reveals the appended snapshot immediately")
    func reduceMotionSkipsFadeDrawing() throws {
        _ = NSApplication.shared
        let theme = theme()
        let first = "Prefix"
        let second = "Prefix appended tail"
        let view = MiraMarkdownView()
        view.apply(
            content: content(first, theme: theme), source: first, theme: theme,
            locale: Locale(identifier: "en"), isStreaming: false, reduceMotion: false
        )
        let appended = content(second, theme: theme)
        view.apply(
            content: appended, source: second, theme: theme,
            locale: Locale(identifier: "en"), isStreaming: true, reduceMotion: true
        )
        let actual = try #require(renderedBitmap(view, width: 320))

        let canonical = MiraMarkdownView()
        canonical.apply(
            content: appended, source: second, theme: theme,
            locale: Locale(identifier: "en"), isStreaming: false, reduceMotion: false
        )
        let expected = try #require(renderedBitmap(canonical, width: 320))
        #expect(actual.elementsEqual(expected))
    }

    @Test("status-only completion preserves active fades and native selection")
    func statusOnlyCompletionPreservesTransientRendering() throws {
        _ = NSApplication.shared
        let theme = theme()
        let view = MiraMarkdownView()
        let first = content("Stable prefix", theme: theme)
        let streamedSource = "Stable prefix with a final streamed word\n\n```swift\nlet value = 1\n```"
        let streamed = content(streamedSource, theme: theme)

        view.apply(content: first, source: "Stable prefix", theme: theme,
                   locale: Locale(identifier: "en"), isStreaming: false, reduceMotion: false)
        view.textLabelView.selectionRange = NSRange(location: 0, length: 6)
        view.apply(content: streamed, source: streamedSource, theme: theme,
                   locale: Locale(identifier: "en"), isStreaming: true, reduceMotion: false)
        _ = try #require(renderedBitmap(view, width: 420))
        let selected = view.textLabelView.selectionRange
        let fadeKey = NSAttributedString.Key("miraMarkdownFadeRun")
        let wordRange = (view.textLabelView.attributedText.string as NSString).range(of: "word")
        let before = view.textLabelView.attributedText.attribute(fadeKey, at: wordRange.location,
                                                                 effectiveRange: nil)
        #expect(before != nil)
        let contextKey = NSAttributedString.Key("contextView")
        let attachmentsBefore = view.textLabelView.layoutRuns(matching: contextKey).compactMap {
            $0.attributes[contextKey] as? NSView
        }
        #expect(!attachmentsBefore.isEmpty)

        // Completion changes row status only; it reuses the exact parsed body.
        view.apply(content: streamed, source: streamedSource, theme: theme,
                   locale: Locale(identifier: "en"), isStreaming: false, reduceMotion: false)
        _ = try #require(renderedBitmap(view, width: 420))

        #expect(view.textLabelView.selectionRange == selected)
        #expect(view.textLabelView.attributedText.attribute(fadeKey, at: wordRange.location,
                                                           effectiveRange: nil) != nil)
        let attachmentsAfter = view.textLabelView.layoutRuns(matching: contextKey).compactMap {
            $0.attributes[contextKey] as? NSView
        }
        #expect(attachmentsAfter.count == attachmentsBefore.count)
        #expect(zip(attachmentsBefore, attachmentsAfter).allSatisfy { $0 === $1 })
    }
}
