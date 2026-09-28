import SwiftUI

extension ToolPermissionLevel {
    var title: LocalizedStringKey {
        switch self {
        case .ask: "Ask for approval"
        case .automatic: "Approve safe actions"
        case .fullAccess: "Full access"
        }
    }
    var detail: LocalizedStringKey {
        switch self {
        case .ask: "Ask before running external actions, deleting data, or using unrecognized tools."
        case .automatic: "Approve recognized low-risk actions automatically. Ask for risky or uncertain actions."
        case .fullAccess: "Run enabled tools without routine approval, including file changes and network access."
        }
    }
    var symbol: String {
        switch self {
        case .ask: "hand.raised" // i18n-verbatim: SF Symbol identifier.
        case .automatic: "checkmark.shield" // i18n-verbatim: SF Symbol identifier.
        case .fullAccess: "exclamationmark.shield" // i18n-verbatim: SF Symbol identifier.
        }
    }
}

struct ToolPermissionOptions: View {
    let preferences: ToolPermissionPreferences
    var didSelect: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: MiraTheme.Spacing.xs) {
            ForEach(ToolPermissionLevel.allCases, id: \.self) { level in
                Button {
                    preferences.select(level)
                    didSelect()
                } label: {
                    HStack(alignment: .top, spacing: MiraTheme.Spacing.md) {
                        Image(systemName: level.symbol)
                            .frame(width: MiraTheme.Layout.controlHeight)
                            .padding(.top, MiraTheme.Spacing.xs)
                        VStack(alignment: .leading, spacing: MiraTheme.Spacing.xs) {
                            Text(level.title).font(MiraTheme.Typography.body)
                            Text(level.detail)
                                .font(MiraTheme.Typography.caption)
                                .foregroundStyle(MiraTheme.Colors.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "checkmark")
                            .opacity(preferences.level == level ? 1 : 0)
                            .accessibilityHidden(true)
                    }
                    .foregroundStyle(level == .fullAccess ? Color.orange : MiraTheme.Colors.text)
                    .padding(MiraTheme.Spacing.md)
                    .contentShape(Rectangle())
                }
                .buttonStyle(MiraRowButtonStyle())
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(preferences.level == level ? .isSelected : [])
                .accessibilityIdentifier("tools.permission.\(level.rawValue)")
            }
        }
    }
}

struct ToolPermissionControl: View {
    private let preferences = ToolPermissionPreferences.shared
    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var colorScheme
    @State private var showsOptions = false

    var body: some View {
        Button { showsOptions.toggle() } label: {
            Label { Text(preferences.level.title).lineLimit(1) } icon: {
                Image(systemName: preferences.level.symbol)
            }
            .font(MiraTheme.Typography.composerModel)
            .foregroundStyle(preferences.level == .fullAccess ? Color.orange : MiraTheme.Colors.secondaryText)
        }
        .buttonStyle(.plain)
        .help("Tool permissions")
        .accessibilityLabel("Tool permissions")
        .accessibilityValue(Text(preferences.level.title))
        .accessibilityIdentifier("conversation.toolPermissions")
        .popover(isPresented: $showsOptions, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: MiraTheme.Spacing.sm) {
                Text("Tool permissions").font(MiraTheme.Typography.section)
                    .foregroundStyle(MiraTheme.Colors.secondaryText)
                    .padding(.horizontal, MiraTheme.Spacing.md)
                ToolPermissionOptions(preferences: preferences) { showsOptions = false }
                Text("Applies to all conversations on this Mac. Changes affect new tool actions; pending requests still need a decision.")
                    .font(MiraTheme.Typography.caption)
                    .foregroundStyle(MiraTheme.Colors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, MiraTheme.Spacing.md)
            }
            .padding(MiraTheme.Spacing.md)
            .frame(width: 360)
            .environment(\.locale, locale)
            .environment(\.colorScheme, colorScheme)
        }
    }
}

struct ToolPermissionSettings: View {
    private let preferences = ToolPermissionPreferences.shared

    var body: some View {
        MiraSettingsSection("Tool permissions") {
            ToolPermissionOptions(preferences: preferences)
            Text("Applies to all conversations on this Mac. Changes affect new tool actions; pending requests still need a decision.")
                .font(MiraTheme.Typography.caption)
                .foregroundStyle(MiraTheme.Colors.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Text("Internal lookups and ordinary memory and task updates keep their existing checks. Full access preserves tool-specific restrictions and macOS permissions; it does not create a file sandbox.")
                .font(MiraTheme.Typography.caption)
                .foregroundStyle(MiraTheme.Colors.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
