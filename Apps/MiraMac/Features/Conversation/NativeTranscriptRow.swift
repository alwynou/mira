import AppKit
import SwiftUI
import MarkdownView
import ListViewKit
import MiraCore

/// Only visible rows own text views. The list's measurement view is shared.
@MainActor
final class NativeTranscriptRow: ListRowView {
    private let header = NSHostingView(rootView: AnyView(EmptyView()))
    private let footer = NSHostingView(rootView: AnyView(EmptyView()))
    private let answer = MiraMarkdownView()
    private let thinking = MiraMarkdownView()
    private let disclosure = NSButton(title: "", target: nil, action: nil)
    private var item: TranscriptItem?
    private var headerContent = AnyView(EmptyView())
    private var footerContent = AnyView(EmptyView())
    private var hostingWidth: CGFloat = -1
    private var expanded = false
    private var measurement = false
    private var footerEstimate: CGFloat = 0
    var onHeightChange: ((CGFloat) -> Void)?
    var onToggleThinking: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        [header, disclosure, thinking, answer, footer].forEach { addSubview($0) }
        disclosure.bezelStyle = .inline
        disclosure.isBordered = false
        disclosure.alignment = .left
        disclosure.font = .systemFont(ofSize: 13)
        disclosure.target = self
        disclosure.action = #selector(toggleThinking)
        answer.onLayoutChange = { [weak self] in self?.needsLayout = true }
        thinking.onLayoutChange = { [weak self] in self?.needsLayout = true }
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

    // Mounted same-ID updates skip reuse; pooled rows must release selection and content.
    override func prepareForReuse() {
        super.prepareForReuse()
        clearContent()
    }

