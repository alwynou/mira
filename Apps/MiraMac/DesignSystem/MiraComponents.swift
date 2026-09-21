import SwiftUI
import AppKit

/// A native disclosure whose trailing affordance appears without moving its text.
final class MiraHoverDisclosureButton: NSButton {
    var isExpanded = false { didSet { needsDisplay = true } }
    private(set) var isPointerInside = false
    private var hoverTracking: NSTrackingArea?

    var showsChevron: Bool { isEnabled && (isPointerInside || window?.firstResponder === self) }
    var symbolSize: CGFloat { font?.pointSize ?? 13 }
    var textOriginX: CGFloat { image == nil ? 0 : symbolSize + 7 }
    var textOverflows: Bool { textOriginX + attributedTitle.size().width + 8 + symbolSize > bounds.width }
    var chevronFrame: NSRect {
        let x = min(textOriginX + attributedTitle.size().width + 8, max(0, bounds.width - symbolSize - 2))
        return NSRect(x: x, y: (bounds.height - symbolSize) / 2, width: symbolSize, height: symbolSize)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverTracking = area
        if let window {
            isPointerInside = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
        }
        needsDisplay = true
    }

    override func mouseEntered(with event: NSEvent) { isPointerInside = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { isPointerInside = false; needsDisplay = true }
    override func becomeFirstResponder() -> Bool { let value = super.becomeFirstResponder(); needsDisplay = true; return value }
    override func resignFirstResponder() -> Bool { let value = super.resignFirstResponder(); needsDisplay = true; return value }

    override func draw(_ dirtyRect: NSRect) {
        let color = attributedTitle.length > 0
            ? attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor ?? .secondaryLabelColor
            : NSColor.secondaryLabelColor
        NSGraphicsContext.saveGraphicsState()
        bounds.clip()
        if let image {
            drawSymbol(image, in: NSRect(x: 0, y: (bounds.height - symbolSize) / 2, width: symbolSize, height: symbolSize), color: color)
        }
        attributedTitle.draw(at: NSPoint(x: textOriginX, y: (bounds.height - attributedTitle.size().height) / 2))
        if showsChevron {
            let frame = chevronFrame
            if textOverflows {
                let background = NSColor(MiraTheme.Colors.canvas)
                let fade = NSRect(x: max(0, frame.minX - 24), y: 0, width: frame.minX - max(0, frame.minX - 24), height: bounds.height)
                NSGradient(starting: background.withAlphaComponent(0), ending: background)?.draw(in: fade, angle: 0)
                background.setFill()
                NSRect(x: frame.minX, y: 0, width: bounds.width - frame.minX, height: bounds.height).fill()
            }
            if let symbol = NSImage(systemSymbolName: isExpanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil) {
                drawSymbol(symbol, in: frame, color: NSColor(MiraTheme.Colors.secondaryText))
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        if window?.firstResponder === self {
            NSGraphicsContext.saveGraphicsState()
            NSFocusRingPlacement.only.set()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private func drawSymbol(_ image: NSImage, in frame: NSRect, color: NSColor) {
        let configuration = NSImage.SymbolConfiguration(pointSize: symbolSize, weight: .regular)
            .applying(.preferringMonochrome())
        let configured = image.withSymbolConfiguration(configuration) ?? image
        let size = configured.size
        guard size.width > 0, size.height > 0 else { return }
        let scale = min(frame.width / size.width, frame.height / size.height)
        let destination = NSRect(x: frame.midX - size.width * scale / 2,
                                 y: frame.midY - size.height * scale / 2,
                                 width: size.width * scale, height: size.height * scale)
        let tinted = NSImage(size: size, flipped: false) { rect in
            configured.draw(in: rect)
            color.setFill()
            rect.fill(using: .sourceIn)
            return true
        }
        tinted.draw(in: destination, from: .zero, operation: .sourceOver,
                    fraction: 1, respectFlipped: true, hints: nil)
    }
}

struct MiraModelPickerGroup: Identifiable {
    struct Option: Identifiable {
        let id: String
        let title: String
    }
    let id: String
    let title: String
    let options: [Option]
}

/// Native menu rows retain system typography, spacing, selection and keyboard navigation.
struct MiraModelPickerItems: View {
    let groups: [MiraModelPickerGroup]
    let selectedID: String?
    let select: (String) -> Void

    var body: some View {
        ForEach(groups) { group in
            Section {
                ForEach(group.options) { option in
                    Toggle(isOn: Binding(get: { selectedID == option.id }, set: { enabled in
                        if enabled { select(option.id) }
                    })) {
                        Text(verbatim: option.title)
                    }
                    .accessibilityIdentifier("conversation.modelOption." + option.id)
                }
            } header: {
                Text(verbatim: group.title)
            }
        }
        if groups.isEmpty {
            Text("Configure a compatible model in Providers.")
        }
    }
}

private extension EnvironmentValues {
    @Entry var miraSidebarIsPressed = false
}

struct MiraSidebarRow<Content: View>: View {
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.miraSidebarIsPressed) private var isPressed
    @State private var isHovered = false
    let isSelected: Bool
    let minimumHeight: CGFloat
    @ViewBuilder let content: () -> Content

    init(isSelected: Bool = false,
         minimumHeight: CGFloat = MiraTheme.Layout.rowHeight, @ViewBuilder content: @escaping () -> Content) {
        self.isSelected = isSelected
        self.minimumHeight = minimumHeight
        self.content = content
    }

    var body: some View {
        content()
            .font(MiraTheme.Typography.sidebar)
            .foregroundStyle(MiraTheme.Colors.text)
            .frame(maxWidth: .infinity, minHeight: minimumHeight, alignment: .leading)
            .padding(.horizontal, MiraTheme.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: MiraTheme.Radius.row, style: .continuous)
                    .fill(isHighlighted ? highlightFill : .clear)
            )
            .overlay {
                if isSelected && contrast == .increased {
                    RoundedRectangle(cornerRadius: MiraTheme.Radius.row)
                        .strokeBorder(MiraTheme.Colors.secondaryText, lineWidth: 1)
                }
            }
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .contentShape(RoundedRectangle(cornerRadius: MiraTheme.Radius.row, style: .continuous))
            .onHover { isHovered = $0 }
    }

    private var isHighlighted: Bool {
        isSelected || (isEnabled && (isHovered || isPressed))
    }

    private var highlightFill: Color {
        if reduceTransparency || contrast == .increased { return MiraTheme.Colors.sidebarHighlight }
        return MiraTheme.Colors.sidebarOverlay.opacity(MiraTheme.Opacity.sidebarHighlight)
    }
}

struct MiraRowButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        // The row draws one shared highlight, including when selection and hover overlap.
        configuration.label
            .environment(\.miraSidebarIsPressed, configuration.isPressed)
            .opacity(isEnabled ? 1 : 0.45)
    }
}

struct MiraIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        MiraInteractiveLabel(configuration: configuration, shape: RoundedRectangle(cornerRadius: MiraTheme.Radius.small, style: .continuous), size: MiraTheme.Layout.controlHeight)
    }
}

