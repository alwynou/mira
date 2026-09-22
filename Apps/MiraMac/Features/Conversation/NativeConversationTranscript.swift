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
    let page: ConversationPageState
    let conversationID: ConversationID?
    let readingState: ConversationReadingState
    let isActive: Bool
    let contentGeneration: Int
    let locale: Locale
    let colorScheme: ColorScheme
    let reduceMotion: Bool
    let topOverlayHeight: CGFloat
    let bottomOverlayHeight: CGFloat
    @Binding var rememberedMessage: SessionQueryMessage?
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
        private var conversationID: ConversationID?
        private var state = NativeTranscriptState()
        private let measurement = NativeTranscriptRow()
        private let rowViews = NSHashTable<NativeTranscriptRow>.weakObjects()
        private var contents: [String: (source: String, content: MarkdownContent)] = [:]
        private var contentOrder: [String] = []
        private var heights: [String: (width: CGFloat, height: CGFloat)] = [:]
        private var measurementSignatures: [String: Int] = [:]
        private var theme: MarkdownTheme
        private var appearanceName: NSAppearance.Name?
        private var renderedLocale: Locale?
        private var renderedReduceMotion: Bool?
        private var boundsObserver: NSObjectProtocol?
        private var eventMonitor: Any?
        private var activity: Task<Void, Never>?
        private var activityGeneration = 0
        private var isMounted = false
        private var selectionDrag: NSEvent?
        private var settlingUntil: TimeInterval = 0
        private var lastViewportSize = CGSize.zero
        private var bottomAlignmentUntil: TimeInterval = 0
        private var restorationAnchor: ConversationReadingState.NativeAnchor?
        private var restorationUntil: TimeInterval = 0
        private var pendingHeightIDs: Set<String> = []
        private var hasInstalledSnapshot = false
        private var isPositioning = false
        private var lastUserID: String?
        private var navigationGeneration = 0
        private let scheduler = TranscriptFollowScheduler()

        init(_ parent: NativeConversationTranscript) {
            self.parent = parent
            conversationID = parent.conversationID
            theme = MiraMarkdownStyle.theme(for: NSAppearance(named: parent.colorScheme == .dark ? .darkAqua : .aqua) ?? NSApp.effectiveAppearance)
            viewport.conversationID = parent.conversationID
            viewport.isActive = parent.isActive
            viewport.isHidden = !parent.isActive
            viewport.addSubview(list)
            list.autoresizingMask = [.width, .height]
            list.frame = viewport.bounds
            list.clipsToBounds = true
            TranscriptViewportLayout.setTopOverlayHeight(parent.topOverlayHeight, in: list)
            list.setAccessibilityElement(true)
            list.setAccessibilityRole(.scrollArea)
            list.setAccessibilityIdentifier("conversation.transcript")
            list.setAccessibilityLabel(L10n.string("Conversation", locale: parent.locale))
            list.contentView.postsBoundsChangedNotifications = true
            viewport.onLayout = { [weak self] in self?.layoutViewport() }
            list.rows {
                ListRow(NativeTranscriptRow.self)
                    .estimatedHeight(240)
                    .height { [weak self] token, context in
                        guard let self else { return 1 }
                        if let cached = heights[token.id], cached.width == context.width { return cached.height }
                        if let cached = self.parent.readingState.rowMeasurements[token.id],
                           cached.signature == measurementSignatures[token.id], cached.width == context.width {
                            heights[token.id] = (cached.width, cached.height)
                            return cached.height
                        }
                        configure(measurement, token: token, measurement: true)
                        let height = measurement.fittingHeight(width: context.width)
                        cacheHeight(height, width: context.width, id: token.id)
                        return height
                    }
                    .configure { [weak self] row, token, _ in self?.configure(row, token: token, measurement: false) }
            }
        }

        func start() {
            isMounted = true
            parent.readingState.prepareForDisplay()
            boundsObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                                                                    object: list.contentView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if let self, self.hasInstalledSnapshot, !self.isPositioning, self.viewport.window != nil,
                       self.list.bounds.width > 0, self.list.bounds.height > 0 {
                        self.recordAnchor()
                    }
                    self?.viewport.needsLayout = true
                    self?.wake()
                }
            }
            list.onUserScroll = { [weak self] in
                guard let self, parent.isActive, parent.page.isActive else { return }
                userStartedScrolling()
                wake()
            }
            // Text selection and page keys need window-level routing while Litext
            // owns first responder. Wheel input stays entirely in NSScrollView.
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .keyDown]) { [weak self] event in
                let handled = MainActor.assumeIsolated { self?.handle(event) ?? false }
                return handled ? nil : event
            }
            wake()
        }

        private func handle(_ event: NSEvent) -> Bool {
            guard parent.isActive, parent.page.isActive, event.window === list.window else { return false }
            let isScrollKey = event.type == .keyDown && [115, 116, 119, 121, 125, 126].contains(event.keyCode)
                && event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
                && ((list.window?.firstResponder as? NSView).map { $0 === viewport || $0 === list || $0.isDescendant(of: list) } ?? false)
            if isScrollKey {
                userStartedScrolling()
                let step = max(40, (list.bounds.height - parent.topOverlayHeight - list.bottomContentPadding) * 0.9)
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
            list.onUserScroll = nil
            // Bounds changes record the last visible position. Teardown may already
            // have collapsed the viewport or clamped its offset to zero.
            parent.readingState.expandedActivityIDs = state.expandedActivity
            parent.readingState.leave()
            viewport.onLayout = nil
            contents.removeAll()
            contentOrder.removeAll()
            heights.removeAll()
            measurement.clearContent()
            for row in rowViews.allObjects { row.clearContent() }
            list.apply([], animated: false)
            list.reloadData()
        }

        func update(_ newParent: NativeConversationTranscript) {
            guard newParent.conversationID == newParent.page.conversationID else { return }
            let localeChanged = renderedLocale != newParent.locale
            let reducedMotionChanged = renderedReduceMotion != newParent.reduceMotion
            let reactivating = !parent.isActive && newParent.isActive
            if parent.isActive && !newParent.isActive {
                recordAnchor()
                navigationGeneration &+= 1
                scheduler.cancel(); activity?.cancel(); activity = nil
                list.cancelCurrentScrolling()
                bottomAlignmentUntil = 0; restorationUntil = 0
                parent.readingState.leave()
            }
            if parent.contentGeneration != newParent.contentGeneration {
                // A new content generation requires native rows to rebuild from the latest snapshot.
                resetForSelection()
            }
            if conversationID != newParent.conversationID {
                resetForSelection()
                conversationID = newParent.conversationID
                newParent.readingState.prepareForDisplay()
            }
            parent = newParent
            viewport.conversationID = parent.conversationID
            viewport.isActive = parent.isActive
            viewport.isHidden = !parent.isActive
            guard parent.isActive else { return }
            if reactivating {
                parent.readingState.prepareForDisplay()
                if hasInstalledSnapshot {
                    parent.readingState.completeRestoration()
                    restorationAnchor = parent.readingState.nativeAnchor
                    restorationUntil = ProcessInfo.processInfo.systemUptime + 0.5
                }
            }
            // The temporary empty loading state is not an authoritative snapshot.
            // Do not prune the destination's saved measurements or thinking state.
            guard !parent.page.isLoading else { return }
            let previousItems = state.items
            let change = state.apply(parent.items)
            let contentChanged = change.structureChanged || !change.updated.isEmpty
            if contentChanged { bottomAlignmentUntil = 0; restorationUntil = 0 }
            TranscriptViewportLayout.setTopOverlayHeight(parent.topOverlayHeight, in: list)
            let overlayChanged = TranscriptViewportLayout.setBottomOverlayHeight(
                parent.bottomOverlayHeight, in: list,
                followingLatest: !contentChanged && parent.readingState.scrollState.shouldKeepBottomAlignedDuringResize()
            )
            // SwiftUI's window appearance is available before AppKit attaches the list.
            // An unattached view's fallback appearance must not discard a dark-mode cache.
            let name: NSAppearance.Name = parent.colorScheme == .dark ? .darkAqua : .aqua
            let styleChanged = appearanceName != name || localeChanged
            appearanceName = name
            renderedLocale = parent.locale
            renderedReduceMotion = parent.reduceMotion
            if styleChanged {
                theme = MiraMarkdownStyle.theme(for: NSAppearance(named: name) ?? list.effectiveAppearance)
                contents.removeAll()
                contentOrder.removeAll()
                heights.removeAll()
            }
            let measurementStyle = parent.locale.identifier + ":" + name.rawValue
            if parent.readingState.measurementStyle != measurementStyle {
                parent.readingState.rowMeasurements.removeAll()
                parent.readingState.measurementStyle = measurementStyle
            }
            if (overlayChanged || styleChanged) && !contentChanged && parent.readingState.scrollState.shouldKeepBottomAlignedDuringResize() {
                bottomAlignmentUntil = ProcessInfo.processInfo.systemUptime + 0.5
            }
            for id in parent.readingState.expandedActivityIDs where !state.expandedActivity.contains(id) {
                state.toggleActivity(id)
            }
            parent.readingState.expandedActivityIDs = state.expandedActivity
            measurementSignatures = Dictionary(uniqueKeysWithValues: parent.items.map {
                ($0.id, $0.measurementSignature(expanded: state.expandedActivity.contains($0.id)))
            })
            let retainedIDs = Set(state.tokens.map(\.id))
            parent.readingState.rowMeasurements = parent.readingState.rowMeasurements.filter { retainedIDs.contains($0.key) }
            let contentInvalidated = Set(parent.items.compactMap { item -> String? in
                guard let previous = previousItems[item.id], renderedContentChange(from: previous, to: item)
                else { return nil }
                return item.id
            }).union(change.removed)
            let layoutInvalidated = Set(change.updated.map(\.id)).union(change.removed)
            for id in contentInvalidated {
                contents.removeValue(forKey: id + ":answer")
                contents.removeValue(forKey: id + ":thinking")
            }
            for id in layoutInvalidated {
                heights.removeValue(forKey: id)
            }
            contentOrder.removeAll { contents[$0] == nil }
            #if DEBUG
            if NativePerformanceBenchmark.isRequested && ProcessInfo.processInfo.arguments.contains("--benchmark-expand-thinking") {
                for item in parent.items where !item.thinking.isEmpty && !state.expandedActivity.contains(item.id) {
                    state.toggleActivity(item.id)
                }
            }
            #endif
            if hasInstalledSnapshot && change.structureChanged { list.apply(state.tokens, animated: false) }
            else if hasInstalledSnapshot {
                for token in change.updated { list.update(token) }
            }
            if hasInstalledSnapshot && !change.removed.isEmpty {
                measurement.clearContent()
                for row in rowViews.allObjects { row.clearContent() }
                list.reloadData()
            }
            if hasInstalledSnapshot && (styleChanged || reducedMotionChanged) {
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
                let origin = conversationID
                let generation = navigationGeneration
                Task { @MainActor [weak self] in
                    guard let self, isMounted, parent.isActive, parent.page.isActive, conversationID == origin,
                          parent.page.conversationID == origin, navigationGeneration == generation else { return }
                    parent.readingState.scrollState.jumpToLatest()
                    wake()
                }
            }
            lastUserID = userID
            revealMessageIfNeeded()
            if reducedMotionChanged && parent.reduceMotion { list.cancelCurrentScrolling() }
            viewport.needsLayout = true
            wake()
        }

        private func renderedContentChange(from previous: TranscriptItem, to current: TranscriptItem) -> Bool {
            previous.role != current.role || previous.text != current.text ||
            previous.thinking != current.thinking
        }

        /// Keep the native container and its cleared reuse pool warm across selections.
        /// No old message, prepared document or selection is retained in a reused row.
        private func resetForSelection() {
            navigationGeneration &+= 1
            hasInstalledSnapshot = false
            parent.readingState.expandedActivityIDs = state.expandedActivity
            parent.readingState.leave()
            scheduler.cancel()
            list.cancelCurrentScrolling()
            selectionDrag = nil
            bottomAlignmentUntil = 0
            restorationUntil = 0
            restorationAnchor = nil
            pendingHeightIDs.removeAll()
            lastUserID = nil
            lastViewportSize = .zero
            contents.removeAll()
            contentOrder.removeAll()
            heights.removeAll()
            measurementSignatures.removeAll()
            measurement.clearContent()
            for row in rowViews.allObjects { row.clearContent() }
            list.apply([], animated: false)
            state = NativeTranscriptState()
        }

        private var sourceMessageID: String? {
            if let reveal = parent.revealedMessageID,
               parent.items.contains(where: { $0.message?.id == reveal && $0.role == .user && $0.status == .completed }) {
                return "message:\(reveal.rawValue.uuidString)"
            }
            return nil
        }

        private func revealMessageIfNeeded() {
            if hasInstalledSnapshot, let reveal = parent.revealedMessageID, let id = sourceMessageID {
                let origin = conversationID
                let generation = navigationGeneration
                Task { @MainActor [weak self] in
                    guard let self, isMounted, parent.isActive, parent.page.isActive, parent.revealedMessageID == reveal, conversationID == origin,
                          parent.page.conversationID == origin, navigationGeneration == generation else { return }
                    navigationGeneration &+= 1
                    scheduler.cancel()
                    bottomAlignmentUntil = 0
                    restorationUntil = 0
                    parent.readingState.userStartedScrolling()
                    parent.readingState.scrollState.revealHistory()
                    list.scrollToRow(with: id, at: .middle, animated: false)
                    parent.revealedMessageID = nil
                    recordAnchor()
                }
            }
        }

        private func cacheHeight(_ height: CGFloat, width: CGFloat, id: String) {
            heights[id] = (width, height)
            guard let signature = measurementSignatures[id] else { return }
            parent.readingState.rowMeasurements[id] = .init(signature: signature, width: width, height: height)
        }

        /// Install estimates in an empty viewport, then measure only the destination rows.
        /// Positioning completes in the native layout pass before those rows are displayed.
        private func layoutViewport() {
            guard isMounted, parent.isActive, !isPositioning, !state.tokens.isEmpty,
                  viewport.bounds.width > 0, viewport.bounds.height > 0,
                  parent.bottomOverlayHeight > 0 else { return }
            isPositioning = true
            defer { isPositioning = false }
            if !hasInstalledSnapshot {
                list.frame = CGRect(x: 0, y: 0, width: viewport.bounds.width, height: 0)
                list.apply(state.tokens, animated: false)
                list.frame = viewport.bounds
                let reading = parent.readingState
                let sourceID = sourceMessageID
                let restoring = sourceID == nil && reading.pendingRestoreOffset != nil
                restorationAnchor = restoring ? reading.nativeAnchor : nil
                // Visible-row measurement may change estimates. Resolve against the same
                // anchor on each pass, rather than showing an intermediate top position.
                for _ in 0..<8 {
                    let y: CGFloat
                    if let sourceID {
                        list.scrollToRow(with: sourceID, at: .middle, animated: false)
                        y = list.contentOffset.y
                    } else if restoring, let anchor = reading.nativeAnchor, state.items[anchor.id] != nil {
                        y = list.rectForRow(with: anchor.id).minY + anchor.offset
                    } else if let offset = reading.pendingRestoreOffset { y = offset }
                    else { y = list.maximumContentOffset.y }
                    list.setContentOffset(CGPoint(x: 0, y: min(list.maximumContentOffset.y, max(list.minimumContentOffset.y, y))), animated: false)
                    let previousSize = list.listContentSize
                    list.layoutSubtreeIfNeeded()
                    if previousSize == list.listContentSize, abs(list.contentOffset.y - y) < 0.5 { break }
                }
                hasInstalledSnapshot = true
                reading.completeRestoration()
                bottomAlignmentUntil = restoring || sourceID != nil ? 0 : ProcessInfo.processInfo.systemUptime + 0.5
                restorationUntil = restoring ? ProcessInfo.processInfo.systemUptime + 0.5 : 0
                reading.scrollState.updateVisiblePosition(isNearLatest: TranscriptViewportLayout.isNearLatest(in: list))
                lastViewportSize = list.viewportSize
                recordAnchor()
                revealMessageIfNeeded()
            }
            alignLatestIfNeeded()
            alignRestorationIfNeeded()
        }

        private func alignRestorationIfNeeded() {
            guard hasInstalledSnapshot, ProcessInfo.processInfo.systemUptime < restorationUntil,
                  let anchor = restorationAnchor, state.items[anchor.id] != nil,
                  !parent.readingState.scrollState.isUserScrolling, !list.isScrollOffsetOwnedByUser else { return }
            let y = list.rectForRow(with: anchor.id).minY + anchor.offset
            let target = min(list.maximumContentOffset.y, max(list.minimumContentOffset.y, y))
            if abs(list.contentOffset.y - target) > 0.5 {
                list.setContentOffset(CGPoint(x: 0, y: target), animated: false)
                list.layoutSubtreeIfNeeded()
            }
        }

        private func alignLatestIfNeeded() {
            guard hasInstalledSnapshot, ProcessInfo.processInfo.systemUptime < bottomAlignmentUntil,
                  !parent.readingState.scrollState.isUserScrolling, !list.isScrollOffsetOwnedByUser else { return }
            for _ in 0..<8 {
                let target = list.maximumContentOffset
                list.setContentOffset(target, animated: false)
                list.layoutSubtreeIfNeeded()
                if list.maximumContentOffset == target { break }
            }
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
            let origin = conversationID
            let contentGeneration = parent.contentGeneration
            if !measuring { rowViews.add(row) }
            let visible = item.role == .assistant
            let expanded = state.expandedActivity.contains(item.id)
            var reasoningSource = ""
            if visible && expanded {
                reasoningSource = item.thinking
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
                    MemoryDeletionStatusView(requests: item.memoryDeletions)
                    if let executionID = item.executionID, let conversationID {
                        TranscriptCitations(text: item.text, executionID: executionID, conversationID: conversationID,
                                           model: parent.model, memoryNotices: item.memoryNotices).equatable()
                    }
                }.environment(\.locale, parent.locale))
            } else { auxiliary = AnyView(EmptyView()) }
            row.onHeightChange = measuring ? nil : { [weak self, weak row] height in
                guard let self, let row, isMounted, parent.isActive, parent.page.isActive,
                      conversationID == origin, parent.contentGeneration == contentGeneration else { return }
                let width = row.bounds.width
                guard heights[item.id]?.width != width || heights[item.id]?.height != height else { return }
                cacheHeight(height, width: width, id: item.id)
                let now = ProcessInfo.processInfo.systemUptime
                if now < bottomAlignmentUntil { bottomAlignmentUntil = now + 0.5 }
                if now < restorationUntil { restorationUntil = now + 0.5 }
                pendingHeightIDs.insert(item.id)
                scheduler.schedule { [weak self] in
                    guard let self, isMounted, parent.isActive, parent.page.isActive,
                          conversationID == origin, parent.contentGeneration == contentGeneration else { return }
                    let ids = pendingHeightIDs
                    pendingHeightIDs.removeAll()
                    for id in ids { list.invalidateLayout(forRowWith: id) }
                    viewport.needsLayout = true
                    wake()
                }
            }
            row.onToggleActivity = { [weak self] in
                guard let self, isMounted, parent.isActive, parent.page.isActive,
                      conversationID == origin, parent.contentGeneration == contentGeneration else { return }
                state.toggleActivity(item.id)
                parent.readingState.expandedActivityIDs = state.expandedActivity
                measurementSignatures[item.id] = item.measurementSignature(expanded: state.expandedActivity.contains(item.id))
                heights.removeValue(forKey: item.id)
                if let current = list.rowView(for: item.id) as? NativeTranscriptRow {
                    configure(current, token: token, measurement: false)
                }
                list.invalidateLayout(forRowWith: item.id)
                wake()
            }
            row.onToggleProcessBlock = { [weak self] blockID in
                guard let self, isMounted, parent.isActive, parent.page.isActive,
                      conversationID == origin, parent.contentGeneration == contentGeneration else { return }
                if !parent.readingState.expandedProcessBlockIDs.insert(blockID).inserted {
                    parent.readingState.expandedProcessBlockIDs.remove(blockID)
                }
                heights.removeValue(forKey: item.id)
                parent.readingState.rowMeasurements.removeValue(forKey: item.id)
                if let current = list.rowView(for: item.id) as? NativeTranscriptRow {
                    configure(current, token: token, measurement: false)
                }
                list.invalidateLayout(forRowWith: item.id)
                wake()
            }
            row.configure(item: item, body: body, reasoning: reasoning,
                          expanded: expanded, theme: theme, locale: parent.locale, reduceMotion: parent.reduceMotion,
                          measurement: measuring, auxiliary: auxiliary,
                          expandedBlocks: parent.readingState.expandedProcessBlockIDs) { [weak self] message in
                guard let self, isMounted, parent.isActive, parent.page.isActive,
                      conversationID == origin, parent.contentGeneration == contentGeneration else { return }
                parent.rememberedMessage = message
            }
        }

        private func userStartedScrolling() {
            navigationGeneration &+= 1
            bottomAlignmentUntil = 0
            restorationUntil = 0
            scheduler.cancel()
            if !parent.readingState.scrollState.isUserScrolling { list.cancelCurrentScrolling() }
            parent.readingState.userStartedScrolling()
            parent.readingState.scrollState.userScrollChanged(isScrolling: true, isNearBottom: false)
        }

        private func wake() {
            guard isMounted, parent.isActive, parent.page.isActive else { return }
            settlingUntil = ProcessInfo.processInfo.systemUptime + 0.5
            guard activity == nil else { return }
            activityGeneration &+= 1
            let generation = activityGeneration
            activity = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(16)) } catch { break }
                    guard let self, isMounted else { break }
                    observeGeometry()
                    if !parent.items.contains(where: \.isStreaming), !list.isUserInteractingWithScroll,
                       ProcessInfo.processInfo.systemUptime > settlingUntil { break }
                }
                if self?.activityGeneration == generation { self?.activity = nil }
            }
        }

        private func observeGeometry() {
            guard parent.isActive, parent.page.isActive else { return }
            guard hasInstalledSnapshot else {
                viewport.needsLayout = true
                return
            }
            let reading = parent.readingState
            if let event = selectionDrag, NSEvent.pressedMouseButtons & 1 != 0,
               let label = list.window?.firstResponder as? TextLabelView, label.isDescendant(of: list),
               let location = list.window?.mouseLocationOutsideOfEventStream {
                let point = list.convert(location, from: nil)
                let top = list.bounds.minY + parent.topOverlayHeight + 16
                let bottom = max(top, list.bounds.maxY - list.bottomContentPadding - 16)
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
            let viewportChanged = lastViewportSize != .zero && list.viewportSize != lastViewportSize
            let shouldJumpToLatest = reading.scrollState.consumePendingJumpToLatest()
            if shouldJumpToLatest {
                bottomAlignmentUntil = ProcessInfo.processInfo.systemUptime + 0.5
            } else if viewportChanged && reading.scrollState.shouldKeepBottomAlignedDuringResize() {
                bottomAlignmentUntil = ProcessInfo.processInfo.systemUptime + 0.5
            }
            // Allow deferred row measurements to finish the same positioning operation.
            // New content or a user gesture cancels this bounded correction immediately.
            alignLatestIfNeeded()
            alignRestorationIfNeeded()
            reading.scrollState.updateVisiblePosition(isNearLatest: TranscriptViewportLayout.isNearLatest(in: list))
            reading.scrollState.updateJumpVisibility(distanceToLatest: Double(TranscriptViewportLayout.distanceToLatest(in: list)))
            lastViewportSize = list.viewportSize
            recordAnchor()
        }

        private func recordAnchor() {
            guard hasInstalledSnapshot, parent.isActive, parent.page.isActive, parent.page.conversationID == conversationID else { return }
            let reading = parent.readingState
            reading.recordOffset(list.contentOffset.y)
            guard reading.pendingRestoreOffset == nil else { return }
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
    var onLayout: (() -> Void)?
    var conversationID: ConversationID?
    var isActive = false
    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override func layout() {
        super.layout()
        onLayout?()
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }
}