    func configure(item: TranscriptItem, body: MarkdownContent?, reasoning: MarkdownContent?,
                   reasoningSource: String, expanded: Bool, theme: MarkdownTheme, locale: Locale,
                   reduceMotion: Bool, measurement: Bool, auxiliary: AnyView,
                   remember: @escaping (Message) -> Void) {
        if self.item?.id != item.id || item.bodyPurgedAt != nil {
            answer.prepareForReuse()
            thinking.prepareForReuse()
        }
        self.item = item
        self.expanded = expanded
        self.measurement = measurement
        let assistant = item.role == .assistant && item.bodyPurgedAt == nil
        let hasThinking = assistant && item.trace.contains { $0.reasoning != nil }
        let activeThinking = item.isStreaming && item.trace.last?.reasoning?.isComplete == false
        disclosure.isHidden = !hasThinking
        disclosure.title = (expanded ? "▾ " : "▸ ") + L10n.string(activeThinking ? "Thinking…" : "Thinking", locale: locale)
        disclosure.setAccessibilityLabel(L10n.string(activeThinking ? "Thinking…" : "Thinking", locale: locale))
        disclosure.setAccessibilityValue(expanded ? 1 : 0)
        thinking.isHidden = !hasThinking || !expanded
        answer.isHidden = !assistant || item.text.isEmpty
        if let body, !answer.isHidden {
            answer.apply(content: body, source: item.text, theme: theme, locale: locale,
                         isStreaming: item.isStreaming && !measurement, reduceMotion: reduceMotion)
        } else { answer.prepareForReuse() }
        if let reasoning, !thinking.isHidden {
            thinking.apply(content: reasoning, source: reasoningSource, theme: theme, locale: locale,
                           isStreaming: activeThinking && !measurement, reduceMotion: reduceMotion)
        } else { thinking.prepareForReuse() }

        if item.bodyPurgedAt != nil {
            headerContent = AnyView(Label("Reply content cleared after forgetting a memory", systemImage: "eye.slash")
                .font(.callout).foregroundStyle(.secondary).environment(\.locale, locale))
        } else if assistant {
            headerContent = AnyView(HStack(alignment: .top, spacing: 12) {
                MiraBrandMark().frame(width: 28, height: 24)
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 8) {
                        Text("Mira").font(MiraTheme.Typography.body.weight(.semibold))
                        if let status = item.status, status != .committed {
                            Text("Incomplete").font(.caption).foregroundStyle(.orange)
                        }
                    }.frame(height: 24, alignment: .leading)
                    if item.text.isEmpty && (!item.isStreaming || !hasThinking) {
                        Text(item.isStreaming ? "Waiting for response…" : "No answer was produced.")
                            .foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.environment(\.locale, locale).foregroundStyle(MiraTheme.Colors.text))
        } else {
            headerContent = AnyView(MessageRow(role: item.role, text: item.text, status: item.status)
                .contextMenu {
                    if let message = item.message, message.role == .user, message.status == .committed {
                        Button("Remember this message…", systemImage: "brain") { remember(message) }
                    }
                }.environment(\.locale, locale).foregroundStyle(MiraTheme.Colors.text))
        }
        footerEstimate = assistant ? CGFloat(MemoryCitationReference.references(in: item.text).count
            + SourceCitationReference.references(in: item.text).count) * 24 + (item.memoryNotices.isEmpty ? 0 : 28) : 0
        footerContent = auxiliary
        hostingWidth = -1
        needsLayout = true
    }

    func clearContent() {
        answer.prepareForReuse()
        thinking.prepareForReuse()
        item = nil
        headerContent = AnyView(EmptyView())
        footerContent = AnyView(EmptyView())
        header.rootView = AnyView(EmptyView())
        footer.rootView = AnyView(EmptyView())
        onHeightChange = nil
        onToggleThinking = nil
        hostingWidth = -1
    }

    private func updateHosting(width: CGFloat) {
        guard hostingWidth != width else { return }
        hostingWidth = width
        header.rootView = AnyView(headerContent.frame(width: width, alignment: .leading).fixedSize(horizontal: false, vertical: true))
        if !measurement {
            footer.rootView = AnyView(footerContent.frame(width: max(1, width - 40), alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { proxy in
                    Color.clear.onChange(of: proxy.size.height, initial: true) { [weak self] _, _ in
                        self?.needsLayout = true
                    }
                }))
        }
    }

    func fittingHeight(width: CGFloat, place: Bool = false) -> CGFloat {
        let contentWidth = min(MiraTheme.Layout.contentMax, max(1, width - 48))
        let x = (width - contentWidth) / 2
        let bodyWidth = max(1, contentWidth - 40)
        updateHosting(width: contentWidth)
        var y = ceil(header.fittingSize.height)
        if place { header.frame = NSRect(x: x, y: 0, width: contentWidth, height: y) }
        if !disclosure.isHidden {
            y += 9
            if place { disclosure.frame = NSRect(x: x + 40, y: y, width: bodyWidth, height: 22) }
            y += 22
            if !thinking.isHidden {
                let height = thinking.fittingHeight(width: bodyWidth)
                if place { thinking.frame = NSRect(x: x + 40, y: y + 8, width: bodyWidth, height: height) }
                y += height + 8
            }
        }
        if !answer.isHidden {
            let height = answer.fittingHeight(width: bodyWidth)
            if place { answer.frame = NSRect(x: x + 40, y: y + 9, width: bodyWidth, height: height) }
            y += height + 9
        }
        let footerHeight = measurement ? footerEstimate : ceil(footer.fittingSize.height)
        if footerHeight > 0 {
            if place { footer.frame = NSRect(x: x + 40, y: y + 10, width: bodyWidth, height: footerHeight) }
            y += footerHeight + 10
        }
        footer.isHidden = measurement || footerHeight <= 0
        return ceil(y + MiraTheme.Spacing.xl)
    }

    override func layout() {
        super.layout()
        let height = fittingHeight(width: bounds.width, place: true)
        if !measurement, abs(height - bounds.height) > 0.5 { onHeightChange?(height) }
    }

    @objc private func toggleThinking() { onToggleThinking?() }
}
