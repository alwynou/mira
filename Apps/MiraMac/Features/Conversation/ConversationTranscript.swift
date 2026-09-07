import SwiftUI
import MiraCore

struct ConversationTranscript: View {
    let model: ConversationModel
    @Binding var rememberedMessage: Message?
    @Binding var revealedMessageID: MessageID?
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var scrollState = TranscriptScrollState()
    @State private var followScheduler = TranscriptFollowScheduler()
    @State private var latestBottomOffset: CGFloat = 0
    @State private var followsByOffset = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Growing content must not feed the window's min/ideal/max size negotiation.
        GeometryReader { _ in
            transcript.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var transcript: some View {
        ScrollView {
            // Long Markdown messages change height asynchronously after parsing. Keep
            // their measured layouts alive; lazy row eviction caused placement loops.
            VStack(alignment: .leading, spacing: 28) {
                ForEach(transcriptItems) { item in
                    TranscriptRow(item: item, model: model, conversationID: model.selectedConversationID,
                                  rememberedMessage: $rememberedMessage)
                        .equatable()
                        .id(item.id)
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
            latestBottomOffset = max(0, viewport.contentHeight - viewport.containerHeight)
            // Follow the rendered height, including asynchronous Markdown and code layout,
            // rather than raw token count. A point target can interpolate as the bottom
            // moves; a permanently pinned edge would jump with every size change.
            if scrollState.shouldFollowContentChange(),
               !followsByOffset || viewport.visibleBottom < viewport.contentHeight - 1 {
                followScheduler.schedule {
                    guard scrollState.shouldFollowContentChange() else { return }
                    TranscriptScrollAnimation.perform(animated: followsByOffset && !reduceMotion && model.activeExecution != nil) {
                        position.scrollTo(y: latestBottomOffset)
                    }
                    followsByOffset = true
                }
            }
        }
        .onScrollPhaseChange { _, phase, context in
            let isUserScrolling = phase == .tracking || phase == .interacting || phase == .decelerating
            if isUserScrolling { followScheduler.cancel() }
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
            followScheduler.cancel()
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
        .onChange(of: reduceMotion) { _, enabled in
            if enabled, scrollState.shouldFollowContentChange() {
                followScheduler.cancel()
                TranscriptScrollAnimation.perform(animated: false) { position.scrollTo(y: latestBottomOffset) }
            }
        }
        .onDisappear { followScheduler.cancel() }
    }

    private func jumpToLatest() {
        followScheduler.cancel()
        scrollState.jumpToLatest()
        TranscriptScrollAnimation.perform(animated: false) { position.scrollTo(y: latestBottomOffset) }
        followsByOffset = true
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

/// Compare the entire immutable row, not only its Markdown leaf. Capturing the
/// transcript's changing view value in every ForEach child fans draft updates out
/// through the headers, menus, and citation containers of all historical rows.
private struct TranscriptRow: View, Equatable {
    let item: TranscriptItem
    let model: ConversationModel
    let conversationID: ConversationID?
    @Binding var rememberedMessage: Message?

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.item == rhs.item && lhs.model === rhs.model && lhs.conversationID == rhs.conversationID
    }

    var body: some View {
        Group {
            if item.bodyPurgedAt != nil {
                Label("Reply content cleared after forgetting a memory", systemImage: "eye.slash")
                    .font(.callout).foregroundStyle(.secondary)
            } else if item.role == .assistant {
                VStack(alignment: .leading, spacing: 10) {
                    AssistantMarkdownRow(text: item.text, status: item.status, isStreaming: item.isStreaming, trace: item.trace)
                        .equatable()
                    MemoryHistoryTags(notices: item.memoryNotices).padding(.leading, 40)
                    if let executionID = item.executionID, let conversationID {
                        TranscriptCitations(text: item.text, executionID: executionID, conversationID: conversationID, model: model, memoryNotices: item.memoryNotices)
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
        }
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
