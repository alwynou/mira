import SwiftUI
import MiraCore

struct ConversationTranscript: View {
    let model: ConversationModel
    @Binding var rememberedMessage: Message?
    @Binding var revealedMessageID: MessageID?
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var scrollState = TranscriptScrollState()

    var body: some View {
        ScrollView {
            // Long Markdown messages change height asynchronously after parsing. Keep
            // their measured layouts alive; lazy row eviction caused placement loops.
            VStack(alignment: .leading, spacing: 28) {
                ForEach(transcriptItems) { item in
                    Group {
                        if item.bodyPurgedAt != nil {
                            Label("Reply content cleared after forgetting a memory", systemImage: "eye.slash")
                                .font(.callout).foregroundStyle(.secondary)
                        } else if item.role == .assistant {
                            VStack(alignment: .leading, spacing: 10) {
                                AssistantMarkdownRow(text: item.text, status: item.status, isStreaming: item.isStreaming, trace: item.trace)
                                    .equatable()
                                if let executionID = item.executionID, let conversationID = model.selectedConversationID {
                                    TranscriptCitations(text: item.text, executionID: executionID, conversationID: conversationID, model: model)
                                        .equatable()
                                        .padding(.leading, 40)
                                }
                            }
                        } else {
                            MessageRow(role: item.role, text: item.text, status: item.status)
                                .contextMenu {
                                    if let message = item.message, message.role == .user, message.status == .committed {
                                        Button("Remember this message…", systemImage: "brain") { rememberedMessage = message }
                                    }
                                }
                        }
                    }.id(item.id)
                }
            }
            .scrollTargetLayout()
            .padding(28).frame(maxWidth: 860).frame(maxWidth: .infinity)
        }
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.top, for: .alignment)
        .onScrollGeometryChange(for: TranscriptViewport.self) { geometry in
            TranscriptViewport(contentHeight: ceil(geometry.contentSize.height), containerHeight: ceil(geometry.containerSize.height),
                               visibleBottom: geometry.visibleRect.maxY)
        } action: { _, viewport in
            // Follow the rendered height, including asynchronous Markdown and code layout,
            // rather than the raw token count. No animation competes with a wheel gesture.
            if scrollState.shouldFollowContentChange(), viewport.visibleBottom < viewport.contentHeight - 1 {
                position.scrollTo(edge: .bottom)
            }
        }
        .onScrollPhaseChange { _, phase, context in
            let isUserScrolling = phase == .tracking || phase == .interacting || phase == .decelerating
            scrollState.userScrollChanged(
                isScrolling: isUserScrolling,
                isNearBottom: TranscriptScrollState.isNearBottom(
                    contentHeight: context.geometry.contentSize.height,
                    visibleBottom: context.geometry.visibleRect.maxY
                )
            )
        }
        .onChange(of: model.messages.last(where: { $0.role == .user })?.id) { oldID, newID in
            if newID != nil, oldID != newID { jumpToLatest() }
        }
        .onChange(of: revealedMessageID) { _, messageID in
            guard let messageID,
                  model.messages.contains(where: { $0.id == messageID && $0.role == .user && $0.status == .committed }) else { return }
            scrollState.revealHistory()
            position.scrollTo(id: "message:\(messageID.rawValue.uuidString)", anchor: .center)
            revealedMessageID = nil
        }
        .overlay(alignment: .bottomTrailing) {
            if !scrollState.followsLatest && !scrollState.isUserScrolling {
                Button("Jump to latest", systemImage: "arrow.down") { jumpToLatest() }
                    .buttonStyle(.borderedProminent)
                    .padding(16)
            }
        }
    }

    private func jumpToLatest() {
        scrollState.jumpToLatest()
        position.scrollTo(edge: .bottom)
    }

    private var transcriptItems: [TranscriptItem] {
        var items = model.messages.map { message in
            TranscriptItem(
                id: message.role == .assistant ? (message.executionID.map { "execution:\($0.rawValue.uuidString)" } ?? "message:\(message.id.rawValue.uuidString)") : "message:\(message.id.rawValue.uuidString)",
                role: message.role, text: message.text, status: message.status, isStreaming: false,
                message: message, bodyPurgedAt: message.bodyPurgedAt,
                executionID: message.executionID, trace: message.trace
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

private struct TranscriptViewport: Equatable {
    let contentHeight: CGFloat
    let containerHeight: CGFloat
    let visibleBottom: CGFloat

    // Offset-only callbacks must not schedule another scroll. Compare rounded sizes
    // to avoid chasing subpixel changes while AppKit settles its text layout.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.contentHeight == rhs.contentHeight && lhs.containerHeight == rhs.containerHeight
    }
}

private struct TranscriptCitations: View, Equatable {
    let text: String
    let executionID: ExecutionID
    let conversationID: ConversationID
    let model: ConversationModel

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.text == rhs.text && lhs.executionID == rhs.executionID && lhs.conversationID == rhs.conversationID && lhs.model === rhs.model
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            MemoryCitationList(references: MemoryCitationReference.references(in: text), executionID: executionID,
                               conversationID: conversationID, application: model.application) { sourceID in
                Task { await model.selectConversation(sourceID) }
            }
            KnowledgeCitationList(references: SourceCitationReference.references(in: text), executionID: executionID,
                                  conversationID: conversationID, application: model.application)
        }
    }
}
