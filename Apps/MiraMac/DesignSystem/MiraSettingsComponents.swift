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

struct MiraSettingsSection<Content: View>: View {
    private let title: LocalizedStringKey?
    @ViewBuilder let content: () -> Content

    init(_ title: LocalizedStringKey? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
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
            if let title { Text(title).font(MiraTheme.Settings.section) }
        })
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
            .labeledContentStyle(MiraSettingsCenteredFieldStyle())
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
private struct MiraSettingsCenteredFieldStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: MiraTheme.Spacing.lg) {
            configuration.label
                .frame(maxWidth: .infinity, alignment: .leading)
            configuration.content
                .multilineTextAlignment(.trailing)
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

    private var hasSelection: Bool { options.contains { $0.id == selection } }

    var body: some View {
        Picker(selection: Binding(
            get: { hasSelection ? selection : "" },
            set: { selection = $0 }
        )) {
            if !hasSelection {
                Text(verbatim: localized(placeholder)).tag("")
                    .disabled(true)
            }
            if options.isEmpty {
                Text("No options available")
                    .disabled(true)
                    .accessibilityIdentifier("\(identifier).empty")
            }
            ForEach(options) { option in
                Text(verbatim: option.displayTitle(locale: locale))
                    .tag(option.id)
                    .accessibilityIdentifier("\(identifier).option.\(option.id)")
            }
            if hasSelection, let clearSelectionTitle {
                Divider()
                Text(verbatim: localized(clearSelectionTitle)).tag("")
                    .accessibilityIdentifier("\(identifier).clear")
            }
        } label: {
            Text(verbatim: localized(title))
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .disabled(options.isEmpty)
        .frame(minWidth: minimumWidth, maxWidth: maximumWidth, alignment: .trailing)
        .accessibilityLabel(Text(verbatim: localized(title)))
        .accessibilityIdentifier(identifier)
    }

    private func localized(_ source: LocalizedStringResource) -> String {
        var resource = source
        resource.locale = locale
        return String(localized: resource)
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
