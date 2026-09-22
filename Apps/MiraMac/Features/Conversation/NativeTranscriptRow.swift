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
    private let disclosure = MiraHoverDisclosureButton(title: "", target: nil, action: nil)
    private var item: TranscriptItem?
    private var headerContent = AnyView(EmptyView())
    private var footerContent = AnyView(EmptyView())
    private var hostingWidth: CGFloat = -1
    private var expanded = false
    private var measurement = false
    private var footerEstimate: CGFloat = 0
    private var assistantRow = false
    private var processViews: [String: NativeProcessBlockView] = [:]
    private var displayedEntries: [TranscriptProcessEntry] = []
    var onToggleProcessBlock: ((String) -> Void)?
    var onHeightChange: ((CGFloat) -> Void)?
    var onToggleActivity: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        // The row owns its frames; only intrinsic height participates in measurement.
        header.sizingOptions = [.intrinsicContentSize]
        footer.sizingOptions = [.intrinsicContentSize]
        [header, disclosure, thinking, answer, footer].forEach { addSubview($0) }
        disclosure.bezelStyle = .inline
        disclosure.isBordered = false
        disclosure.alignment = .left
        disclosure.font = .systemFont(ofSize: 13)
        // Preserve both the status prefix and the newest activity at the end.
        disclosure.lineBreakMode = .byTruncatingMiddle
        disclosure.setAccessibilityIdentifier("conversation.activity")
        disclosure.target = self
        disclosure.action = #selector(toggleActivity)
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
                   expanded: Bool, theme: MarkdownTheme, locale: Locale,
                   reduceMotion: Bool, measurement: Bool, auxiliary: AnyView,
                   expandedBlocks: Set<String> = [],
                   remember: @escaping (SessionQueryMessage) -> Void) {
        if self.item?.id != item.id {
            answer.prepareForReuse()
            thinking.prepareForReuse()
            clearProcess()
        }
        self.item = item
        self.expanded = expanded
        self.measurement = measurement
        let assistant = item.role == .assistant
        assistantRow = assistant
        let ordered = assistant && !item.steps.isEmpty
        let hasThinking = assistant && !ordered && !item.thinking.isEmpty
        let activeThinking = item.isThinking
        let canExpand = ordered ? !item.processEntries.isEmpty : hasThinking
        disclosure.isHidden = !assistant || (ordered && item.isStreaming && !item.orderedBlocks.isEmpty)
        disclosure.isEnabled = canExpand
        let title = L10n.string(item.activityTitle, locale: locale)
        let preview: String
        if !item.isStreaming, !item.processEntries.isEmpty {
            let calls = item.processEntries.filter { if case .tool = $0.block.content { return true }; return false }.count
            let messages = item.processEntries.filter { if case .text = $0.block.content { return true }; return false }.count
            if calls == 0 && messages == 0 {
                preview = L10n.string("Thought for a while", locale: locale)
            } else if calls == 0 {
                preview = L10n.format("%lld messages", locale: locale, Int64(messages))
            } else if messages == 0 {
                preview = L10n.format("%lld tool calls", locale: locale, Int64(calls))
            } else {
                preview = L10n.format("%lld tool calls · %lld messages", locale: locale, Int64(calls), Int64(messages))
            }
        } else { preview = ordered || expanded ? "" : item.activityPreview }
        let processOpen = ordered ? item.isStreaming || expanded : expanded
        disclosure.isExpanded = processOpen
        let label = title
            + (preview.isEmpty ? "" : " · " + preview)
        disclosure.attributedTitle = NSAttributedString(string: label, attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor(MiraTheme.Colors.secondaryText)
        ])
        disclosure.setAccessibilityLabel(title)
        disclosure.toolTip = preview.isEmpty ? title : title + " · " + preview
        disclosure.setAccessibilityValue(processOpen ? 1 : 0)
        thinking.isHidden = !hasThinking || !expanded
        let representedAnswer = item.steps.last.map { step in
            (item.finalStepID == step.id || item.isStreaming) && step.blocks.compactMap { block -> String? in
                if case .text(let content) = block.content { return content.text }; return nil
            }.joined() == item.text
        } ?? false
        answer.isHidden = (ordered && representedAnswer) || !assistant || item.text.isEmpty
        if let body, !answer.isHidden {
            answer.apply(content: body, source: item.text, theme: theme, locale: locale,
                         isStreaming: item.isStreaming && !measurement, reduceMotion: reduceMotion)
        } else { answer.prepareForReuse() }
        if let reasoning, !thinking.isHidden {
            thinking.apply(content: reasoning, source: item.thinking, theme: theme, locale: locale,
                           isStreaming: activeThinking && !measurement, reduceMotion: reduceMotion)
        } else { thinking.prepareForReuse() }

        displayedEntries = ordered
            ? ((item.isStreaming || expanded ? item.processEntries : []) + item.finalEntries) : []
        let retained = Set(displayedEntries.map(\.id))
        for id in Array(processViews.keys) where !retained.contains(id) {
            processViews.removeValue(forKey: id)?.removeFromSuperview()
        }
        for view in processViews.values { view.isHidden = true }
        for entry in displayedEntries {
            let view = processViews[entry.id] ?? NativeProcessBlockView()
            if processViews[entry.id] == nil { processViews[entry.id] = view; addSubview(view) }
            view.isHidden = false
            view.configure(entry, expanded: expandedBlocks.contains(entry.id), phase: item.outputPhase,
                           theme: theme, locale: locale, reduceMotion: reduceMotion, measurement: measurement)
            view.onToggle = { [weak self] in self?.onToggleProcessBlock?(entry.id) }
            view.onLayout = { [weak self] in self?.needsLayout = true }
        }

        header.isHidden = assistant
        if assistant {
            headerContent = AnyView(EmptyView())
        } else {
            headerContent = AnyView(MessageRow(role: item.role, text: item.text, status: item.status)
                .contextMenu {
                    if let message = item.message, item.role == .user, message.summary.role == .user,
                       case .available = message.body {
                        Button("Remember this message…", systemImage: "brain") { remember(message) }
                    }
                }.environment(\.locale, locale).foregroundStyle(MiraTheme.Colors.text))
        }
        let citationEstimate = CGFloat(MemoryCitationReference.references(in: item.text).count
            + SourceCitationReference.references(in: item.text).count) * 24
        let noticeEstimate: CGFloat = item.memoryNotices.isEmpty ? 0 : 28
        let deletionEstimate = item.estimatedMemoryDeletionHeight
        footerEstimate = assistant ? citationEstimate + noticeEstimate + deletionEstimate : 0
        footerContent = auxiliary
        if footerEstimate == 0 {
            footer.rootView = AnyView(EmptyView())
            footer.isHidden = true
        }
        hostingWidth = -1
        needsLayout = true
    }

    private func clearProcess() {
        for view in processViews.values { view.removeFromSuperview() }
        processViews = [:]
        displayedEntries = []
    }

    func clearContent() {
        clearProcess()
        onToggleProcessBlock = nil
        answer.prepareForReuse()
        thinking.prepareForReuse()
        item = nil
        headerContent = AnyView(EmptyView())
        footerContent = AnyView(EmptyView())
        header.rootView = AnyView(EmptyView())
        footer.rootView = AnyView(EmptyView())
        disclosure.attributedTitle = NSAttributedString(string: "")
        disclosure.toolTip = nil
        disclosure.setAccessibilityLabel(nil)
        onHeightChange = nil
        onToggleActivity = nil
        hostingWidth = -1
    }

    private func updateHosting(width: CGFloat) {
        guard hostingWidth != width else { return }
        hostingWidth = width
        header.rootView = AnyView(headerContent.frame(width: width, alignment: .leading).fixedSize(horizontal: false, vertical: true))
        if !measurement, footerEstimate > 0 {
            footer.rootView = AnyView(footerContent.frame(width: max(1, width), alignment: .leading)
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
        let bodyWidth = max(1, contentWidth)
        updateHosting(width: contentWidth)
        var y: CGFloat = assistantRow ? 0 : ceil(header.fittingSize.height)
        if place { header.frame = NSRect(x: x, y: 0, width: contentWidth, height: y) }
        if !disclosure.isHidden {
            if place { disclosure.frame = NSRect(x: x, y: y, width: bodyWidth, height: 22) }
            y += 22
            if !thinking.isHidden {
                let height = thinking.fittingHeight(width: bodyWidth)
                if place { thinking.frame = NSRect(x: x, y: y + 8, width: bodyWidth, height: height) }
                y += height + 8
            }
        }
        for entry in displayedEntries {
            guard let view = processViews[entry.id] else { continue }
            let height = view.fittingHeight(width: bodyWidth)
            if place { view.frame = NSRect(x: x, y: y + 9, width: bodyWidth, height: height) }
            y += height + 9
        }
        if !answer.isHidden {
            let height = answer.fittingHeight(width: bodyWidth)
            if place { answer.frame = NSRect(x: x, y: y + 9, width: bodyWidth, height: height) }
            y += height + 9
        }
        let footerHeight = measurement ? footerEstimate : (footerEstimate > 0 ? ceil(footer.fittingSize.height) : 0)
        if footerHeight > 0 {
            if place { footer.frame = NSRect(x: x, y: y + 10, width: bodyWidth, height: footerHeight) }
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

    @objc private func toggleActivity() { onToggleActivity?() }
}

extension SessionToolActivityStatus {
    var displayTitle: String {
        switch self {
        case .queued: "Queued"
        case .waitingForApproval: "Waiting for approval"
        case .running: "Running"
        case .succeeded: "Completed"
        case .failed: "Failed"
        case .stopped: "Stopped"
        }
    }
}

/// A stable native seat for one reasoning, text, or correlated tool block.
/// Tool details use one selectable input/output card, matching the generic DSH row.
@MainActor
private final class NativeProcessBlockView: NSView {
    override var isFlipped: Bool { true }
    private let disclosure = MiraHoverDisclosureButton(title: "", target: nil, action: nil)
    private let body = MiraMarkdownView()
    private let toolDetails = NativeToolIOView()
    private var cache: [String: (source: String, theme: MarkdownTheme, locale: Locale, content: MarkdownContent)] = [:]
    var onToggle: (() -> Void)?
    var onLayout: (() -> Void)?

    init() {
        super.init(frame: .zero)
        [disclosure, body, toolDetails].forEach { addSubview($0) }
        disclosure.bezelStyle = .inline
        disclosure.isBordered = false
        disclosure.alignment = .left
        disclosure.lineBreakMode = .byTruncatingMiddle
        disclosure.target = self
        disclosure.action = #selector(toggle)
        body.onLayoutChange = { [weak self] in self?.onLayout?() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

    func configure(_ entry: TranscriptProcessEntry, expanded: Bool, phase: SessionOutputPhase,
                   theme: MarkdownTheme, locale: Locale, reduceMotion: Bool, measurement: Bool) {
        disclosure.isHidden = false
        disclosure.image = nil
        toolDetails.isHidden = true
        var source: String?
        var title = ""
        var summary = ""
        var streaming = false
        switch entry.block.content {
        case .text(let text):
            disclosure.isHidden = true
            source = display(text, locale: locale)
            streaming = entry.isLive && phase == .answering
        case .thinking(let text):
            title = L10n.string(entry.isLive && phase == .thinking ? "Thinking…" : "Thinking", locale: locale)
            let visible = display(text, locale: locale)
            summary = entry.isLive && phase == .thinking ? TranscriptItem.latestLine(visible)
                : TranscriptItem.singleLine(visible.split(whereSeparator: \.isNewline).first.map(String.init) ?? "")
            summary = summary.replacingOccurrences(of: "**", with: "")
            if expanded { source = visible; summary = "" }
            streaming = entry.isLive && phase == .thinking
        case .tool(let tool):
            title = L10n.string("Tool call", locale: locale)
            let arguments = tool.arguments.text ?? ""
            var detail = arguments
            if let values = try? JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any],
               let text = values.keys.sorted().compactMap({ values[$0] as? String }).first(where: { !$0.isEmpty }) {
                detail = text
            }
            summary = TranscriptItem.singleLine(tool.toolName + " · " + detail)
            if tool.status == .failed, let error = tool.result.text, !error.isEmpty {
                summary = TranscriptItem.singleLine(error.split(whereSeparator: \.isNewline).first.map(String.init) ?? error)
            }
            let symbol = tool.status == .failed ? "xmark.circle.fill" : "wrench.fill"
            disclosure.image = NSImage(systemSymbolName: symbol, accessibilityDescription: L10n.string(tool.status.displayTitle, locale: locale))
            disclosure.imagePosition = .imageLeading
            if expanded {
                let hasOutput = tool.result != .absent || [.succeeded, .failed, .stopped].contains(tool.status)
                toolDetails.configure(input: display(tool.arguments, locale: locale),
                    output: hasOutput ? display(tool.result, locale: locale) : nil, locale: locale)
            }
        }
        disclosure.isExpanded = expanded
        disclosure.font = .systemFont(ofSize: 13)
        let failed: Bool
        if case .tool(let tool) = entry.block.content { failed = tool.status == .failed }
        else { failed = false }
        let label = title + (summary.isEmpty ? "" : " · " + summary)
        if toolDetails.isHidden { toolDetails.clear() }
        disclosure.attributedTitle = NSAttributedString(string: label, attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor(failed ? MiraTheme.Colors.failure : MiraTheme.Colors.secondaryText)
        ])
        let status: String
        if case .tool(let tool) = entry.block.content { status = " · " + L10n.string(tool.status.displayTitle, locale: locale) }
        else { status = "" }
        disclosure.setAccessibilityLabel(title + status)
        disclosure.setAccessibilityIdentifier("conversation.process." + entry.id)
        disclosure.setAccessibilityValue(expanded ? 1 : 0)
        disclosure.toolTip = title + " · " + summary
        apply(source, to: body, key: "body", theme: theme, locale: locale,
              streaming: streaming && !measurement, reduceMotion: reduceMotion)
        needsLayout = true
    }

    private func display(_ value: SessionTextContent, locale: Locale) -> String {
        switch value {
        case .available(let text): return text
        case .absent: return L10n.string("Content unavailable", locale: locale)
        }
    }

    private func apply(_ source: String?, to view: MiraMarkdownView, key: String,
                       theme: MarkdownTheme, locale: Locale, streaming: Bool, reduceMotion: Bool) {
        guard let source, !source.isEmpty else {
            view.isHidden = true
            view.prepareForReuse()
            cache.removeValue(forKey: key)
            return
        }
        view.isHidden = false
        let prepared: MarkdownContent
        if let previous = cache[key], previous.source == source, previous.theme == theme, previous.locale == locale {
            prepared = previous.content
        } else {
            prepared = MarkdownContent(markdown: source, theme: theme, locale: locale)
            cache[key] = (source, theme, locale, prepared)
        }
        view.apply(content: prepared, source: source, theme: theme, locale: locale,
                   isStreaming: streaming, reduceMotion: reduceMotion)
    }

    func fittingHeight(width: CGFloat, place: Bool = false) -> CGFloat {
        var y: CGFloat = 0
        if !disclosure.isHidden {
            if place { disclosure.frame = NSRect(x: 0, y: y, width: width, height: 22) }
            y += 22
        }
        for view in [body] {
            if !view.isHidden {
                let inset: CGFloat = disclosure.isHidden ? 0 : 12
                let height = view.fittingHeight(width: max(1, width - inset))
                if place { view.frame = NSRect(x: inset, y: y + (y > 0 ? 6 : 0), width: max(1, width - inset), height: height) }
                y += height + (y > 0 ? 6 : 0)
            }
        }
        if !toolDetails.isHidden {
            let inset: CGFloat = 12
            let height = toolDetails.fittingHeight(width: max(1, width - inset))
            if place { toolDetails.frame = NSRect(x: inset, y: y + 6, width: max(1, width - inset), height: height) }
            y += height + 6
        }
        return ceil(y)
    }

    override func layout() { super.layout(); _ = fittingHeight(width: bounds.width, place: true) }
    @objc private func toggle() { onToggle?() }
}

@MainActor
private final class NativeToolIOView: NSView {
    override var isFlipped: Bool { true }
    private let inputLabel = NSTextField(labelWithString: "")
    private let outputLabel = NSTextField(labelWithString: "")
    private let input = NSTextField(wrappingLabelWithString: "")
    private let output = NSTextField(wrappingLabelWithString: "")
    private let inputScroll = NSScrollView()
    private let outputScroll = NSScrollView()
    private let divider = NSBox()
    private var inputIsJSON = false
    private var outputIsJSON = false

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        divider.boxType = .separator
        for field in [inputLabel, outputLabel] {
            field.font = .systemFont(ofSize: 11, weight: .medium)
            field.textColor = NSColor(MiraTheme.Colors.secondaryText)
        }
        for field in [input, output] {
            field.font = .monospacedSystemFont(ofSize: MiraTheme.Markdown.code, weight: .regular)
            field.textColor = NSColor(MiraTheme.Colors.text)
            field.isSelectable = true
            field.maximumNumberOfLines = 0
            field.setAccessibilityElement(true)
            field.setAccessibilityRole(.staticText)
        }
        for (scroll, field) in [(inputScroll, input), (outputScroll, output)] {
            scroll.drawsBackground = false
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.setAccessibilityIdentifier("conversation.toolIO")
            scroll.documentView = field
        }
        [inputLabel, inputScroll, divider, outputLabel, outputScroll].forEach { addSubview($0) }
        clear()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

    func configure(input: String, output: String?, locale: Locale) {
        isHidden = false
        let (input, inputJSON) = compactJSON(input)
        let (outputText, outputJSON) = compactJSON(output ?? "")
        inputIsJSON = inputJSON
        outputIsJSON = outputJSON
        let output = output.map { _ in outputText }
        for (field, scroll, json) in [(self.input, inputScroll, inputJSON), (self.output, outputScroll, outputJSON)] {
            field.maximumNumberOfLines = json ? 1 : 0
            field.lineBreakMode = json ? .byClipping : .byWordWrapping
            scroll.hasHorizontalScroller = json
            scroll.hasVerticalScroller = !json
            scroll.scrollerStyle = .overlay
        }
        inputLabel.stringValue = L10n.string("Input", locale: locale)
        outputLabel.stringValue = L10n.string("Output", locale: locale)
        if self.input.stringValue != input { self.input.stringValue = input }
        if self.output.stringValue != (output ?? "") { self.output.stringValue = output ?? "" }
        self.input.setAccessibilityValue(input)
        self.output.setAccessibilityValue(output ?? "")
        outputLabel.isHidden = output == nil
        self.output.isHidden = output == nil
        outputScroll.isHidden = output == nil
        divider.isHidden = output == nil
        needsLayout = true
    }

    func clear() {
        isHidden = true
        input.stringValue = ""
        output.stringValue = ""
        input.setAccessibilityValue("")
        output.setAccessibilityValue("")
    }

    /// Remove JSON whitespace outside strings without rewriting numbers or escapes.
    private func compactJSON(_ text: String) -> (String, Bool) {
        guard (try? JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed)) != nil else {
            return (text, false)
        }
        var quoted = false, escaped = false
        var result = ""
        for character in text.unicodeScalars {
            if quoted {
                result.unicodeScalars.append(character)
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { quoted = false }
            } else if character == "\"" {
                quoted = true
                result.unicodeScalars.append(character)
            } else if ![0x20, 0x0A, 0x0D, 0x09].contains(character.value) {
                result.unicodeScalars.append(character)
            }
        }
        return (result, true)
    }

    func fittingHeight(width: CGFloat, place: Bool = false) -> CGFloat {
        let gutter = max(inputLabel.fittingSize.width, outputLabel.fittingSize.width)
        let inner = max(1, width - 32 - gutter - 14)
        var y: CGFloat = 0
        for (label, field, scroll) in [(inputLabel, input, inputScroll), (outputLabel, output, outputScroll)] where !field.isHidden {
            if field === output {
                if place { divider.frame = NSRect(x: 0, y: y, width: width, height: 1) }
                y += 1
            }
            if place { label.frame = NSRect(x: 16, y: y + 12, width: gutter, height: 16) }
            let json = field === input ? inputIsJSON : outputIsJSON
            let documentWidth = json ? max(inner, ceil((field.stringValue as NSString).size(withAttributes: [.font: field.font ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)]).width) + 4) : inner
            let height = ceil(field.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: documentWidth, height: .greatestFiniteMagnitude)).height ?? 0)
            let visibleHeight = min(126, max(16, height))
            if place {
                scroll.frame = NSRect(x: 16 + gutter + 14, y: y + 12, width: inner, height: visibleHeight)
                field.frame = NSRect(x: 0, y: 0, width: documentWidth, height: max(16, height))
            }
            y += visibleHeight + 24
        }
        return y
    }

    override func layout() {
        super.layout()
        layer?.backgroundColor = NSColor(MiraTheme.Colors.inset).cgColor
        layer?.borderColor = NSColor(MiraTheme.Colors.border).cgColor
        layer?.borderWidth = 1
        _ = fittingHeight(width: bounds.width, place: true)
    }
}
