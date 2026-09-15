import SwiftUI
import AppKit

struct MiraSettingsNavigation<Sidebar: View, Detail: View>: View {
    @ViewBuilder let sidebar: () -> Sidebar
    @ViewBuilder let detail: () -> Detail

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            sidebar()
                .frame(width: MiraTheme.Settings.sidebarWidth)
                .navigationSplitViewColumnWidth(
                    min: MiraTheme.Settings.sidebarWidth,
                    ideal: MiraTheme.Settings.sidebarWidth,
                    max: MiraTheme.Settings.sidebarWidth)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            detail()
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar(removing: .sidebarToggle)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    }
}

/// Keeps the native scroll-edge registration and title in one SwiftUI hierarchy.
struct MiraSettingsTitlebar: ViewModifier {
    let title: LocalizedStringKey

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            GeometryReader { geometry in
                content
                    .safeAreaBar(edge: .top, alignment: .leading, spacing: 0) {
                        Text(title)
                            .font(MiraTheme.Settings.title)
                            .foregroundStyle(MiraTheme.Settings.text)
                            .padding(.horizontal, MiraTheme.Settings.titleHorizontalInset)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .frame(height: geometry.safeAreaInsets.top)
                    }
                    // Replace the native toolbar inset instead of adding a second row.
                    .ignoresSafeArea(.container, edges: .top)
            }
            // Retain native toolbar chrome without adding a navigation control.
            .toolbar { ToolbarSpacer(.flexible) }
            .toolbar(removing: .title)
        } else {
            content.clipped()
        }
    }
}

/// Native forms own scrolling, grouped backgrounds, and control adaptation.
struct MiraSettingsPage<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        if #available(macOS 26.0, *) {
            form.scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            form
        }
    }

    private var form: some View {
        Form(content: content)
            .formStyle(.grouped)
            .font(MiraTheme.Settings.body)
            .foregroundStyle(MiraTheme.Settings.text)
            .tint(MiraTheme.Settings.accent)
    }
}

extension EnvironmentValues {
    @Entry var miraSettingsLazyLayout = false
}

/// Keeps the editor header mounted while realizing the model collection by row.
/// The header scrolls with the content; it is not a sticky section header.
struct MiraSettingsLazyPage<Header: View, Content: View>: View {
    @ViewBuilder let header: () -> Header
    @ViewBuilder let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) where Header == EmptyView {
        self.header = { EmptyView() }
        self.content = content
    }

    init(@ViewBuilder header: @escaping () -> Header,
                       @ViewBuilder content: @escaping () -> Content) {
        self.header = header
        self.content = content
    }

    var body: some View {
        if #available(macOS 26.0, *) {
            page.scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            page
        }
    }

    private var page: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header()
                LazyVStack(alignment: .leading, spacing: 0, content: content)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, MiraTheme.Settings.titleHorizontalInset)
            .padding(.bottom, MiraTheme.Settings.titleHorizontalInset)
        }
        .background(MiraTheme.Settings.canvas)
        .environment(\.miraSettingsLazyLayout, true)
        .font(MiraTheme.Settings.body)
        .foregroundStyle(MiraTheme.Settings.text)
        .tint(MiraTheme.Settings.accent)
    }
}

struct MiraSettingsSection<Content: View, Actions: View>: View {
    @Environment(\.miraSettingsLazyLayout) private var usesLazyLayout
    private let title: LocalizedStringKey?
    private let isCollection: Bool
    private let actions: () -> Actions
    @ViewBuilder let content: () -> Content

    init(_ title: LocalizedStringKey? = nil, isCollection: Bool = false,
         @ViewBuilder actions: @escaping () -> Actions,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.isCollection = isCollection
        self.actions = actions
        self.content = content
    }

    init(_ title: LocalizedStringKey? = nil, isCollection: Bool = false,
         @ViewBuilder content: @escaping () -> Content) where Actions == EmptyView {
        self.init(title, isCollection: isCollection, actions: { EmptyView() }, content: content)
    }

