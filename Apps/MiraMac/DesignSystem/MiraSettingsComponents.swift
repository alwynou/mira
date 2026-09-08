import SwiftUI

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
            MiraSurface {
                VStack(alignment: .leading, spacing: MiraTheme.Spacing.lg, content: content)
                    .padding(MiraTheme.Spacing.lg)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
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
        VStack(alignment: .leading, spacing: MiraTheme.Spacing.xs) {
            Text(title).font(MiraTheme.Typography.body.weight(.medium))
            if let subtitle {
                Text(subtitle)
                    .font(MiraTheme.Typography.caption)
                    .foregroundStyle(MiraTheme.Colors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct MiraSettingsDivider: View {
    var body: some View {
        Rectangle().fill(MiraTheme.Colors.border).frame(height: 1).accessibilityHidden(true)
    }
}

struct MiraSettingsSearchField: View {
    let prompt: LocalizedStringKey
    @Binding var text: String

    var body: some View {
        HStack(spacing: MiraTheme.Spacing.sm) {
            Image(systemName: "magnifyingglass").foregroundStyle(MiraTheme.Colors.secondaryText)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .accessibilityLabel(Text(prompt))
            if !text.isEmpty {
                Button("Clear search", systemImage: "xmark.circle.fill") { text = "" }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(MiraTheme.Colors.secondaryText)
            }
        }
        .padding(MiraTheme.Spacing.md)
        .background(MiraTheme.Colors.surface, in: .rect(cornerRadius: MiraTheme.Radius.small))
        .overlay {
            RoundedRectangle(cornerRadius: MiraTheme.Radius.small)
                .strokeBorder(MiraTheme.Colors.border, lineWidth: 1)
        }
    }
}
