import AppKit
import Observation
import SwiftUI
import SwiftStreamingMarkdown
import MiraCore

struct TranscriptItem: Identifiable {
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

struct AssistantMarkdownRow: View {
    let trace: [CanonicalMessage]
    let text: String
    let status: MessageStatus?
    let isStreaming: Bool
    @State private var buffer: MarkdownBuffer
    @State private var lastText: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(text: String, status: MessageStatus?, isStreaming: Bool, trace: [CanonicalMessage] = []) {
        self.trace = trace
        self.text = text
        self.status = status
        self.isStreaming = isStreaming
        _buffer = State(initialValue: MarkdownBuffer(initial: text))
        _lastText = State(initialValue: text)
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
                }
                else {
                    MarkdownView(text: buffer.snapshot, config: markdownConfig)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { buffer.reset(text); lastText = text }
        .onChange(of: text) { _, newValue in
            if newValue.hasPrefix(lastText) { buffer.append(String(newValue.dropFirst(lastText.count))) }
            else { buffer.reset(newValue) }
            lastText = newValue
        }
        .onChange(of: isStreaming) { _, streaming in if !streaming { buffer.finish() } }
        .accessibilityElement(children: .contain)
    }

    private var markdownConfig: MarkdownRenderConfig {
        MarkdownRenderConfig(
            shouldAnimateText: !reduceMotion,
            citationConfig: .init(isEnabled: false, font: .systemFont(ofSize: 12), textColor: .secondary, backgroundColor: .clear),
            imageConfig: .disabled
        )
    }
}

private struct ThinkingDisclosure: View {
    let trace: [CanonicalMessage]
    let isStreaming: Bool
    @State private var isExpanded = false
    @State private var buffer = MarkdownBuffer()
    @State private var lastText = ""
    @Environment(\.locale) private var locale

    private var text: String { trace.compactMap { $0.reasoning?.text }.filter { !$0.isEmpty }.joined(separator: "\n\n") }
    private var isThinking: Bool { isStreaming && trace.last?.reasoning?.isComplete == false }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            if text.isEmpty {
                Text("The model did not provide visible thinking text.").font(.caption).foregroundStyle(.secondary)
            } else {
                MarkdownView(text: buffer.snapshot, config: .init(shouldAnimateText: false, imageConfig: .disabled))
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        } label: {
            HStack(spacing: 6) {
                if isThinking { ProgressView().controlSize(.mini) }
                Label(L10n.string(isThinking ? "Thinking…" : "Thinking", locale: locale), systemImage: "brain")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .onAppear { buffer.reset(text); lastText = text }
        .onChange(of: text) { _, value in
            if value.hasPrefix(lastText) { buffer.append(String(value.dropFirst(lastText.count))) }
            else { buffer.reset(value) }
            lastText = value
        }
        .onChange(of: isThinking) { _, active in if !active { buffer.finish() } }
    }
}

@MainActor @Observable
private final class MarkdownBuffer {
    private(set) var snapshot: String
    private var fullText: String
    private var pendingEmission: Task<Void, Never>?

    init(initial: String = "") { fullText = initial; snapshot = initial }

    func append(_ delta: String) {
        guard !delta.isEmpty else { return }
        fullText.append(delta)
        guard pendingEmission == nil else { return }
        pendingEmission = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(70))
            guard !Task.isCancelled, let self else { return }
            self.snapshot = self.fullText
            self.pendingEmission = nil
        }
    }

    func reset(_ value: String) {
        pendingEmission?.cancel(); pendingEmission = nil
        fullText = value; snapshot = value
    }

    func finish() {
        pendingEmission?.cancel(); pendingEmission = nil
        snapshot = fullText
    }
}
