import AppKit

/// Native macOS backend. The NSClipView owns the only scroll offset.
/// Virtual rows live in one document; AppKit owns wheel input and scrollbars.
open class ListScrollView: NSScrollView {
    open class Document: NSView {
        override open var isFlipped: Bool { true }
    }
    public let rowContainer = Document()
    var scrollLedger = ScrollLedger()
    private var pendingCompensation: CGFloat = 0
    private var inContentLayout = false
    private var activeLiveScroll = false
    private var gestureActive = false
    private var handlingWheel = false
    private var scrollingAnimation: Task<Void, Never>?
    public var onUserScroll: (() -> Void)?
    public var viewportSize: CGSize { .init(width: max(0, contentView.bounds.width - contentView.contentInsets.left - contentView.contentInsets.right), height: contentView.bounds.height) }
    /// Blank document space after virtual rows, without a native bottom scroll edge.
    public var bottomContentPadding: CGFloat {
        get { documentBottomPadding }
        set {
            let padding = newValue.isFinite ? max(0, newValue) : 0
            guard padding != documentBottomPadding else { return }
            let content = listContentSize
            documentBottomPadding = padding
            listContentSize = content
        }
    }
    private var documentBottomPadding: CGFloat = 0
    var adjustedContentInset: NSEdgeInsets {
        .init(top: contentInsets.top, left: contentInsets.left,
              bottom: contentInsets.bottom + bottomContentPadding, right: contentInsets.right)
    }
    var interactionLocationInViewportY: CGFloat? { nil }
    public var hasActiveUserInteraction: Bool { activeLiveScroll || gestureActive || handlingWheel }
    public var isScrollOffsetOwnedByUser: Bool { hasActiveUserInteraction }
    public var isReaderHoldingScroll: Bool { hasActiveUserInteraction }
    public var isUserInteractingWithScroll: Bool { hasActiveUserInteraction }
    public var isAutoScrollSuppressed: Bool { hasActiveUserInteraction }
    public var isTracking: Bool { hasActiveUserInteraction }
    var showsVerticalScrollIndicator: Bool {
        get { hasVerticalScroller }
        set { hasVerticalScroller = newValue }
    }
    public var minimumContentOffset: CGPoint { .init(x: -contentInsets.left, y: -contentInsets.top) }
    public var maximumContentOffset: CGPoint {
        .init(x: -contentInsets.left, y: max(minimumContentOffset.y, rowContainer.frame.height - viewportSize.height + contentInsets.bottom))
    }
    public var contentOffset: CGPoint {
        get { .init(x: contentView.bounds.minX, y: contentView.bounds.minY + pendingCompensation) }
        set {
            cancelCurrentScrolling()
            pendingCompensation = 0
            moveClip(to: newValue)
        }
    }
    // NSScrollView.contentSize means viewport size. Do not override its meaning.
    public var listContentSize: CGSize {
        get { .init(width: rowContainer.frame.width, height: max(0, rowContainer.frame.height - bottomContentPadding)) }
        set {
            let target = contentOffset
            let size = CGSize(width: viewportSize.width, height: max(0, newValue.height) + bottomContentPadding)
            let changed = rowContainer.frame.size != size
            let compensated = pendingCompensation != 0
            if changed { rowContainer.setFrameSize(size) }
            pendingCompensation = 0
            // An unchanged document must not clamp AppKit's live elastic offset.
            if changed || compensated {
                moveClip(to: hasActiveUserInteraction ? target : nearestScrollLocationInBounds(offset: target))
            }
        }
    }
    override public init(frame: CGRect) {
        super.init(frame: frame)
        drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = true
        hasHorizontalScroller = false
        scrollerStyle = .overlay
        autohidesScrollers = true
        automaticallyAdjustsContentInsets = true
        documentView = rowContainer
        contentView.drawsBackground = false
        contentView.postsBoundsChangedNotifications = true
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(liveScrollStarted), name: NSScrollView.willStartLiveScrollNotification, object: self)
        center.addObserver(self, selector: #selector(liveScrollEnded), name: NSScrollView.didEndLiveScrollNotification, object: self)
        center.addObserver(self, selector: #selector(viewportChanged), name: NSView.boundsDidChangeNotification, object: contentView)
    }
    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    private func beginUserInteraction() {
        guard !activeLiveScroll else { return }
        activeLiveScroll = true
        cancelCurrentScrolling()
        onUserScroll?()
    }

    @objc private func liveScrollStarted() { beginUserInteraction() }
    @objc private func liveScrollEnded() { activeLiveScroll = false }
    @objc private func viewportChanged() {
        guard !inContentLayout else { return }
        needsLayout = true
        // Service visible-row creation in the native scrolling turn.
        layoutSubtreeIfNeeded()
    }
    override open func layout() {
        super.layout()
        guard !inContentLayout, viewportSize.width > 0, viewportSize.height > 0 else { return }
        inContentLayout = true
        defer { inContentLayout = false }
        scrollLedger.accrue(offsetY: contentOffset.y)
        layoutContent()
    }
    open func layoutContent() {}
    func compensateScrollOffset(by dy: CGFloat) {
        guard dy.isFinite, dy != 0 else { return }
        // Flush only after the new document height is installed; otherwise AppKit
        // can clamp the correction against the previous document geometry.
        pendingCompensation += dy
        scrollLedger.exclude(dy)
    }
    public func nearestScrollLocationInBounds(offset: CGPoint) -> CGPoint {
        .init(x: -contentInsets.left, y: min(max(offset.y, minimumContentOffset.y), maximumContentOffset.y))
    }
    private func moveClip(to offset: CGPoint) {
        contentView.scroll(to: offset)
        reflectScrolledClipView(contentView)
        needsLayout = true
    }
    public func setContentOffset(_ offset: CGPoint, animated: Bool) {
        cancelCurrentScrolling()
        let target = nearestScrollLocationInBounds(offset: offset)
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            contentOffset = target
            return
        }
        let start = contentOffset
        let began = ProcessInfo.processInfo.systemUptime
        scrollingAnimation = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
                guard let self, !Task.isCancelled else { return }
                let progress = min(1, (ProcessInfo.processInfo.systemUptime - began) / 0.2)
                let eased = progress * progress * (3 - 2 * progress)
                let point = CGPoint(x: target.x, y: start.y + (target.y - start.y) * eased)
                moveClip(to: nearestScrollLocationInBounds(offset: point))
                if progress == 1 { scrollingAnimation = nil; return }
            }
        }
    }
    func scroll(to offset: CGPoint) { setContentOffset(offset, animated: true) }
    public func cancelScrollingAnimation() {
        scrollingAnimation?.cancel()
        scrollingAnimation = nil
    }
    public func cancelCurrentScrolling() { cancelScrollingAnimation() }
    func isScrolledToBottom(tolerance: CGFloat = 1) -> Bool { maximumContentOffset.y - contentOffset.y <= max(0, tolerance) }
    override open func scrollWheel(with event: NSEvent) {
        handlingWheel = true
        cancelCurrentScrolling()
        onUserScroll?()
        if !event.phase.isEmpty {
            gestureActive = !event.phase.contains(.ended) && !event.phase.contains(.cancelled)
        }
        if !event.momentumPhase.isEmpty {
            gestureActive = !event.momentumPhase.contains(.ended) && !event.momentumPhase.contains(.cancelled)
        }
        super.scrollWheel(with: event)
        handlingWheel = false
    }

    deinit { scrollingAnimation?.cancel(); NotificationCenter.default.removeObserver(self) }
}