    var body: some View {
        if usesLazyLayout {
            if isCollection {
                lazySection
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    lazyHeader
                    Group(subviews: content()) { rows in
                        VStack(spacing: 0) {
                            ForEach(rows) { row in
                                MiraSettingsLazyRow(isFirst: row.id == rows.first?.id, isLast: row.id == rows.last?.id) {
                                    row
                                }
                            }
                        }
                    }
                }
            }
        } else {
            formSection
        }
    }

    private var lazySection: some View {
        Section {
            content()
        } header: {
            lazyHeader
        }
    }

    @ViewBuilder private var lazyHeader: some View {
        if title != nil {
            header
                .padding(.horizontal, MiraTheme.Settings.groupInset)
                .padding(.top, MiraTheme.Settings.sectionTopInset)
                .padding(.bottom, MiraTheme.Settings.rowVerticalInset)
        } else {
            Color.clear.frame(height: MiraTheme.Settings.groupGap).accessibilityHidden(true)
        }
    }

    private var formSection: some View {
        Section(content: {
            // Grouped Form ignores List separator preferences on macOS. Keep a
            // single native group and compose its rows through public subview APIs.
            Group(subviews: content()) { rows in
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        row
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, row.id == rows.first?.id ? 0 : MiraTheme.Settings.rowVerticalInset)
                            .padding(.bottom, row.id == rows.last?.id ? 0 : MiraTheme.Settings.rowVerticalInset)
                        if row.id != rows.last?.id { MiraSettingsDivider() }
                    }
                }
            }
        }, header: {
            header
        })
    }

    private var header: some View {
        HStack {
            if let title { Text(title).font(MiraTheme.Settings.section) }
            Spacer(minLength: 0)
            actions()
        }
    }
}

/// Collection callers keep their typed ForEach intact and defer row construction to this body.
struct MiraSettingsLazyRow<Content: View>: View {
    let isFirst: Bool
    let isLast: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, isFirst ? MiraTheme.Settings.groupInset : MiraTheme.Settings.rowVerticalInset)
                .padding(.bottom, isLast ? MiraTheme.Settings.groupInset : MiraTheme.Settings.rowVerticalInset)
            if !isLast { MiraSettingsDivider() }
        }
        .padding(.horizontal, MiraTheme.Settings.groupInset)
        .background {
            if isFirst || isLast {
                UnevenRoundedRectangle(
                    topLeadingRadius: isFirst ? MiraTheme.Settings.groupRadius : 0,
                    bottomLeadingRadius: isLast ? MiraTheme.Settings.groupRadius : 0,
                    bottomTrailingRadius: isLast ? MiraTheme.Settings.groupRadius : 0,
                    topTrailingRadius: isFirst ? MiraTheme.Settings.groupRadius : 0)
                    .fill(MiraTheme.Settings.groupSurface)
            } else {
                Rectangle()
                    .fill(MiraTheme.Settings.groupSurface)
            }
        }
    }
}

/// Delegate both drawing and interaction to the platform button styles.
struct MiraSettingsButtonStyle: PrimitiveButtonStyle {
    var isPrimary = false

    func makeBody(configuration: Configuration) -> some View {
        if isPrimary {
            Button(configuration).buttonStyle(.borderedProminent)
        } else {
            Button(configuration).buttonStyle(.bordered)
        }
    }
}

