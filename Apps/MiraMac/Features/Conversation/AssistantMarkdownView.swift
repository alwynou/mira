import AppKit
import Observation
import SwiftUI
import SwiftStreamingMarkdown
import MiraCore

struct TranscriptItem: Identifiable, Equatable {
    let id: String
    let role: MessageRole
    let text: String
    let status: MessageStatus?
    let isStreaming: Bool
    var message: Message? = nil
    var bodyPurgedAt: Date? = nil
    var executionID: ExecutionID? = nil
    var trace: [CanonicalMessage] = []
    var memoryNotices: [MemoryContextNotice] = []
}

struct MessageRow: View {
    let role: MessageRole
    let text: String
    let status: MessageStatus?

    var body: some View {
        HStack {
            Spacer(minLength: 48)
            VStack(alignment: .leading, spacing: MiraTheme.Spacing.sm) {
                if let status, status != .committed {
                    Text("Incomplete").font(MiraTheme.Typography.caption).foregroundStyle(.orange)
                }
                Text(verbatim: text)
                    .font(MiraTheme.Typography.body)
                    .textSelection(.enabled)
                    .lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, MiraTheme.Spacing.lg)
            .padding(.vertical, MiraTheme.Spacing.md)
            .background(MiraTheme.Colors.inset, in: .rect(cornerRadius: MiraTheme.Radius.panel))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("You")
    }
}

struct AssistantMarkdownRow: View, Equatable {
    let text: String
    let status: MessageStatus?
    let isStreaming: Bool
    var trace: [CanonicalMessage] = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.text == rhs.text && lhs.status == rhs.status && lhs.isStreaming == rhs.isStreaming && lhs.trace == rhs.trace
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            MiraBrandMark().frame(width: 28, height: 24)
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    Text("Mira").font(MiraTheme.Typography.body.weight(.semibold))
                    if let status, status != .committed { Text("Incomplete").font(.caption).foregroundStyle(.orange) }
                }
                if trace.contains(where: { $0.reasoning != nil }) {
                    ThinkingDisclosure(trace: trace, isStreaming: isStreaming)
                }
                if text.isEmpty {
                    if !isStreaming { Text("No answer was produced.").foregroundStyle(.secondary) }
                    else if !trace.contains(where: { $0.reasoning != nil }) { Text("Waiting for response…").foregroundStyle(.secondary) }
                } else {
                    // Snapshots are coalesced before Observation invalidates the transcript.
                    // Stable rows retain the renderer and never replay entrance animations.
                    MarkdownView(text: text, config: MiraMarkdownStyle.reply, animatesTextUpdates: isStreaming && !reduceMotion)
                        .equatable()
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
    }

}

private struct ThinkingDisclosure: View {
    let trace: [CanonicalMessage]
    let isStreaming: Bool
    @State private var isExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.locale) private var locale

    init(trace: [CanonicalMessage], isStreaming: Bool) {
        self.trace = trace
        self.isStreaming = isStreaming
        #if DEBUG
        _isExpanded = State(initialValue: NativePerformanceBenchmark.isRequested
                            && ProcessInfo.processInfo.arguments.contains("--benchmark-expand-thinking"))
        #endif
    }

    private var isThinking: Bool { isStreaming && trace.last?.reasoning?.isComplete == false }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            // Collapsed thinking must not join, parse, or lay out its potentially large trace.
            if isExpanded {
                let text = trace.compactMap { $0.reasoning?.text }.filter { !$0.isEmpty }.joined(separator: "\n\n")
                if text.isEmpty {
                    Text("The model did not provide visible thinking text.").font(.caption).foregroundStyle(.secondary)
                } else {
                    MarkdownView(text: text, config: MiraMarkdownStyle.thinking,
                                 animatesTextUpdates: isThinking && !reduceMotion)
                        .equatable()
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
        } label: {
            HStack(spacing: 6) {
                if isThinking { ProgressView().controlSize(.mini) }
                Label(L10n.string(isThinking ? "Thinking…" : "Thinking", locale: locale), systemImage: "brain")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

/// Style through the renderer's public configuration; parsing and streaming stay native.
private enum MiraMarkdownStyle {
    static let reply = make(citations: .init(isEnabled: false, font: .systemFont(ofSize: 12), textColor: .secondary, backgroundColor: .clear))
    static let thinking = make(citations: .default)

    private static func make(citations: MarkdownRenderConfig.CitationConfig) -> MarkdownRenderConfig {
        let heading = MarkdownRenderConfig.defaultHeadingStyle
        let inline = MarkdownRenderConfig.defaultInlineStyle
        return MarkdownRenderConfig(
            shouldAnimateText: false,
            blockQuoteStyle: .init(textFonts: MarkdownRenderConfig.defaultBlockQuoteStyle.textFonts,
                                   textColor: MiraTheme.Colors.secondaryText),
            headingStyle: .init(h1Font: heading.h1Font, h2Font: heading.h2Font, h3Font: heading.h3Font,
                                h4Font: heading.h4Font, h5Font: heading.h5Font, h6Font: heading.h6Font,
                                textColor: MiraTheme.Colors.text),
            orderedListStyle: .init(textFonts: MarkdownRenderConfig.defaultOrderedListStyle.textFonts,
                                    textColor: MiraTheme.Colors.text),
            paragraphStyle: .init(textFonts: MarkdownRenderConfig.defaultParagraphStyle.textFonts,
                                  textColor: MiraTheme.Colors.text),
            tableStyle: .init(textFonts: MarkdownRenderConfig.defaultTableStyle.textFonts,
                              headerTextColor: MiraTheme.Colors.text, regularTextColor: MiraTheme.Colors.text,
                              headerBackgroundColor: MiraTheme.Colors.inset, borderColor: MiraTheme.Colors.border,
                              actionButtonColor: MiraTheme.Colors.accent),
            inlineStyle: .init(boldTextColor: MiraTheme.Colors.text, linkTextFont: inline.linkTextFont,
                               linkTextColor: MiraTheme.Colors.text, linkUnderlineStyle: .single,
                               codeTextFont: inline.codeTextFont, codeTextColor: MiraTheme.Colors.text,
                               codeBackgroundColor: MiraTheme.Colors.inset, codeUnderlineColor: .clear),
            citationConfig: citations,
            codeBlockConfig: .init(theme: .github, backgroundColor: MiraTheme.Colors.inset,
                                    foregroundColor: MiraTheme.Colors.secondaryText),
            thematicBreakColor: MiraTheme.Colors.border,
            imageConfig: .disabled
        )
    }
}