struct MiraPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(MiraTheme.Typography.body.weight(.medium))
            .foregroundStyle(MiraTheme.Colors.onAccent)
            .padding(.horizontal, MiraTheme.Spacing.lg)
            .frame(minHeight: MiraTheme.Layout.controlHeight)
            .background(MiraTheme.Colors.accent, in: RoundedRectangle(cornerRadius: MiraTheme.Radius.small, style: .continuous))
            .opacity(isEnabled ? (configuration.isPressed ? 0.72 : 1) : 0.45)
    }
}

/// A quiet bordered action for secondary commands on the canvas.
struct MiraSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(MiraTheme.Typography.body)
            .foregroundStyle(MiraTheme.Colors.text)
            .padding(.horizontal, MiraTheme.Spacing.md)
            .frame(minHeight: MiraTheme.Layout.controlHeight)
            .background(
                RoundedRectangle(cornerRadius: MiraTheme.Radius.small, style: .continuous)
                    .fill(isHovered || configuration.isPressed ? MiraTheme.Colors.inset : MiraTheme.Colors.surface)
            )
            .overlay {
                RoundedRectangle(cornerRadius: MiraTheme.Radius.small, style: .continuous)
                    .strokeBorder(MiraTheme.Colors.border, lineWidth: 1)
            }
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { isHovered = $0 }
    }
}

struct MiraCircleButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(MiraTheme.Colors.onAccent)
            .frame(width: MiraTheme.Layout.controlHeight, height: MiraTheme.Layout.controlHeight)
            .background(MiraTheme.Colors.accent, in: Circle())
            .opacity(isEnabled ? (configuration.isPressed ? 0.72 : 1) : 0.38)
            .contentShape(Circle())
    }
}

/// A neutral floating action with native Liquid Glass where available.
struct MiraGlassCircleButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func makeBody(configuration: Configuration) -> some View {
        let label = configuration.label
            .font(MiraTheme.Typography.body.weight(.semibold))
            .foregroundStyle(MiraTheme.Colors.text)
            .frame(width: MiraTheme.Layout.floatingControlSize, height: MiraTheme.Layout.floatingControlSize)
            .contentShape(Circle())
        Group {
            if reduceTransparency || contrast == .increased {
                label
                    .background(MiraTheme.Colors.surface, in: Circle())
                    .overlay { Circle().strokeBorder(MiraTheme.Colors.secondaryText, lineWidth: 1) }
            } else if #available(macOS 26.0, *) {
                label.glassEffect(.regular.interactive(), in: .circle)
            } else {
                label
                    .background(.regularMaterial, in: Circle())
                    .overlay { Circle().strokeBorder(MiraTheme.Colors.border, lineWidth: 1) }
            }
        }
        .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
    }
}

struct MiraSurface<Content: View>: View {
    let cornerRadius: CGFloat
    let fill: Color
    @ViewBuilder let content: () -> Content

    init(cornerRadius: CGFloat = MiraTheme.Radius.panel, fill: Color = MiraTheme.Colors.surface,
         @ViewBuilder content: @escaping () -> Content) {
        self.cornerRadius = cornerRadius
        self.fill = fill
        self.content = content
    }

