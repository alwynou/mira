import SwiftUI
import MiraCore

struct ConversationTranscript: View {
    let model: ConversationModel
    let readingState: ConversationReadingState
    let topOverlayHeight: CGFloat
    let bottomOverlayHeight: CGFloat
    @Binding var rememberedMessage: Message?
    @Binding var revealedMessageID: MessageID?
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { _ in
            NativeConversationTranscript(items: transcriptItems, model: model, readingState: readingState,
                                         locale: locale, reduceMotion: reduceMotion, topOverlayHeight: topOverlayHeight, bottomOverlayHeight: bottomOverlayHeight,
                                         rememberedMessage: $rememberedMessage, revealedMessageID: $revealedMessageID)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay(alignment: .bottomTrailing) {
            if !readingState.scrollState.isAtLatest && !readingState.scrollState.isUserScrolling {
                Button("Jump to latest", systemImage: "arrow.down") {
                    readingState.userStartedScrolling()
                    readingState.scrollState.jumpToLatest()
                }
                .buttonStyle(MiraPrimaryButtonStyle())
                .padding(16)
                .padding(.bottom, bottomOverlayHeight)
            }
        }
    }

    private var transcriptItems: [TranscriptItem] {
        var items = model.messages.map { message in
            TranscriptItem(
                id: message.role == .assistant ? (message.executionID.map { "execution:\($0.rawValue.uuidString)" } ?? "message:\(message.id.rawValue.uuidString)") : "message:\(message.id.rawValue.uuidString)",
                role: message.role, text: message.text, status: message.status, isStreaming: false,
                message: message, bodyPurgedAt: message.bodyPurgedAt,
                executionID: message.executionID, trace: message.trace,
                memoryNotices: message.executionID.flatMap { model.memoryNotices[$0] } ?? []
            )
        }
        if let execution = model.executions.last,
           !items.contains(where: { $0.id == "execution:\(execution.id.rawValue.uuidString)" }),
           let draft = model.streamBuffer.drafts[execution.id] {
            items.append(.init(
                id: "execution:\(execution.id.rawValue.uuidString)", role: .assistant, text: draft,
                status: execution.status.isTerminal ? .interrupted : nil,
                isStreaming: !execution.status.isTerminal,
                executionID: execution.id, trace: model.streamBuffer.thinkingTraces[execution.id] ?? []
            ))
        }
        return items
    }
}

struct TranscriptCitations: View, Equatable {
    let text: String
    let executionID: ExecutionID
    let conversationID: ConversationID
    let model: ConversationModel
    let memoryNotices: [MemoryContextNotice]

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.memoryNotices == rhs.memoryNotices && lhs.text == rhs.text && lhs.executionID == rhs.executionID && lhs.conversationID == rhs.conversationID && lhs.model === rhs.model
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            MemoryCitationList(references: MemoryCitationReference.references(in: text), executionID: executionID,
                               conversationID: conversationID, application: model.application, memoryNotices: memoryNotices) { sourceID in
                Task { await model.selectConversation(sourceID) }
            }
            KnowledgeCitationList(references: SourceCitationReference.references(in: text), executionID: executionID,
                                  conversationID: conversationID, application: model.application)
        }
    }
}

/// Status only: never copy a memory body into historical metadata.
struct MemoryHistoryTags: View {
    let notices: [MemoryContextNotice]

    var body: some View {
        if !notices.isEmpty {
            HStack(spacing: 6) {
                ForEach(Array(Set(notices.map(\.reason))).sorted { $0.rawValue < $1.rawValue }, id: \.self) { reason in
                    Label(title(for: reason), systemImage: "brain")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                }
            }
            .help("Historical reply retained. The related memory has changed or is unavailable, so this reply is excluded from future model context.")
        }
    }

    private func title(for reason: MemoryContextNotice.Reason) -> LocalizedStringKey {
        switch reason {
        case .forgotten: "Related memory forgotten"
        case .superseded: "Related memory superseded"
        case .expired: "Related memory expired"
        case .notYetValid: "Related memory not yet valid"
        case .archived: "Related memory archived"
        case .rejected: "Related memory rejected"
        case .removed: "Related memory removed"
        case .candidate: "Related memory pending review"
        case .updated: "Related memory updated"
        case .unavailable: "Related memory unavailable"
        }
    }
}
