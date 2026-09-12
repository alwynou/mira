import AppKit
import Foundation
import SwiftUI
import MarkdownView
import Testing

@MainActor
@Suite("Native transcript rows", .serialized)
struct NativeTranscriptRowTests {
    @Test("row measurement stays finite and responds to multiline content")
    func measurementIsFiniteAtNarrowAndWideWidths() {
        _ = NSApplication.shared
        let row = NativeTranscriptRow(frame: .zero)
        let theme = theme()
        let source = "A paragraph with enough words to wrap across several lines in a narrow transcript column."

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
            status: .committed,
            isStreaming: false,
            bodyPurgedAt: bodyPurged ? Date(timeIntervalSince1970: 1) : nil
        )
        let body = bodyPurged ? nil : MarkdownContent(markdown: text, theme: theme, locale: locale)
        row.configure(
            item: item,
            body: body,
            reasoning: nil,
            reasoningSource: "",
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
