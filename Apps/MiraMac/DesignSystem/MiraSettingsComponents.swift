import SwiftUI
import AppKit

struct MiraSettingsHeader: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: MiraTheme.Spacing.sm) {
            Text(title)
                .font(MiraTheme.Typography.title)
                .foregroundStyle(MiraTheme.Colors.text)
                .accessibilityAddTraits(.isHeader)
            Text(subtitle)
                .font(MiraTheme.Typography.caption)
                .foregroundStyle(MiraTheme.Colors.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Add to the page's 24 pt group spacing for a 32 pt content gap.
        .padding(.bottom, MiraTheme.Spacing.sm)
    }
}

/// Shared settings composition; controls retain native keyboard and accessibility behavior.
struct MiraSettingsPage<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MiraTheme.Spacing.xl, content: content)
                .frame(maxWidth: MiraTheme.Layout.contentMax, alignment: .leading)
                .padding(.horizontal, MiraTheme.Spacing.xxl)
                .padding(.bottom, MiraTheme.Spacing.xxl)
                .frame(maxWidth: .infinity, alignment: .top)
        }
        .padding(.top, MiraTheme.Layout.settingsPageTopInset)
        .background(MiraTheme.Colors.canvas)
        .ignoresSafeArea(.container, edges: .top)
    }
}

