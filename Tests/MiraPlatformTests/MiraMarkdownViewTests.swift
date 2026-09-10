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
}
