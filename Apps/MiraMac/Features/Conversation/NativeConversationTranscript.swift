import AppKit
import SwiftUI
import MarkdownView
import MarkdownParser
import ListViewKit
import Litext
import MiraCore

struct NativeConversationTranscript: NSViewRepresentable {
    let items: [TranscriptItem]
    let model: ConversationModel
    let readingState: ConversationReadingState
    let locale: Locale
    let reduceMotion: Bool
    let topOverlayHeight: CGFloat
    let bottomOverlayHeight: CGFloat
    @Binding var rememberedMessage: Message?
    @Binding var revealedMessageID: MessageID?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.start()
        return context.coordinator.viewport
    }

    func updateNSView(_ nsView: NSView, context: Context) { context.coordinator.update(self) }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) { coordinator.stop() }

    @MainActor
    final class Coordinator {
        let list = ListView<NativeTranscriptToken>()
        let viewport = NativeTranscriptViewport()
        private var parent: NativeConversationTranscript
        private var state = NativeTranscriptState()
        private let measurement = NativeTranscriptRow()
        private var contents: [String: (source: String, content: MarkdownContent)] = [:]
        private var contentOrder: [String] = []
        private var heights: [String: (width: CGFloat, height: CGFloat)] = [:]
        private var theme: MarkdownTheme
        private var appearanceName: NSAppearance.Name?
        private var boundsObserver: NSObjectProtocol?
        private var eventMonitor: Any?
        private var activity: Task<Void, Never>?
        private var isMounted = false
        private var selectionDrag: NSEvent?
        private var settlingUntil: TimeInterval = 0
        private var lastViewportSize = CGSize.zero
        private var bottomAlignmentUntil: TimeInterval = 0
        private var pendingHeightIDs: Set<String> = []
        private var initialFollow = true
        private var lastUserID: String?
        private let scheduler = TranscriptFollowScheduler()

        init(_ parent: NativeConversationTranscript) {
            self.parent = parent
            theme = MiraMarkdownStyle.theme(for: NSApp.effectiveAppearance)
            viewport.addSubview(list)
            list.autoresizingMask = [.width, .height]
            list.frame = viewport.bounds
            list.clipsToBounds = true
            TranscriptViewportLayout.setTopOverlayHeight(parent.topOverlayHeight, in: list)
            list.setAccessibilityElement(true)
            list.setAccessibilityRole(.scrollArea)
            list.setAccessibilityIdentifier("conversation.transcript")
            list.setAccessibilityLabel(L10n.string("Conversation", locale: parent.locale))
            list.postsBoundsChangedNotifications = true
            list.rows {
                ListRow(NativeTranscriptRow.self)
                    .estimatedHeight(240)
                    .height { [weak self] token, context in
                        guard let self else { return 1 }
                        if let cached = heights[token.id], cached.width == context.width { return cached.height }
                        configure(measurement, token: token, measurement: true)
                        return measurement.fittingHeight(width: context.width)
                    }
                    .configure { [weak self] row, token, _ in self?.configure(row, token: token, measurement: false) }
            }
        }

        func start() {
            isMounted = true
            parent.readingState.prepareForDisplay()
            boundsObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                                                                    object: list, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.wake() }
            }
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown, .leftMouseDragged, .leftMouseUp, .keyDown]) { [weak self] event in
                let handled = MainActor.assumeIsolated { self?.handle(event) ?? false }
                return handled ? nil : event
            }
            wake()
        }

        private func handle(_ event: NSEvent) -> Bool {
            guard event.window === list.window else { return false }
            let point = list.convert(event.locationInWindow, from: nil)
            let isScrollKey = event.type == .keyDown && [115, 116, 119, 121, 125, 126].contains(event.keyCode)
                && event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
                && ((list.window?.firstResponder as? NSView).map { $0 === viewport || $0 === list || $0.isDescendant(of: list) } ?? false)
            // Wheel input inside the floating composer belongs to its text field.
            let isReadingPoint = list.bounds.contains(point) && point.y < list.bounds.maxY - list.contentInsets.bottom
            if (event.type == .scrollWheel && event.scrollingDeltaY != 0 && isReadingPoint) || isScrollKey {
                userStartedScrolling()
            }
            if event.type == .scrollWheel, isReadingPoint,
               abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) {
                // Vertical transcript gestures belong to ListViewKit, not the
                // enclosing SwiftUI viewport that supplies the scroll-edge effect.
                list.scrollWheel(with: event)
                wake()
                return true
            }
            if isScrollKey {
                let step = max(40, (list.bounds.height - parent.topOverlayHeight - list.contentInsets.bottom) * 0.9)
                let y: CGFloat
                switch event.keyCode {
                case 115: y = list.minimumContentOffset.y
                case 119: y = list.maximumContentOffset.y
                case 116: y = list.contentOffset.y - step
                case 121: y = list.contentOffset.y + step
                case 126: y = list.contentOffset.y - 40
                default: y = list.contentOffset.y + 40
                }
                list.setContentOffset(CGPoint(x: 0, y: min(list.maximumContentOffset.y, max(list.minimumContentOffset.y, y))), animated: false)
                wake()
                return true
            }
            if event.type == .leftMouseDragged,
               let label = list.window?.firstResponder as? TextLabelView, label.isDescendant(of: list) {
                selectionDrag = event
            } else if event.type == .leftMouseUp { selectionDrag = nil }
            wake()
            return false
        }

        func stop() {
            isMounted = false
            scheduler.cancel()
            activity?.cancel()
            activity = nil
            list.cancelCurrentScrolling()
            if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
            if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
            boundsObserver = nil
            eventMonitor = nil
            recordAnchor()
            parent.readingState.expandedThinkingIDs = state.expandedThinking
            parent.readingState.leave()
            contents.removeAll()
            contentOrder.removeAll()
            heights.removeAll()
            measurement.clearContent()
            for row in list.visibleRowViews { (row as? NativeTranscriptRow)?.clearContent() }
            list.apply([], animated: false)
            list.reloadData()
        }

        func update(_ newParent: NativeConversationTranscript) {
            let localeChanged = parent.locale != newParent.locale
            let reducedMotionChanged = parent.reduceMotion != newParent.reduceMotion
            parent = newParent
            let privacyChanged = parent.items.contains { item in
                item.bodyPurgedAt != nil && state.items[item.id]?.bodyPurgedAt == nil
            }
            let change = state.apply(parent.items)
            let contentChanged = change.structureChanged || !change.updated.isEmpty
            if contentChanged { bottomAlignmentUntil = 0 }
            TranscriptViewportLayout.setTopOverlayHeight(parent.topOverlayHeight, in: list)
            let overlayChanged = TranscriptViewportLayout.setBottomOverlayHeight(
                parent.bottomOverlayHeight, in: list,
                followingLatest: !contentChanged && parent.readingState.scrollState.shouldKeepBottomAlignedDuringResize()
            )
            let name = list.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
            let styleChanged = appearanceName != name || localeChanged
            appearanceName = name
            if styleChanged {
                theme = MiraMarkdownStyle.theme(for: list.effectiveAppearance)
                contents.removeAll()
                contentOrder.removeAll()
                heights.removeAll()
            }
            if (overlayChanged || styleChanged) && !contentChanged && parent.readingState.scrollState.shouldKeepBottomAlignedDuringResize() {
                bottomAlignmentUntil = ProcessInfo.processInfo.systemUptime + 0.5
            }
            for id in parent.readingState.expandedThinkingIDs where !state.expandedThinking.contains(id) {
                state.toggleThinking(id)
            }
            parent.readingState.expandedThinkingIDs = state.expandedThinking
            let invalidated = Set(change.updated.map(\.id)).union(change.removed)
            for id in invalidated {
                contents.removeValue(forKey: id + ":answer")
                contents.removeValue(forKey: id + ":thinking")
                heights.removeValue(forKey: id)
            }
            contentOrder.removeAll { contents[$0] == nil }
            #if DEBUG
            if NativePerformanceBenchmark.isRequested && ProcessInfo.processInfo.arguments.contains("--benchmark-expand-thinking") {
                for item in parent.items where item.trace.contains(where: { $0.reasoning != nil }) && !state.expandedThinking.contains(item.id) {
                    state.toggleThinking(item.id)
                }
            }
            #endif
            if change.structureChanged { list.apply(state.tokens, animated: false) }
            else {
                for token in change.updated { list.update(token) }
            }
            if privacyChanged || !change.removed.isEmpty {
                measurement.clearContent()
                for row in list.visibleRowViews { (row as? NativeTranscriptRow)?.clearContent() }
                list.reloadData()
            }
            if styleChanged || reducedMotionChanged {
                // Invalidate sizes and configure mounted rows even when their item is unchanged.
                for token in state.tokens {
                    if let row = list.rowView(for: token.id) as? NativeTranscriptRow {
                        configure(row, token: token, measurement: false)
                    }
                }
                list.invalidateLayout()
            }
            let userID = parent.items.last(where: { $0.role == .user })?.id
            if let lastUserID, userID != lastUserID, userID != nil {
                Task { @MainActor [weak self] in
                    guard let self, isMounted else { return }
                    parent.readingState.scrollState.jumpToLatest()
                    wake()
                }
            }
            lastUserID = userID
            if let reveal = parent.revealedMessageID,
               parent.items.contains(where: { $0.message?.id == reveal && $0.role == .user && $0.status == .committed }) {
                let id = "message:\(reveal.rawValue.uuidString)"
                Task { @MainActor [weak self] in
                    guard let self, isMounted, parent.revealedMessageID == reveal else { return }
                    scheduler.cancel()
                    bottomAlignmentUntil = 0
                    parent.readingState.userStartedScrolling()
                    parent.readingState.scrollState.revealHistory()
                    list.scrollToRow(with: id, at: .middle, animated: false)
                    parent.revealedMessageID = nil
                    recordAnchor()
                }
            }
            if reducedMotionChanged && parent.reduceMotion { list.cancelCurrentScrolling() }
            wake()
        }

        private func content(id: String, source: String) -> MarkdownContent {
            if let cached = contents[id], cached.source == source { return cached.content }
            let result = MarkdownParser().parse(source)
            let prepared = MarkdownContent(parserResult: result, theme: theme, locale: parent.locale)
            contents[id] = (source, prepared)
            contentOrder.removeAll { $0 == id }
            contentOrder.append(id)
            // Do not retain one rendered document for every historical message.
            while contentOrder.count > 64 { contents.removeValue(forKey: contentOrder.removeFirst()) }
            return prepared
        }

        private func configure(_ row: NativeTranscriptRow, token: NativeTranscriptToken, measurement measuring: Bool) {
            guard let item = state.items[token.id] else { return }
            let visible = item.bodyPurgedAt == nil && item.role == .assistant
            let expanded = state.expandedThinking.contains(item.id)
            var reasoningSource = ""
            if visible && expanded {
                reasoningSource = item.trace.compactMap { $0.reasoning?.text }.filter { !$0.isEmpty }.joined(separator: "\n\n")
                if reasoningSource.isEmpty {
                    reasoningSource = L10n.string("The model did not provide visible thinking text.", locale: parent.locale)
                }
            }
            let body = visible && !item.text.isEmpty ? content(id: item.id + ":answer", source: item.text) : nil
            let reasoning = visible && expanded ? content(id: item.id + ":thinking", source: reasoningSource) : nil
            let auxiliary: AnyView
            if visible && !measuring {
                auxiliary = AnyView(VStack(alignment: .leading, spacing: 10) {
                    MemoryHistoryTags(notices: item.memoryNotices)
                    if let executionID = item.executionID, let conversationID = parent.model.selectedConversationID {
                        TranscriptCitations(text: item.text, executionID: executionID, conversationID: conversationID,
                                           model: parent.model, memoryNotices: item.memoryNotices).equatable()
                    }
                }.environment(\.locale, parent.locale))
            } else { auxiliary = AnyView(EmptyView()) }
            row.onHeightChange = measuring ? nil : { [weak self, weak row] height in
                guard let self, let row, isMounted else { return }
                let width = row.bounds.width
                guard heights[item.id]?.width != width || heights[item.id]?.height != height else { return }
                heights[item.id] = (width, height)
                let now = ProcessInfo.processInfo.systemUptime
                if now < bottomAlignmentUntil { bottomAlignmentUntil = now + 0.5 }
                pendingHeightIDs.insert(item.id)
                scheduler.schedule { [weak self] in
                    guard let self, isMounted else { return }
                    let ids = pendingHeightIDs
                    pendingHeightIDs.removeAll()
                    for id in ids { list.invalidateLayout(forRowWith: id) }
                    wake()
                }
            }
            row.onToggleThinking = { [weak self] in
                guard let self else { return }
                state.toggleThinking(item.id)
                parent.readingState.expandedThinkingIDs = state.expandedThinking
                heights.removeValue(forKey: item.id)
                if let current = list.rowView(for: item.id) as? NativeTranscriptRow {
                    configure(current, token: token, measurement: false)
                }
                list.invalidateLayout(forRowWith: item.id)
                wake()
            }
            row.configure(item: item, body: body, reasoning: reasoning, reasoningSource: reasoningSource,
                          expanded: expanded, theme: theme, locale: parent.locale, reduceMotion: parent.reduceMotion,
                          measurement: measuring, auxiliary: auxiliary) { [weak self] message in
                self?.parent.rememberedMessage = message
            }
        }

        private func userStartedScrolling() {
            bottomAlignmentUntil = 0
            scheduler.cancel()
            if !parent.readingState.scrollState.isUserScrolling { list.cancelCurrentScrolling() }
            parent.readingState.userStartedScrolling()
            parent.readingState.scrollState.userScrollChanged(isScrolling: true, isNearBottom: false)
        }

        private func wake() {
            guard isMounted else { return }
            settlingUntil = ProcessInfo.processInfo.systemUptime + 0.5
            guard activity == nil else { return }
            activity = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(16)) } catch { break }
                    guard let self, isMounted else { break }
                    observeGeometry()
                    if !parent.items.contains(where: \.isStreaming), !list.isUserInteractingWithScroll,
                       ProcessInfo.processInfo.systemUptime > settlingUntil { break }
                }
                self?.activity = nil
            }
        }

        private func observeGeometry() {
            let reading = parent.readingState
            if let event = selectionDrag, NSEvent.pressedMouseButtons & 1 != 0,
               let label = list.window?.firstResponder as? TextLabelView, label.isDescendant(of: list),
               let location = list.window?.mouseLocationOutsideOfEventStream {
                let point = list.convert(location, from: nil)
                let top = list.bounds.minY + parent.topOverlayHeight + 16
                let bottom = max(top, list.bounds.maxY - list.contentInsets.bottom - 16)
                let delta = point.y < top ? max(-32, point.y - top) : (point.y > bottom ? min(32, point.y - bottom) : 0)
                if delta != 0 {
                    userStartedScrolling()
                    let y = min(list.maximumContentOffset.y, max(list.minimumContentOffset.y, list.contentOffset.y + delta))
                    list.setContentOffset(CGPoint(x: 0, y: y), animated: false)
                    label.mouseDragged(with: event)
                    settlingUntil = ProcessInfo.processInfo.systemUptime + 0.5
                }
            }
            if list.isScrollOffsetOwnedByUser && !reading.scrollState.isUserScrolling { userStartedScrolling() }
            if !list.isUserInteractingWithScroll && reading.scrollState.isUserScrolling {
                reading.scrollState.userScrollChanged(isScrolling: false,
                    isNearBottom: TranscriptViewportLayout.isNearLatest(in: list))
            }
            var restoredReadingPosition = false
            if let anchor = reading.nativeAnchor, reading.pendingRestoreOffset != nil,
               state.items[anchor.id] != nil {
                let rect = list.rectForRow(with: anchor.id)
                list.setContentOffset(CGPoint(x: 0, y: rect.minY + anchor.offset), animated: false)
                reading.userStartedScrolling()
                restoredReadingPosition = true
            } else if let offset = reading.takeRestorationOffset(maximumOffset: list.maximumContentOffset.y) {
                list.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
                restoredReadingPosition = true
            }
            if restoredReadingPosition {
                initialFollow = false
                bottomAlignmentUntil = 0
            }
            let viewportChanged = lastViewportSize != .zero && list.bounds.size != lastViewportSize
            let shouldPlaceInitialContent = initialFollow && reading.pendingRestoreOffset == nil && reading.scrollState.isAtLatest
            let shouldJumpToLatest = reading.scrollState.consumePendingJumpToLatest()
            if shouldPlaceInitialContent || shouldJumpToLatest {
                bottomAlignmentUntil = ProcessInfo.processInfo.systemUptime + 0.5
                initialFollow = false
            } else if viewportChanged && reading.scrollState.shouldKeepBottomAlignedDuringResize() {
                bottomAlignmentUntil = ProcessInfo.processInfo.systemUptime + 0.5
            }
            // Allow deferred row measurements to finish the same positioning operation.
            // New content or a user gesture cancels this bounded correction immediately.
            if ProcessInfo.processInfo.systemUptime < bottomAlignmentUntil {
                list.scrollToBottom(animated: false)
            }
            reading.scrollState.updateVisiblePosition(isNearLatest: TranscriptViewportLayout.isNearLatest(in: list))
            lastViewportSize = list.bounds.size
            recordAnchor()
        }

        private func recordAnchor() {
            let reading = parent.readingState
            reading.recordOffset(list.contentOffset.y)
            guard reading.pendingRestoreOffset == nil, !reading.scrollState.isAtLatest else { return }
            if let index = list.indicesForVisibleRows.first, state.tokens.indices.contains(index) {
                let rect = list.rectForRow(at: index)
                reading.nativeAnchor = .init(id: state.tokens[index].id, offset: list.contentOffset.y - rect.minY)
            }
        }
    }
}

/// A keyboard-focusable viewport keeps navigation scoped away from the composer.
@MainActor
final class NativeTranscriptViewport: NSView {
    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }
}