struct MiraSettingsSplitPage<Sidebar: View, Detail: View>: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    @ViewBuilder let sidebar: () -> Sidebar
    @ViewBuilder let detail: () -> Detail

    var body: some View {
        MiraSettingsPage {
            MiraSettingsHeader(title: title, subtitle: subtitle)
            HStack(alignment: .top, spacing: MiraTheme.Spacing.xl) {
                sidebar().frame(width: MiraTheme.Layout.providerListWidth, alignment: .leading)
                detail().frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct MiraSettingsButtonStyle: ButtonStyle {
    var isPrimary = false

    func makeBody(configuration: Configuration) -> some View {
        MiraSettingsButtonLabel(configuration: configuration, isPrimary: isPrimary)
    }
}

private struct MiraSettingsButtonLabel: View {
    let configuration: ButtonStyleConfiguration
    let isPrimary: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .font(MiraTheme.Typography.body.weight(.medium))
            .foregroundStyle(isPrimary ? MiraTheme.Colors.onAccent : MiraTheme.Colors.text)
            .padding(.horizontal, MiraTheme.Spacing.lg)
            .frame(height: MiraTheme.Layout.settingsButtonHeight)
            .background(fill, in: .rect(cornerRadius: MiraTheme.Radius.small))
            .overlay {
                if contrast == .increased {
                    RoundedRectangle(cornerRadius: MiraTheme.Radius.small)
                        .strokeBorder(MiraTheme.Colors.secondaryText, lineWidth: 1)
                }
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.72 : 1) : 0.45)
            .contentShape(.rect(cornerRadius: MiraTheme.Radius.small))
            .onHover { isHovered = $0 }
    }

    private var fill: Color {
        if isPrimary { return MiraTheme.Colors.accent }
        return isEnabled && isHovered ? MiraTheme.Colors.hover : MiraTheme.Colors.inset
    }
}

struct MiraProviderIcon: View {
    let providerID: String?
    var size: CGFloat = MiraTheme.Layout.providerIconSize

    private var assetName: String? {
        switch providerID {
        case "openai": "ProviderOpenAI" // i18n-verbatim: Asset catalog identifier.
        case "anthropic": "ProviderAnthropic" // i18n-verbatim: Asset catalog identifier.
        case "deepseek": "ProviderDeepSeek" // i18n-verbatim: Asset catalog identifier.
        case "moonshotai", "moonshotai-cn", "kimi-for-coding": "ProviderMoonshot" // i18n-verbatim: Asset catalog identifier.
        case "openrouter": "ProviderOpenRouter" // i18n-verbatim: Asset catalog identifier.
        default: nil
        }
    }

    var body: some View {
        Group {
            if let assetName {
                Image(assetName).resizable().renderingMode(.original).scaledToFit()
            } else {
                Image(systemName: "server.rack").resizable().scaledToFit()
                    .foregroundStyle(MiraTheme.Colors.secondaryText)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct MiraProviderRow: View {
    let name: String
    let providerID: String?
    let state: LocalizedStringKey
    var isSelected = false
    var isActive = false

    var body: some View {
        MiraSidebarRow(isSelected: isSelected, minimumHeight: MiraTheme.Layout.providerRowHeight) {
            HStack(spacing: MiraTheme.Spacing.sm) {
                MiraProviderIcon(providerID: providerID)
                Text(verbatim: name)
                    .font(MiraTheme.Typography.caption.weight(.medium))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isActive {
                    Circle().fill(MiraTheme.Colors.active).frame(width: MiraTheme.Spacing.xs, height: MiraTheme.Spacing.xs)
                }
            }
            .padding(.vertical, MiraTheme.Spacing.xs)
        }
        .help(Text(verbatim: name))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: name))
        .accessibilityValue(Text(state))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct MiraProviderGroup<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: () -> Content

    init(_ title: LocalizedStringKey, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MiraTheme.Spacing.sm) {
            Text(title)
                .font(MiraTheme.Typography.caption.weight(.medium))
                .foregroundStyle(MiraTheme.Colors.secondaryText)
                .padding(.horizontal, MiraTheme.Spacing.md)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: MiraTheme.Spacing.xs, content: content)
        }
    }
}

struct MiraSettingsSection<Content: View>: View {
    private let title: LocalizedStringKey?
    @ViewBuilder let content: () -> Content

    init(_ title: LocalizedStringKey? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MiraTheme.Spacing.sm) {
            if let title {
                Text(title)
                    .font(MiraTheme.Typography.section.weight(.medium))
                    .foregroundStyle(MiraTheme.Colors.secondaryText)
            }
            MiraSurface(fill: MiraTheme.Colors.settingsSurface) {
                VStack(alignment: .leading, spacing: MiraTheme.Spacing.lg, content: content)
                    .padding(MiraTheme.Spacing.lg)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct MiraSettingsRow<Control: View>: View {
    @Environment(\.colorSchemeContrast) private var contrast
    private let title: LocalizedStringKey
    private let subtitle: LocalizedStringKey?
    @ViewBuilder let control: () -> Control

    init(_ title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil,
         @ViewBuilder control: @escaping () -> Control) {
        self.title = title
        self.subtitle = subtitle
        self.control = control
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: MiraTheme.Spacing.xl) {
                label
                    .frame(idealWidth: MiraTheme.Layout.contentMax / 2, maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: MiraTheme.Spacing.lg)
                control().fixedSize(horizontal: true, vertical: false)
            }
            VStack(alignment: .leading, spacing: MiraTheme.Spacing.md) {
                label
                control()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, MiraTheme.Spacing.xs)
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: MiraTheme.Spacing.sm) {
            Text(title).font(MiraTheme.Typography.body.weight(.medium))
            if let subtitle {
                Text(subtitle)
                    .font(MiraTheme.Typography.caption)
                    .foregroundStyle(contrast == .increased ? MiraTheme.Colors.secondaryText : MiraTheme.Colors.settingsDescription)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Form labels and controls keep their columns; supporting text belongs below its own row.
struct MiraSettingsFormRow<Control: View>: View {
    @Environment(\.colorSchemeContrast) private var contrast
    private let title: LocalizedStringKey
    private let subtitle: LocalizedStringKey?
    @ViewBuilder let control: () -> Control

    init(_ title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil,
         @ViewBuilder control: @escaping () -> Control) {
        self.title = title; self.subtitle = subtitle; self.control = control
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MiraTheme.Spacing.sm) {
            HStack(alignment: .center, spacing: MiraTheme.Spacing.md) {
                Text(title)
                    .font(MiraTheme.Typography.body)
                    .foregroundStyle(MiraTheme.Colors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: MiraTheme.Layout.settingsFormLabelWidth, alignment: .leading)
                control().frame(maxWidth: .infinity, alignment: .leading)
            }
            if let subtitle {
                Text(subtitle)
                    .font(MiraTheme.Typography.caption)
                    .foregroundStyle(contrast == .increased ? MiraTheme.Colors.secondaryText : MiraTheme.Colors.settingsDescription)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct MiraSettingsTextFieldStyle: TextFieldStyle {
    @FocusState private var isFocused: Bool

    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .font(MiraTheme.Typography.body)
            .padding(.horizontal, MiraTheme.Spacing.md)
            .frame(height: MiraTheme.Layout.settingsInputHeight)
            .background(MiraTheme.Colors.surface, in: .rect(cornerRadius: MiraTheme.Radius.row))
            .overlay {
                RoundedRectangle(cornerRadius: MiraTheme.Radius.row)
                    .stroke(isFocused ? MiraTheme.Colors.accent : MiraTheme.Colors.border, lineWidth: 1)
            }
            .focused($isFocused)
    }
}

struct MiraSettingsDivider: View {
    var body: some View {
        Rectangle().fill(MiraTheme.Colors.border).frame(height: 1).accessibilityHidden(true)
    }
}

/// A native pop-up button. The bridge only styles its closed control and observes menu lifecycle.
struct MiraSettingsSelect: NSViewRepresentable {
    struct Option: Identifiable {
        enum Title {
            case localized(LocalizedStringResource)
            case verbatim(String)
        }
        let id: String
        let title: Title

        init(id: String, title: LocalizedStringResource) {
            self.id = id; self.title = .localized(title)
        }

        init(id: String, verbatimTitle: String) {
            self.id = id; title = .verbatim(verbatimTitle)
        }
    }

    struct MenuEntry: Equatable {
        let id: String?
        let title: String
        let isSeparator: Bool
    }

    let title: LocalizedStringResource
    @Binding var selection: String
    let options: [Option]
    let identifier: String
    var placeholder: LocalizedStringResource = "Select an option"
    var clearSelectionTitle: LocalizedStringResource? = nil
    var minimumWidth: CGFloat = MiraTheme.Layout.selectMinWidth
    var maximumWidth: CGFloat? = nil
    @Environment(\.locale) private var locale
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var selectedOption: Option? { selection.isEmpty ? nil : options.first { $0.id == selection } }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> MiraSettingsPopUpButton {
        let button = MiraSettingsPopUpButton(frame: .zero, pullsDown: false)
        context.coordinator.button = button
        return button
    }

    func updateNSView(_ button: MiraSettingsPopUpButton, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        var entries = options.map { MenuEntry(id: $0.id, title: optionTitle($0), isSeparator: false) }
        if entries.isEmpty {
            entries.append(MenuEntry(id: nil, title: localized("No options available"), isSeparator: false))
        }
        if selectedOption != nil, let clearSelectionTitle {
            entries.append(MenuEntry(id: nil, title: "", isSeparator: true))
            entries.append(MenuEntry(id: "", title: localized(clearSelectionTitle), isSeparator: false))
        }
        if coordinator.entries != entries {
            button.menu?.cancelTracking()
            let menu = NSMenu()
            menu.autoenablesItems = false
            menu.delegate = coordinator
            for entry in entries {
                if entry.isSeparator {
                    menu.addItem(.separator())
                    continue
                }
                let item = NSMenuItem(title: entry.title, action: #selector(Coordinator.choose(_:)), keyEquivalent: "")
                item.target = coordinator
                item.representedObject = entry.id
                item.isEnabled = entry.id != nil
                let suffix = entry.id.map { $0.isEmpty ? "clear" : "option.\($0)" } ?? "empty"
                item.setAccessibilityIdentifier("\(identifier).\(suffix)")
                menu.addItem(item)
            }
            button.menu = menu
            coordinator.entries = entries
        }
        if !isEnabled { button.menu?.cancelTracking() }
        button.isEnabled = isEnabled
        button.reduceMotion = reduceMotion
        button.increasedContrast = contrast == .increased
        let selectedItem = selectedOption.flatMap { option in
            button.itemArray.first { ($0.representedObject as? String) == option.id }
        }
        button.select(selectedItem)
        for item in button.itemArray { item.state = item === selectedItem ? .on : .off }
        button.displayText = selectedOption.map(optionTitle) ?? localized(placeholder)
        button.isPlaceholder = selectedOption == nil
        button.setAccessibilityIdentifier(identifier)
        button.setAccessibilityLabel(localized(title))
        button.setAccessibilityValue(button.displayText)
        button.needsDisplay = true
        button.needsLayout = true
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MiraSettingsPopUpButton, context: Context) -> CGSize? {
        let text = selectedOption.map(optionTitle) ?? localized(placeholder)
        let textWidth = (text as NSString).size(withAttributes: [.font: MiraTheme.Typography.appKitBody]).width
        let idealWidth = ceil(textWidth) + MiraTheme.Spacing.md * 2 + MiraTheme.Spacing.sm
            + MiraTheme.Typography.appKitCaption.pointSize
        return CGSize(width: max(minimumWidth, min(idealWidth, maximumWidth ?? .infinity)),
                      height: MiraTheme.Layout.selectHeight)
    }

    static func dismantleNSView(_ button: MiraSettingsPopUpButton, coordinator: Coordinator) {
        button.menu?.cancelTracking()
        button.menu?.delegate = nil
    }

    private func optionTitle(_ option: Option) -> String {
        switch option.title {
        case .localized(let resource): localized(resource)
        case .verbatim(let value): value
        }
    }

    private func localized(_ source: LocalizedStringResource) -> String {
        var resource = source
        resource.locale = locale
        return String(localized: resource)
    }

    @MainActor
    final class Coordinator: NSObject, NSMenuDelegate {
        var parent: MiraSettingsSelect
        var entries: [MenuEntry] = []
        weak var button: MiraSettingsPopUpButton?

        init(_ parent: MiraSettingsSelect) { self.parent = parent }

        @objc func choose(_ item: NSMenuItem) {
            guard let id = item.representedObject as? String else { return }
            parent.selection = id
        }

        func menuWillOpen(_ menu: NSMenu) { button?.setMenuOpen(true) }
        func menuDidClose(_ menu: NSMenu) { button?.setMenuOpen(false) }
    }
}

/// Only control drawing is customized. NSPopUpButton retains all menu and input behavior.
final class MiraSettingsPopUpButton: NSPopUpButton {
    var displayText = ""
    var isPlaceholder = false
    var increasedContrast = false
    var reduceMotion = false
    private var isMenuOpen = false
    private let arrowLayer = CALayer()

    override init(frame buttonFrame: NSRect, pullsDown flag: Bool) {
        super.init(frame: buttonFrame, pullsDown: flag)
        isBordered = false
        focusRingType = .none
        font = MiraTheme.Typography.appKitBody
        controlSize = .regular
        if let popupCell = cell as? NSPopUpButtonCell {
            popupCell.arrowPosition = .noArrow
            popupCell.altersStateOfSelectedItem = false
        }
        wantsLayer = true
        arrowLayer.contentsGravity = .resizeAspect
        layer?.addSublayer(arrowLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                  xRadius: MiraTheme.Radius.row, yRadius: MiraTheme.Radius.row)
        NSColor(MiraTheme.Colors.surface).setFill()
        outline.fill()
        let focused = window?.firstResponder === self
        NSColor(isEnabled && (isMenuOpen || focused) ? MiraTheme.Colors.accent : MiraTheme.Colors.border).setStroke()
        outline.lineWidth = 1
        outline.stroke()

        let color = isPlaceholder
            ? (increasedContrast ? MiraTheme.Colors.secondaryText : MiraTheme.Colors.tertiaryText)
            : MiraTheme.Colors.text
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let text = NSAttributedString(string: displayText, attributes: [
            .font: MiraTheme.Typography.appKitBody,
            .foregroundColor: NSColor(color).withAlphaComponent(isEnabled ? 1 : 0.45),
            .paragraphStyle: paragraph
        ])
        let size = text.size()
        let arrowWidth = MiraTheme.Typography.appKitCaption.pointSize
        text.draw(in: NSRect(x: MiraTheme.Spacing.md, y: (bounds.height - size.height) / 2,
                             width: max(0, bounds.width - MiraTheme.Spacing.md * 2 - MiraTheme.Spacing.sm - arrowWidth),
                             height: size.height))
    }

    override func layout() {
        super.layout()
        let size = MiraTheme.Typography.appKitCaption.pointSize
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        arrowLayer.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        arrowLayer.position = CGPoint(x: bounds.maxX - MiraTheme.Spacing.md - size / 2, y: bounds.midY)
        arrowLayer.opacity = isEnabled ? 1 : 0.45
        arrowLayer.contentsScale = window?.backingScaleFactor ?? 2
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let symbol = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor(MiraTheme.Colors.secondaryText)])))
            arrowLayer.contents = symbol?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        CATransaction.commit()
    }

    func setMenuOpen(_ isOpen: Bool) {
        guard isMenuOpen != isOpen else { return }
        isMenuOpen = isOpen
        let target = CATransform3DMakeRotation(isOpen ? .pi : 0, 0, 0, 1)
        let current = arrowLayer.presentation()?.transform ?? arrowLayer.transform
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        arrowLayer.transform = target
        CATransaction.commit()
        if !reduceMotion {
            let animation = CABasicAnimation(keyPath: "transform")
            animation.fromValue = NSValue(caTransform3D: current)
            animation.toValue = NSValue(caTransform3D: target)
            animation.duration = 0.16
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            arrowLayer.add(animation, forKey: "menuRotation")
        } else {
            arrowLayer.removeAnimation(forKey: "menuRotation")
        }
        needsDisplay = true
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        needsDisplay = true
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        needsDisplay = true
        return result
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        needsLayout = true
    }
}