struct MiraSettingsRow<Control: View>: View {
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
        LabeledContent {
            control().labelsHidden()
        } label: {
            Text(title)
            if let subtitle {
                Text(subtitle)
                    .font(MiraTheme.Settings.caption)
                    .foregroundStyle(MiraTheme.Settings.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct MiraSettingsFormRow<Control: View>: View {
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
        VStack(alignment: .leading, spacing: MiraTheme.Settings.labelDescriptionGap) {
            LabeledContent {
                control().labelsHidden()
            } label: {
                Text(title)
            }
            .labeledContentStyle(MiraSettingsCenteredLabeledContentStyle())
            if let subtitle {
                Text(subtitle)
                    .font(MiraTheme.Settings.caption)
                    .foregroundStyle(MiraTheme.Settings.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Keep native field semantics while aligning the label and control by their centers.
private struct MiraSettingsCenteredLabeledContentStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: MiraTheme.Spacing.lg) {
            configuration.label
                .frame(maxWidth: .infinity, alignment: .leading)
            configuration.content
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

struct MiraSettingsDivider: View {
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Rectangle()
            .fill(contrast == .increased ? Color(nsColor: .separatorColor) : MiraTheme.Settings.separator)
            .frame(height: MiraTheme.Settings.separatorHeight)
            .accessibilityHidden(true)
    }
}

/// Typed option labels preserve model identifiers verbatim and resolve UI copy at display time.
struct MiraSettingsSelect: View {
    struct Option: Identifiable {
        enum Title {
            case localized(LocalizedStringResource)
            case verbatim(String)
        }
        let id: String
        let title: Title

        init(id: String, title: LocalizedStringResource) {
            self.id = id
            self.title = .localized(title)
        }

        init(id: String, verbatimTitle: String) {
            self.id = id
            title = .verbatim(verbatimTitle)
        }

        func displayTitle(locale: Locale) -> String {
            switch title {
            case .localized(var resource):
                resource.locale = locale
                return String(localized: resource)
            case .verbatim(let value):
                return value
            }
        }
    }

    let title: LocalizedStringResource
    @Binding var selection: String
    let options: [Option]
    let identifier: String
    var placeholder: LocalizedStringResource = "Select an option"
    var clearSelectionTitle: LocalizedStringResource? = nil
    var minimumWidth: CGFloat = MiraTheme.Settings.selectMinWidth
    var maximumWidth: CGFloat? = nil
    @Environment(\.locale) private var locale

    var body: some View {
        MiraSettingsNativeSelect(
            selection: $selection,
            options: options.map { .init(id: $0.id, title: $0.displayTitle(locale: locale)) },
            title: localized(title), identifier: identifier,
            placeholder: localized(placeholder),
            emptyTitle: localized("No options available"),
            clearTitle: clearSelectionTitle.map(localized))
            .frame(minWidth: minimumWidth, maxWidth: maximumWidth, alignment: .trailing)
    }

    private func localized(_ source: LocalizedStringResource) -> String {
        var resource = source
        resource.locale = locale
        return String(localized: resource)
    }
}

/// A native popup avoids constructing a SwiftUI view hierarchy for hundreds of menu options.
private struct MiraSettingsNativeSelect: NSViewRepresentable {
    struct Option: Equatable {
        let id: String
        let title: String
    }

    @Binding var selection: String
    let options: [Option]
    let title: String
    let identifier: String
    let placeholder: String
    let emptyTitle: String
    let clearTitle: String?
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: NSFont.systemFontSize)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.cell?.lineBreakMode = .byTruncatingMiddle
        context.coordinator.button = button
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        let coordinator = context.coordinator
        coordinator.selection = $selection
        let hasSelection = options.contains { $0.id == selection }
        var entries: [Coordinator.Entry] = []
        if !hasSelection {
            entries.append(.init(title: placeholder, id: nil, identifier: identifier + ".placeholder"))
        }
        if options.isEmpty {
            entries.append(.init(title: emptyTitle, id: nil, identifier: identifier + ".empty"))
        }
        entries += options.map { .init(title: $0.title, id: $0.id, identifier: identifier + ".option." + $0.id) }
        if hasSelection, let clearTitle {
            entries.append(.init(title: "", id: nil, identifier: "", isSeparator: true))
            entries.append(.init(title: clearTitle, id: "", identifier: identifier + ".clear"))
        }
        if coordinator.entries != entries {
            coordinator.entries = entries
            let menu = NSMenu()
            menu.autoenablesItems = false
            for entry in entries {
                if entry.isSeparator { menu.addItem(.separator()); continue }
                let item = NSMenuItem(title: entry.title, action: #selector(Coordinator.choose(_:)), keyEquivalent: "")
                item.target = coordinator
                item.representedObject = entry.id
                item.isEnabled = entry.id != nil
                item.setAccessibilityIdentifier(entry.identifier)
                menu.addItem(item)
            }
            button.menu = menu
        }
        let selected = hasSelection ? button.itemArray.first { ($0.representedObject as? String) == selection } : button.itemArray.first
        button.select(selected)
        for item in button.itemArray { item.state = item === selected ? .on : .off }
        button.isEnabled = isEnabled && !options.isEmpty
        button.setAccessibilityLabel(title)
        button.setAccessibilityIdentifier(identifier)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
        let title = nsView.selectedItem?.title ?? nsView.itemArray.first?.title ?? ""
        let key = Coordinator.FittingKey(title: title, controlSize: nsView.controlSize,
                                          bezelStyle: nsView.bezelStyle)
        let size = context.coordinator.fittingSizes[key] ?? Self.measure(title: title, matching: nsView)
        context.coordinator.fittingSizes[key] = size
        let width: CGFloat
        if let proposedWidth = proposal.width, proposedWidth > 0 {
            width = min(size.width, proposedWidth)
        } else {
            width = size.width
        }
        return CGSize(width: width, height: size.height)
    }

    private static func measure(title: String, matching button: NSPopUpButton) -> CGSize {
        // Use an offscreen native control so AppKit supplies the chrome width;
        // measuring the whole menu would make every selection as wide as its longest option.
        let probe = NSPopUpButton(frame: .zero, pullsDown: false)
        probe.bezelStyle = button.bezelStyle
        probe.controlSize = button.controlSize
        probe.font = button.font
        probe.isBordered = button.isBordered
        probe.addItem(withTitle: title)
        probe.selectItem(at: 0)
        probe.sizeToFit()
        return probe.fittingSize
    }

    @MainActor final class Coordinator: NSObject {
        struct Entry: Equatable {
            let title: String
            let id: String?
            let identifier: String
            var isSeparator = false
        }

        var selection: Binding<String>
        var entries: [Entry] = []
        struct FittingKey: Hashable {
            let title: String
            let controlSize: NSControl.ControlSize
            let bezelStyle: NSButton.BezelStyle
        }

        var fittingSizes: [FittingKey: CGSize] = [:]
        weak var button: NSPopUpButton?

        init(selection: Binding<String>) { self.selection = selection }

        @objc func choose(_ item: NSMenuItem) {
            guard item.isEnabled, let id = item.representedObject as? String else { return }
            button?.select(item)
            selection.wrappedValue = id
        }
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

/// A compact native button for choosing a provider from a horizontal rail.
struct MiraProviderSelectionCard: View {
    @State private var isHovered = false
    let name: String
    let providerID: String?
    let isSelected: Bool
    let action: () -> Void

    init(name: String, providerID: String?, isSelected: Bool, action: @escaping () -> Void) {
        self.name = name
        self.providerID = providerID
        self.isSelected = isSelected
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: MiraTheme.Spacing.sm) {
                MiraProviderIcon(providerID: providerID, size: MiraTheme.Layout.providerHeadingIconSize)
                Text(verbatim: name)
                    .font(MiraTheme.Settings.body)
                    .foregroundStyle(MiraTheme.Settings.text)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, MiraTheme.Spacing.sm)
            .padding(.vertical, MiraTheme.Spacing.md)
            .frame(width: MiraTheme.Settings.providerCardWidth)
            .frame(minHeight: MiraTheme.Settings.providerCardMinHeight)
            .contentShape(.rect)
            .background {
                RoundedRectangle(cornerRadius: MiraTheme.Settings.providerCardRadius, style: .continuous)
                    .fill(
                        isSelected
                            ? MiraTheme.Settings.accent.opacity(MiraTheme.Settings.providerCardSelectionOpacity)
                            : isHovered
                                ? MiraTheme.Colors.hover
                                : .clear)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Stored and replacement credentials share the native secure field; neither is a placeholder.
struct MiraSettingsCredentialField: View {
    @Binding private var text: String
    let hasStoredKey: Bool
    let showsRequiredError: Bool

    init(text: Binding<String>, hasStoredKey: Bool, showsRequiredError: Bool = false) {
        self._text = text
        self.hasStoredKey = hasStoredKey
        self.showsRequiredError = showsRequiredError
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MiraTheme.Spacing.xs) {
            SecureField("API Key", text: $text)
                .multilineTextAlignment(.leading)
                .textFieldStyle(.roundedBorder)
                .overlay {
                    RoundedRectangle(cornerRadius: MiraTheme.Radius.small)
                        .strokeBorder(showsRequiredError ? Color.red : .clear, lineWidth: 1)
                        .allowsHitTesting(false)
                }
                .accessibilityLabel(Text("API Key"))
                .accessibilityHint(showsRequiredError ? Text("Enter an API key.") : Text(""))
                .help(hasStoredKey ? Text("New API Key (leave blank to keep)") : Text("API Key"))
            if showsRequiredError {
                Text("Enter an API key.")
                    .font(MiraTheme.Settings.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
