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
    var execution: Execution? = nil
}

struct MessageRow: View {
    let role: MessageRole
    let text: String
    let status: MessageStatus?

    var body: some View {
        HStack {
            Spacer(minLength: MiraLayout.gutter)
            VStack(alignment: .leading, spacing: MiraLayout.small) {
                if let status, status != .committed {
                    Text("Incomplete").font(.caption).foregroundStyle(.orange)
                }
                Text(verbatim: text)
                    .font(.body).textSelection(.enabled).lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(MiraLayout.large)
            .background(MiraSurface.subtle, in: .rect(cornerRadius: 14))
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
    var execution: Execution? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.text == rhs.text && lhs.status == rhs.status && lhs.isStreaming == rhs.isStreaming
            && lhs.trace == rhs.trace && lhs.execution == rhs.execution
    }

    var body: some View {
        let presentation = TranscriptPresentation(text: text, trace: trace)
        VStack(alignment: .leading, spacing: MiraLayout.large) {
            ExecutionTranscript(presentation: presentation, execution: execution, isStreaming: isStreaming, status: status)
            if presentation.answer.isEmpty {
                if !isStreaming {
                    Text("No answer was produced.").font(.body).foregroundStyle(.secondary)
                }
            } else {
                // Retain the existing renderer and its bounded streaming animations.
                MarkdownView(text: presentation.answer, config: MiraMarkdownStyle.config, animatesTextUpdates: isStreaming && !reduceMotion)
                    .equatable()
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mira")
    }


}

private struct ExecutionTranscript: View {
    let presentation: TranscriptPresentation
    let execution: Execution?
    let isStreaming: Bool
    let status: MessageStatus?
    @Environment(\.locale) private var locale

    private var isActive: Bool { isStreaming && execution?.status.isTerminal != true }

    var body: some View {
        TranscriptDisclosure(title: summary, isActive: isActive) {
            VStack(alignment: .leading, spacing: MiraLayout.micro) {
                if !presentation.rounds.contains(where: { $0.thinking != nil || !$0.intermediateText.isEmpty || !$0.tools.isEmpty }) {
                    Text(isActive ? (presentation.answer.isEmpty ? "Waiting for response…" : "Generating") : "No process details were recorded.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(presentation.rounds) { round in
                    TranscriptRoundView(round: round, isActive: isActive && round.id == presentation.rounds.last?.id)
                }
            }
            .padding(.top, MiraLayout.small)
        }
        .accessibilityIdentifier("conversation.process")
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, MiraLayout.small)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var summary: String {
        if isActive {
            if !presentation.pendingTools.isEmpty { return L10n.format("Using %@", locale: locale, presentation.pendingTools.map(\.name).joined(separator: ", ")) }
            if presentation.isThinking { return L10n.string("Thinking…", locale: locale) }
            if !presentation.answer.isEmpty { return L10n.string("Generating", locale: locale) }
            return L10n.string("Preparing…", locale: locale)
        }
        if let execution {
            if execution.status == .completed {
                let seconds = Int64(max(0, execution.updatedAt.timeIntervalSince(execution.createdAt)))
                return L10n.format("Completed · %lld s", locale: locale, seconds)
            }
            return L10n.string(execution.status.displayTitle, locale: locale)
        }
        return L10n.string(status == .committed ? "Completed" : "Incomplete", locale: locale)
    }
}

private struct TranscriptRoundView: View {
    let round: TranscriptPresentation.Round
    let isActive: Bool
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: MiraLayout.micro) {
            if let thinking = round.thinking {
                TranscriptDisclosure(title: L10n.string("Thinking", locale: locale),
                                     isActive: isActive && !round.isThinkingComplete) {
                    TranscriptOutput(text: thinking.isEmpty
                                     ? L10n.string("The model did not provide visible thinking text.", locale: locale) : thinking,
                                     rendersMarkdown: true, isStreaming: isActive && !round.isThinkingComplete)
                }
            }
            if !round.intermediateText.isEmpty {
                Text(verbatim: round.intermediateText)
                    .font(.body).foregroundStyle(.primary).lineSpacing(5)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            if !round.tools.isEmpty {
                TranscriptDisclosure(title: L10n.format("Tool calls · %lld", locale: locale, Int64(round.tools.count)),
                                     isActive: isActive && round.tools.contains { !$0.hasResult }) {
                    VStack(alignment: .leading, spacing: MiraLayout.micro) {
                        ForEach(round.tools) { tool in
                            TranscriptDisclosure(title: tool.name, isActive: isActive && !tool.hasResult) {
                                if let output = tool.output {
                                    TranscriptOutput(text: output)
                                } else {
                                    Text(isActive ? "Waiting for result…" : "No result was recorded.")
                                        .font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .padding(.leading, MiraLayout.medium)
                }
            }
        }
    }
}

/// Compact transcript headers keep their chevron next to the text. DisclosureGroup
/// supplies keyboard and accessibility semantics without filled button chrome.
private struct TranscriptDisclosure<Content: View>: View {
    let title: String
    let isActive: Bool
    @ViewBuilder let content: () -> Content
    @State private var isExpanded: Bool

    init(title: String, isActive: Bool, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.isActive = isActive
        self.content = content
        #if DEBUG
        let benchmarkExpanded = NativePerformanceBenchmark.isRequested
            && ProcessInfo.processInfo.arguments.contains("--benchmark-expand-thinking")
        _isExpanded = State(initialValue: isActive || benchmarkExpanded)
        #else
        _isExpanded = State(initialValue: isActive)
        #endif
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded, content: content) {
            Text(verbatim: title).font(.footnote).foregroundStyle(.secondary)
        }
        .disclosureGroupStyle(TranscriptDisclosureStyle())
        .onChange(of: isActive) { _, active in isExpanded = active }
    }
}

private struct TranscriptDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: MiraLayout.micro) {
            Button {
                configuration.isExpanded.toggle()
            } label: {
                HStack(spacing: MiraLayout.tiny) {
                    configuration.label
                    Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityValue(configuration.isExpanded ? Text("Expanded") : Text("Collapsed"))
            if configuration.isExpanded { configuration.content }
        }
    }
}

private struct TranscriptOutput: View {
    let text: String
    var rendersMarkdown = false
    var isStreaming = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if rendersMarkdown {
                MarkdownView(text: text, config: MiraMarkdownStyle.config,
                             animatesTextUpdates: isStreaming && !reduceMotion)
                    .equatable()
            } else {
                Text(verbatim: text).font(.body).foregroundStyle(.secondary).lineSpacing(5)
            }
        }
            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(MiraLayout.medium)
            .background(MiraSurface.subtle, in: .rect(cornerRadius: 10))
    }
}

/// Style the renderer through its public configuration; rendering and streaming
/// behavior stay in the existing dependency.
@MainActor
private enum MiraMarkdownStyle {
    private static let body = fonts(size: 14, lineHeight: 24)
    private static let small = fonts(size: 12, lineHeight: 20)
    private static let heading = fonts(size: 16, weight: .semibold, lineHeight: 24)
    private static let title = fonts(size: 20, weight: .semibold, lineHeight: 28)

    static let config = MarkdownRenderConfig(
        shouldAnimateText: false,
        blockQuoteStyle: .init(textFonts: body, textColor: .secondary),
        headingStyle: .init(h1Font: title, h2Font: heading, h3Font: heading, h4Font: heading,
                            h5Font: heading, h6Font: heading, textColor: .primary),
        orderedListStyle: .init(textFonts: body, textColor: .primary),
        paragraphStyle: .init(textFonts: body, textColor: .primary),
        tableStyle: .init(textFonts: small, headerTextColor: .primary, regularTextColor: .primary,
                          headerBackgroundColor: MiraSurface.subtle, borderColor: Color(nsColor: .separatorColor),
                          actionButtonColor: .primary),
        inlineStyle: .init(boldTextColor: .primary, linkTextFont: body.normal, linkTextColor: .primary,
                           linkUnderlineStyle: .single, codeTextFont: .monospacedSystemFont(ofSize: 12, weight: .regular),
                           codeTextColor: .primary, codeBackgroundColor: MiraSurface.subtle, codeUnderlineColor: .clear),
        citationConfig: .init(isEnabled: false, font: .systemFont(ofSize: 12), textColor: .secondary, backgroundColor: .clear),
        codeBlockConfig: .init(theme: .grayscale, backgroundColor: MiraSurface.subtle, foregroundColor: .secondary,
                               codeTextFonts: fonts(size: 12, lineHeight: 20, monospaced: true), chromeTextFonts: small),
        blockSpacing: MiraLayout.large,
        thematicBreakColor: Color(nsColor: .separatorColor),
        imageConfig: .disabled
    )

    private static func fonts(size: CGFloat, weight: NSFont.Weight = .regular, lineHeight: CGFloat, monospaced: Bool = false) -> TextFonts {
        let normal: NSFont = monospaced ? .monospacedSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
        let bold: NSFont = monospaced ? .monospacedSystemFont(ofSize: size, weight: .semibold) : .systemFont(ofSize: size, weight: .semibold)
        return TextFonts(normal: normal, italic: NSFontManager.shared.convert(normal, toHaveTrait: .italicFontMask),
                         bold: bold, boldItalic: NSFontManager.shared.convert(bold, toHaveTrait: .italicFontMask),
                         preferredLetterSpacing: nil, preferredLineHeight: lineHeight)
    }
}
