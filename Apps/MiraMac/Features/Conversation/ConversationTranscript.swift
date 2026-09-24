import SwiftUI
import MiraCore

struct ConversationTranscript: View {
    let model: ConversationModel
    let page: ConversationPageState
    let topOverlayHeight: CGFloat
    let bottomOverlayHeight: CGFloat
    @Binding var rememberedMessage: SessionQueryMessage?
    @Binding var revealedMessageID: MessageID?
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    private var readingState: ConversationReadingState {
        page.readingState
    }

    var body: some View {
        GeometryReader { _ in
            NativeConversationTranscript(items: transcriptItems, model: model, page: page, conversationID: page.conversationID, readingState: readingState, isActive: page.isActive, contentGeneration: page.contentGeneration,
                                         locale: locale, colorScheme: colorScheme, reduceMotion: reduceMotion, topOverlayHeight: topOverlayHeight, bottomOverlayHeight: bottomOverlayHeight,
                                         rememberedMessage: $rememberedMessage, revealedMessageID: $revealedMessageID)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay(alignment: .bottom) {
            TranscriptJumpToLatestButton(readingState: readingState)
                .padding(.bottom, bottomOverlayHeight + MiraTheme.Spacing.sm)
        }
    }

    private var transcriptItems: [TranscriptItem] { page.transcriptItems }

}

/// Scroll-driven visibility updates do not rebuild transcript message snapshots.
private struct TranscriptJumpToLatestButton: View {
    let readingState: ConversationReadingState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let isVisible = readingState.scrollState.showsJumpToLatest
        Button("Jump to latest", systemImage: "arrow.down") {
            readingState.userStartedScrolling()
            readingState.scrollState.jumpToLatest()
        }
        .labelStyle(.iconOnly)
        .buttonStyle(MiraGlassCircleButtonStyle())
        .help("Jump to latest")
        .accessibilityIdentifier("conversation.jumpToLatest")
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(isVisible)
        .disabled(!isVisible)
        .accessibilityHidden(!isVisible)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isVisible)
    }
}

struct TranscriptCitations: View, Equatable {
    let text: String
    let executionID: ExecutionID
    let conversationID: ConversationID
    let model: ConversationModel

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.text == rhs.text && lhs.executionID == rhs.executionID && lhs.conversationID == rhs.conversationID && lhs.model === rhs.model
    }

    var body: some View {
        KnowledgeCitationList(references: SourceCitationReference.references(in: text), executionID: executionID,
                              conversationID: conversationID, library: model.library)
    }
}

/// Status only: deletion requests never expose memory bodies or request internals in the transcript.
struct MemoryDeletionStatusView: View {
    let requests: [MemoryDeletionRequest]
    @Environment(\.locale) private var locale

    private var orderedRequests: [MemoryDeletionRequest] {
        requests.sorted {
            if $0.requestedAt != $1.requestedAt { return $0.requestedAt < $1.requestedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private var hasFailedRequest: Bool {
        requests.contains { $0.state == .failed }
    }

    var body: some View {
        if !requests.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(orderedRequests) { request in
                    Label(title(for: request.state), systemImage: symbol(for: request.state))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(L10n.string(
                    hasFailedRequest
                        ? "The original conversation remains on this device. Retry failed deletions from Memory."
                        : "The original conversation remains on this device.",
                    locale: locale))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .accessibilityElement(children: .contain)
        }
    }

    private func title(for state: MemoryDeletionRequest.State) -> String {
        switch state {
        case .pending: return L10n.string("Memory deletion pending", locale: locale)
        case .completed: return L10n.string("Memory deleted", locale: locale)
        case .failed: return L10n.string("Memory deletion failed", locale: locale)
        }
    }

    private func symbol(for state: MemoryDeletionRequest.State) -> String {
        switch state {
        case .pending: return "clock"
        case .completed: return "checkmark.circle"
        case .failed: return "exclamationmark.triangle"
        }
    }
}