    var body: some View {
        content()
            .background(fill, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(MiraTheme.Colors.border, lineWidth: 1)
            }
    }
}

private struct MiraInteractiveLabel<Shape: InsettableShape>: View {
    let configuration: ButtonStyleConfiguration
    let shape: Shape
    var size: CGFloat? = nil
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .frame(width: size, height: size)
            .foregroundStyle(MiraTheme.Colors.text)
            .background {
                shape.fill(interactionFill)
            }
            .opacity(isEnabled ? 1 : 0.45)
            .overlay {
                if contrast == .increased {
                    shape.stroke(MiraTheme.Colors.border, lineWidth: 1)
                }
            }
            .contentShape(shape)
            .onHover { isHovered = $0 }
    }

    private var interactionFill: Color {
        guard isEnabled, configuration.isPressed || isHovered else { return .clear }
        return configuration.isPressed ? MiraTheme.Colors.selected : MiraTheme.Colors.hover
    }
}

/// Real split accessory content. AppKit owns its scroll-edge material and layout.
@MainActor
final class MiraConversationHeaderView: NSView {
    let label = NSTextField(labelWithString: "")
    weak var detailView: NSView?
    var title: String {
        get { label.stringValue }
        set { label.stringValue = newValue; label.toolTip = newValue; needsLayout = true }
    }
    override var mouseDownCanMoveWindow: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: MiraTheme.Typography.appKitBody.pointSize, weight: .semibold)
        label.textColor = NSColor(MiraTheme.Colors.text)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.setAccessibilityIdentifier("conversation.title")
        addSubview(label)
    }
    convenience init() {
        self.init(frame: .init(x: 0, y: 0, width: 800, height: MiraTheme.Layout.conversationHeaderHeight))
    }
    required init?(coder: NSCoder) { fatalError("Storyboard initialization is unsupported.") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResizeNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(windowDidResize(_:)),
                name: NSWindow.didResizeNotification, object: window)
        }
    }
    @objc private func windowDidResize(_ notification: Notification) {
        // Native toolbar frames settle after the split content's layout callback.
        DispatchQueue.main.async { [weak self] in
            self?.needsLayout = true
            self?.layoutSubtreeIfNeeded()
        }
    }
    override func layout() {
        super.layout()
        let windowButtons = [window?.standardWindowButton(.closeButton),
                             window?.standardWindowButton(.miniaturizeButton),
                             window?.standardWindowButton(.zoomButton)].compactMap { $0 }
        let controls = windowButtons.map { convert($0.bounds, from: $0) }
        let sidebar = window?.toolbar?.items.first { $0.itemIdentifier == .toggleSidebar }?.view
        let occupiedEdge = max(controls.map(\.maxX).max() ?? 0,
                               sidebar.map { convert($0.bounds, from: $0).maxX } ?? 0)
        let detailRect = detailView.map { convert($0.safeAreaRect, from: $0) } ?? bounds
        let leading = max(detailRect.minX + MiraTheme.Spacing.lg, occupiedEdge + MiraTheme.Spacing.md)
        let actionIDs = ["conversation.new", "conversation.inspector", "conversation.knowledge"]
        let actions = window?.toolbar?.items.filter { actionIDs.contains($0.itemIdentifier.rawValue) }
            .compactMap(\.view).map { convert($0.bounds, from: $0).minX }
        let trailing = min(detailRect.maxX, actions?.min() ?? bounds.maxX) - MiraTheme.Spacing.lg
        let height = ceil(label.intrinsicContentSize.height)
        label.frame = .init(x: leading, y: (controls.last?.midY ?? bounds.midY) - height / 2,
                            width: max(0, trailing - leading), height: height)
    }
}

/// A window-local material behind the composer and its controls.
struct MiraComposerGlass: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content.background {
            let shape = RoundedRectangle(cornerRadius: MiraTheme.Radius.composer, style: .continuous)
            Group {
                if reduceTransparency || contrast == .increased {
                    shape.fill(MiraTheme.Colors.surface)
                } else {
                    MiraComposerBackdrop()
                        .clipShape(shape)
                }
            }
            .overlay {
                shape.strokeBorder(MiraTheme.Colors.border.opacity(contrast == .increased ? 1 : MiraTheme.Opacity.composerBorder), lineWidth: 1)
            }
            .shadow(color: .black.opacity(MiraTheme.Opacity.composerShadow),
                    radius: MiraTheme.Layout.composerShadowRadius, y: MiraTheme.Layout.composerShadowOffset)
            .allowsHitTesting(false)
        }
    }
}

private struct MiraComposerBackdrop: NSViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> MiraComposerBackdropView {
        let view = MiraComposerBackdropView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ nsView: MiraComposerBackdropView, context: Context) {
        // Adjust only the backdrop; input text, controls, and the border stay fully opaque.
        nsView.alphaValue = colorScheme == .light ? MiraTheme.Opacity.composerMaterialLight : 1
    }
}

@MainActor
final class MiraComposerBackdropView: NSVisualEffectView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        blendingMode = .withinWindow
        material = .headerView
        state = .active
        isEmphasized = false
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
