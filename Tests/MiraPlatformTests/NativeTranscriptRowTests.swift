import AppKit
import Foundation
import SwiftUI
import MarkdownView
import Testing
import MiraCore

@MainActor
@Suite("Native transcript rows", .serialized)
struct NativeTranscriptRowTests {
    @Test func disclosureAffordanceTracksHoverAndAvailableWidth() throws {
        _ = NSApplication.shared
        let button = MiraHoverDisclosureButton(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        button.font = .systemFont(ofSize: 13)
        button.attributedTitle = NSAttributedString(string: "Thinking", attributes: [.font: button.font!])
        #expect(!button.showsChevron)
        #expect(!button.textOverflows)
        #expect(button.chevronFrame.minX == button.attributedTitle.size().width + 8)
        #expect(button.symbolSize == button.font?.pointSize)
        let event = try #require(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
            trackingNumber: 0, userData: nil))
        button.mouseEntered(with: event)
        #expect(button.showsChevron)
        button.attributedTitle = NSAttributedString(string: String(repeating: "Thinking about the source ", count: 8),
            attributes: [.font: button.font!])
        #expect(button.textOverflows)
        #expect(button.chevronFrame.maxX == button.bounds.maxX - 2)
        button.isExpanded = true
        #expect(button.showsChevron)
        button.mouseExited(with: event)
        #expect(!button.showsChevron)
    }

    @Test func toolJSONStaysCompactAndFailureTintSurvivesExpansion() throws {
        _ = NSApplication.shared
        let row = NativeTranscriptRow(frame: .zero)
        let attempt = UUID()
        let json = "\r\n\t" + #"{ "text" : "a b \"quoted\"", "number" : 12345678901234567890, "items" : [ 1, 2 ] }"#
        let compact = #"{"text":"a b \"quoted\"","number":12345678901234567890,"items":[1,2]}"#
        func descendants<T: NSView>(_ view: NSView, as type: T.Type) -> [T] {
            view.subviews.flatMap { child in (child as? T).map { [$0] } ?? descendants(child, as: type) }
        }
        for status: SessionToolActivityStatus in [.succeeded, .failed] {
            let item = TranscriptItem(id: "tool", role: .assistant, text: "", status: .completed, isStreaming: false,
                steps: [.init(id: attempt, stepIndex: 0, blocks: [
                    .init(id: "tool", content: .tool(.init(id: UUID(), toolName: "fixture.read", status: status,
                        arguments: .available(json), result: .available(json))))
                ])])
            for expanded in [false, true] {
                row.configure(item: item, body: nil, reasoning: nil, expanded: true, theme: theme(),
                    locale: Locale(identifier: "en"), reduceMotion: true, measurement: false,
                    auxiliary: AnyView(EmptyView()), expandedBlocks: expanded ? [attempt.uuidString + ":tool"] : [], remember: { _ in })
                row.frame = NSRect(x: 0, y: 0, width: 360, height: row.fittingHeight(width: 360))
                row.layoutSubtreeIfNeeded()
                let button = try #require(descendants(row, as: MiraHoverDisclosureButton.self).first {
                    $0.accessibilityIdentifier().hasPrefix("conversation.process.")
                })
                #expect(button.isExpanded == expanded)
                #expect(button.image?.tiffRepresentation == NSImage(systemSymbolName: status == .failed ? "xmark.circle.fill" : "wrench.fill", accessibilityDescription: nil)?.tiffRepresentation)
                let color = button.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
                #expect(color?.usingColorSpace(.sRGB) == NSColor(status == .failed ? MiraTheme.Colors.failure : MiraTheme.Colors.secondaryText).usingColorSpace(.sRGB))
                if expanded {
                    let sections = descendants(row, as: NSScrollView.self).filter { $0.accessibilityIdentifier() == "conversation.toolIO" }
                    #expect(sections.count == 2)
                    for section in sections {
                        let field = try #require(section.documentView as? NSTextField)
                        #expect(field.stringValue == compact)
                        #expect(field.maximumNumberOfLines == 1)
                        #expect(section.hasHorizontalScroller)
                        #expect(!section.hasVerticalScroller)
                        #expect(field.frame.width > section.contentView.bounds.width)
                        #expect(section.frame.height <= 20)
                    }
                }
            }
        }
    }

    @Test func runningReasoningHasOneSummaryAndHidesItWhenExpanded() throws {
        _ = NSApplication.shared
        let row = NativeTranscriptRow(frame: .zero)
        let attempt = UUID()
        let item = TranscriptItem(id: "turn", role: .assistant, text: "", status: nil, isStreaming: true,
            outputPhase: .thinking, steps: [.init(id: attempt, stepIndex: 0, blocks: [
                .init(id: "thought", content: .thinking(.available("First line\nLatest line")))
            ])], liveAttemptID: attempt)
        func update(expanded: Bool) {
            row.configure(item: item, body: nil, reasoning: nil, expanded: false, theme: theme(),
                locale: Locale(identifier: "en"), reduceMotion: true, measurement: false,
                auxiliary: AnyView(EmptyView()), expandedBlocks: expanded ? [attempt.uuidString + ":thought"] : [],
                remember: { _ in })
            row.frame = NSRect(x: 0, y: 0, width: 360, height: row.fittingHeight(width: 360))
            row.layoutSubtreeIfNeeded()
        }
        func buttons(in view: NSView) -> [NSButton] {
            view.subviews.flatMap { child in
                (child as? NSButton).map { [$0] } ?? buttons(in: child)
            }
        }
        update(expanded: false)
        let visible = buttons(in: row).filter { !$0.isHidden }
        #expect(visible.count == 1)
        #expect(visible.first?.attributedTitle.string.contains("Latest line") == true)
        update(expanded: true)
        #expect(buttons(in: row).filter { !$0.isHidden }.allSatisfy { !$0.attributedTitle.string.contains("Latest line") })
        #expect(markdownViews(in: row).filter { $0.textLabelView.attributedText.string.contains("Latest line") }.count == 1)
        #expect(markdownViews(in: row).contains { $0.textLabelView.attributedText.string.contains("First line") })
    }

    @Test func longToolInputScrollsWithoutPushingOutputOutOfTheCard() throws {
        _ = NSApplication.shared
        let row = NativeTranscriptRow(frame: .zero)
        let attempt = UUID()
        let input = String(repeating: "Long synthetic input line\n", count: 100)
        let item = TranscriptItem(id: "turn", role: .assistant, text: "", status: .completed, isStreaming: false,
            steps: [.init(id: attempt, stepIndex: 0, blocks: [
                .init(id: "tool", content: .tool(.init(id: UUID(), toolName: "fixture.read", status: .succeeded,
                    arguments: .available(input), result: .available("Short result"))))
            ])])
        row.configure(item: item, body: nil, reasoning: nil, expanded: true, theme: theme(),
            locale: Locale(identifier: "en"), reduceMotion: true, measurement: false,
            auxiliary: AnyView(EmptyView()), expandedBlocks: [attempt.uuidString + ":tool"], remember: { _ in })
        row.frame = NSRect(x: 0, y: 0, width: 360, height: row.fittingHeight(width: 360))
        row.layoutSubtreeIfNeeded()
        func scrolls(in view: NSView) -> [NSScrollView] {
            view.subviews.flatMap { child in (child as? NSScrollView).map { [$0] } ?? scrolls(in: child) }
        }
        let sections = scrolls(in: row).filter { $0.accessibilityIdentifier() == "conversation.toolIO" }
        #expect(sections.count == 2)
        #expect(sections.allSatisfy { $0.frame.height <= 126 })
        let inputSection = try #require(sections.first { ($0.documentView as? NSTextField)?.stringValue == input })
        #expect((inputSection.documentView?.frame.height ?? 0) > inputSection.frame.height)
        #expect(sections.contains { ($0.documentView as? NSTextField)?.stringValue == "Short result" })
        #expect(row.frame.height < 400)
    }

    @Test("activity changes from thinking to answering before the turn finishes")
    func activityHeaderTracksPhaseAndPreservesExpandedThinking() throws {
        _ = NSApplication.shared
        let theme = theme()
        let row = NativeTranscriptRow(frame: .zero)
        let locale = Locale(identifier: "en")
        var item = TranscriptItem(id: "answer", role: .assistant, text: "", status: nil, isStreaming: true,
                                  thinking: "First thought.\nLatest thought.", outputPhase: .thinking)
        func update(_ value: TranscriptItem) {
            row.configure(item: value, body: MarkdownContent(markdown: value.text, theme: theme),
                          reasoning: MarkdownContent(markdown: value.thinking, theme: theme), expanded: true,
                          theme: theme, locale: locale, reduceMotion: true, measurement: false,
                          auxiliary: AnyView(EmptyView()), remember: { _ in })
            row.frame = NSRect(x: 0, y: 0, width: 420, height: row.fittingHeight(width: 420))
            row.layoutSubtreeIfNeeded()
        }
        update(item)
        let activity = try #require(row.subviews.compactMap { $0 as? NSButton }.first)
        #expect(activity.accessibilityLabel() == "Thinking…")
        #expect(!activity.attributedTitle.string.contains("Latest thought."))
        item.outputPhase = .answering
        update(item)
        #expect(activity.accessibilityLabel() == "Answering…")
        #expect(markdownViews(in: row).contains { !$0.isHidden && $0.textLabelView.attributedText.string.contains("First thought.") })
        #expect(!activity.attributedTitle.string.contains("Mira"))
        row.clearContent()
        #expect(activity.attributedTitle.string.isEmpty)
        #expect(activity.toolTip == nil)
    }

    @Test("tool and terminal states replace branding and clear private previews")
    func activitySummariesAreSemanticAndBounded() {
        let tool = SessionToolActivity(id: UUID(), toolName: "knowledge.search", status: .running,
                                      arguments: .available("Finding a source"), result: .absent)
        var item = TranscriptItem(id: "answer", role: .assistant, text: "", status: nil, isStreaming: true,
                                  thinking: "Earlier reasoning", executionPhase: .waitingForTools,
                                  steps: [.init(id: UUID(), stepIndex: 0, blocks: [.init(id: "tool", content: .tool(tool))])])
        #expect(item.activityTitle == "Running tools…")
        #expect(item.activityPreview == "knowledge.search · Finding a source")
        item.executionPhase = .waitingForUser
        #expect(item.activityTitle == "Waiting for approval")
        #expect(TranscriptItem.latestLine(String(repeating: "a", count: 300) + " latest").hasSuffix(" latest"))
        #expect(TranscriptItem.latestLine(String(repeating: "a", count: 300)).count == 240)
        let stopped = TranscriptItem(id: "answer", role: .assistant, text: "Partial", status: .cancelled, isStreaming: false)
        #expect(stopped.activityTitle == "Stopped")
    }
    @Test("row measurement stays finite and responds to multiline content")
    func measurementIsFiniteAtNarrowAndWideWidths() {
        _ = NSApplication.shared
        let row = NativeTranscriptRow(frame: .zero)
        let theme = theme()
        let source = String(repeating: "A paragraph with enough words to wrap across several lines in a narrow transcript column. ", count: 4)

        configure(row, id: "answer", text: source, theme: theme)

        let narrow = row.fittingHeight(width: 180)
        let wide = row.fittingHeight(width: 640)

        #expect(narrow.isFinite)
        #expect(wide.isFinite)
        #expect(narrow > wide)

        configure(row, id: "answer", text: "Short.", theme: theme)
        let short = row.fittingHeight(width: 640)
        #expect(short.isFinite)
        #expect(wide > short)
    }

    @Test("expanded tool activity participates in native row measurement")
    func toolDetailsExpandAndCollapseAtMinimumWidth() {
        _ = NSApplication.shared
        let row = NativeTranscriptRow(frame: .zero)
        let theme = theme()
        let item = TranscriptItem(id: "tools", role: .assistant, text: "Answer", status: .completed,
                                  isStreaming: false, steps: [.init(id: UUID(), stepIndex: 0, blocks: (0..<8).map { index in
            .init(id: "tool-\(index)", content: .tool(.init(id: UUID(), toolName: "knowledge.search", status: .succeeded,
                  arguments: .available("{\"query\":\"source \(index)\"}"),
                  result: .available("Synthetic result \(index): a retained local source preview."))))
        })])
        func height(expanded: Bool) -> CGFloat {
            row.configure(item: item, body: MarkdownContent(markdown: item.text, theme: theme), reasoning: nil,
                          expanded: expanded, theme: theme, locale: Locale(identifier: "en"), reduceMotion: true,
                          measurement: false, auxiliary: AnyView(EmptyView()), remember: { _ in })
            return row.fittingHeight(width: 360)
        }
        let closed = height(expanded: false)
        let opened = height(expanded: true)
        #expect(opened.isFinite && opened > closed + 150)
        #expect(height(expanded: false) == closed)
    }

    @Test("assistant measurement matches the displayed row without measuring a fixed header")
    func measuredAndDisplayedAssistantHeightsAgree() {
        _ = NSApplication.shared
        let measured = NativeTranscriptRow(frame: .zero)
        let displayed = NativeTranscriptRow(frame: .zero)
        let source = "## A heading\n\nA synthetic paragraph with enough words to wrap in a narrow conversation."
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let theme = theme(appearance)
            configure(measured, id: "answer", text: source, theme: theme, measurement: true)
            configure(displayed, id: "answer", text: source, theme: theme)
            for width: CGFloat in [360, 640, 900] {
                #expect(abs(measured.fittingHeight(width: width) - displayed.fittingHeight(width: width)) < 1)
            }
        }
    }

    @Test("same-ID updates preserve an answer selection")
    func sameIDConfigurationPreservesSelection() throws {
        _ = NSApplication.shared
        let row = NativeTranscriptRow(frame: .zero)
        let theme = theme()
        configure(row, id: "answer", text: "Stable prefix", theme: theme)
        let answer = try #require(renderedMarkdownView(in: row))

        answer.textLabelView.selectionRange = NSRange(location: 0, length: 6)
        configure(row, id: "answer", text: "Stable prefix and an appended tail", theme: theme)

        #expect(renderedMarkdownView(in: row) === answer)
        #expect(answer.textLabelView.selectionRange == NSRange(location: 0, length: 6))
    }

    @Test("status-only completion preserves the mounted markdown view")
    func statusOnlyCompletionPreservesMountedMarkdownView() throws {
        _ = NSApplication.shared
        let row = NativeTranscriptRow(frame: .zero)
        let theme = theme()
        let locale = Locale(identifier: "en")
        let source = "Stable prefix with a streamed final word"
        let body = MarkdownContent(markdown: source, theme: theme, locale: locale)
        let streamingItem = TranscriptItem(id: "answer", role: .assistant, text: source, status: nil,
                                           isStreaming: true)
        let completedItem = TranscriptItem(id: "answer", role: .assistant, text: source,
                                           status: .completed, isStreaming: false)
        func update(_ item: TranscriptItem) {
            row.configure(item: item, body: body, reasoning: nil, expanded: false,
                          theme: theme, locale: locale, reduceMotion: false, measurement: false,
                          auxiliary: AnyView(EmptyView()), remember: { _ in })
        }
        update(streamingItem)
        let answer = try #require(renderedMarkdownView(in: row))
        answer.textLabelView.selectionRange = NSRange(location: 0, length: 6)
        update(completedItem)

        #expect(renderedMarkdownView(in: row) === answer)
        #expect(answer.textLabelView.selectionRange == NSRange(location: 0, length: 6))
    }

    @Test("different-ID reuse clears the previous answer selection")
    func differentIDConfigurationClearsSelection() throws {
        _ = NSApplication.shared
        let row = NativeTranscriptRow(frame: .zero)
        let theme = theme()
        configure(row, id: "first", text: "First answer", theme: theme)
        let answer = try #require(renderedMarkdownView(in: row))
        answer.textLabelView.selectionRange = NSRange(location: 0, length: 5)

        configure(row, id: "second", text: "Second answer", theme: theme)

        #expect(renderedMarkdownView(in: row) === answer)
        #expect(answer.textLabelView.selectionRange == nil)
    }

    @Test("purging a row removes the previous private markdown")
    func purgingClearsRenderedMarkdown() throws {
        _ = NSApplication.shared
        let row = NativeTranscriptRow(frame: .zero)
        let theme = theme()
        let privateText = "Private answer that must be forgotten"
        configure(row, id: "answer", text: privateText, theme: theme)
        let answer = try #require(renderedMarkdownView(in: row))
        #expect(answer.textLabelView.attributedText.string.contains(privateText))

        configure(row, id: "answer", text: "", bodyPurged: true, theme: theme)

        #expect(markdownViews(in: row).allSatisfy { !$0.textLabelView.attributedText.string.contains(privateText) })
        #expect(answer.textLabelView.attributedText.string.isEmpty)
    }

    @Test("ordered process stays visible while running and settles around the same final body")
    func orderedProcessPreservesFinalBodyAndIndependentDisclosures() throws {
        _ = NSApplication.shared
        let row = NativeTranscriptRow(frame: .zero)
        let theme = theme()
        let first = UUID(), last = UUID()
        let steps: [SessionActivityStep] = [
            .init(id: first, stepIndex: 0, blocks: [
                .init(id: "thinking", content: .thinking(.available("First reasoning"))),
                .init(id: "text", content: .text(.available("Intermediate message"))),
                .init(id: "tool", content: .tool(.init(id: UUID(), toolName: "fixture.read", status: .succeeded,
                    arguments: .available("{\"source\":\"alpha\"}"), result: .available("Full result"))))
            ]),
            .init(id: last, stepIndex: 1, blocks: [
                .init(id: "thinking", content: .thinking(.available("Final reasoning"))),
                .init(id: "text", content: .text(.available("Final answer")))
            ])
        ]
        func update(streaming: Bool, expanded: Bool, blocks: Set<String> = []) {
            let item = TranscriptItem(id: "ordered", role: .assistant, text: "Final answer",
                status: streaming ? nil : .completed, isStreaming: streaming, outputPhase: .answering,
                steps: steps, liveAttemptID: streaming ? last : nil)
            row.configure(item: item, body: nil, reasoning: nil, expanded: expanded, theme: theme,
                locale: Locale(identifier: "en"), reduceMotion: true, measurement: false,
                auxiliary: AnyView(EmptyView()), expandedBlocks: blocks, remember: { _ in })
            row.frame = NSRect(x: 0, y: 0, width: 360, height: row.fittingHeight(width: 360))
            row.layoutSubtreeIfNeeded()
        }
        update(streaming: true, expanded: false)
        #expect(row.subviews.compactMap { $0 as? NSButton }.first?.isHidden == true)
        let final = try #require(markdownViews(in: row).first { $0.textLabelView.attributedText.string.contains("Final answer") })
        #expect(markdownViews(in: row).contains { $0.textLabelView.attributedText.string.contains("Intermediate message") })
        final.textLabelView.selectionRange = NSRange(location: 0, length: 5)
        update(streaming: false, expanded: false)
        #expect(markdownViews(in: row).contains { $0 === final })
        #expect(final.textLabelView.selectionRange == NSRange(location: 0, length: 5))
        #expect(!markdownViews(in: row).contains { $0.textLabelView.attributedText.string.contains("Intermediate message") })
        update(streaming: false, expanded: true, blocks: [first.uuidString + ":thinking", first.uuidString + ":tool"])
        #expect(markdownViews(in: row).contains { $0.textLabelView.attributedText.string.contains("First reasoning") })
        func fields(in view: NSView) -> [NSTextField] {
            view.subviews.flatMap { child in (child as? NSTextField).map { [$0] } ?? fields(in: child) }
        }
        #expect(fields(in: row).contains { $0.stringValue == "Full result" && $0.isSelectable })
        #expect(fields(in: row).contains { $0.stringValue.contains("\"source\"") && $0.stringValue.contains("\"alpha\"") && $0.isSelectable })
        #expect(!markdownViews(in: row).contains { $0.textLabelView.attributedText.string.contains("Final reasoning") })
        update(streaming: false, expanded: true, blocks: [last.uuidString + ":thinking"])
        #expect(markdownViews(in: row).contains { $0.textLabelView.attributedText.string.contains("Final reasoning") })
        update(streaming: false, expanded: false, blocks: [last.uuidString + ":thinking"])
        #expect(!markdownViews(in: row).contains { $0.textLabelView.attributedText.string.contains("Final reasoning") })
        #expect(markdownViews(in: row).contains { $0 === final })
        #expect(row.fittingHeight(width: 360).isFinite)
        row.clearContent()
        #expect(!markdownViews(in: row).contains { $0.textLabelView.attributedText.string.contains("First reasoning") })
    }

    private func configure(
        _ row: NativeTranscriptRow,
        id: String,
        text: String,
        bodyPurged: Bool = false,
        theme: MarkdownTheme,
        measurement: Bool = false
    ) {
        let locale = Locale(identifier: "en")
        let item = TranscriptItem(
            id: id,
            role: .assistant,
            text: text,
            status: .completed,
            isStreaming: false,
            isBodyPurged: bodyPurged
        )
        let body = bodyPurged ? nil : MarkdownContent(markdown: text, theme: theme, locale: locale)
        row.configure(
            item: item,
            body: body,
            reasoning: nil,
            expanded: false,
            theme: theme,
            locale: locale,
            reduceMotion: false,
            measurement: measurement,
            auxiliary: AnyView(EmptyView()),
            remember: { _ in }
        )
    }

    private func theme(_ name: NSAppearance.Name = .aqua) -> MarkdownTheme {
        MiraMarkdownStyle.theme(for: NSAppearance(named: name) ?? NSAppearance(named: .aqua)!)
    }

    private func markdownViews(in view: NSView) -> [MiraMarkdownView] {
        view.subviews.flatMap { child in
            let direct = child as? MiraMarkdownView
            return (direct.map { [$0] } ?? []) + markdownViews(in: child)
        }
    }

    private func renderedMarkdownView(in row: NativeTranscriptRow) -> MiraMarkdownView? {
        markdownViews(in: row).first { !$0.textLabelView.attributedText.string.isEmpty }
    }
}
