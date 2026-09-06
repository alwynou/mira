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
}

struct MessageRow: View {
    let role: MessageRole
    let text: String
    let status: MessageStatus?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "person.crop.circle")
                .font(.title3).foregroundStyle(Color.secondary).frame(width: 28)
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    Text("You").font(.callout.weight(.semibold))
                    if let status, status != .committed { Text("Incomplete").font(.caption).foregroundStyle(.orange) }
                }
                Text(verbatim: text).textSelection(.enabled).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.accessibilityElement(children: .contain)
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
            Image(systemName: "sparkle").font(.title3).foregroundStyle(Color.accentColor).frame(width: 28)
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    Text("Mira").font(.callout.weight(.semibold))
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
                    MarkdownView(text: text, config: Self.markdownConfig, animatesTextUpdates: isStreaming && !reduceMotion)
                        .equatable()
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
    }

    private static let markdownConfig = MarkdownRenderConfig(
        shouldAnimateText: false,
        citationConfig: .init(isEnabled: false, font: .systemFont(ofSize: 12), textColor: .secondary, backgroundColor: .clear),
        imageConfig: .disabled
    )
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
                    MarkdownView(text: text, config: .init(shouldAnimateText: false, imageConfig: .disabled),
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
