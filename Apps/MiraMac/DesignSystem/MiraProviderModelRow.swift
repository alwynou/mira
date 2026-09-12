import SwiftUI

/// Model information wraps within the leading column; capability controls stay together on the right.
struct MiraProviderModelRow: View {
    struct Pricing {
        let input: String
        let output: String
    }

    @Environment(\.locale) private var locale

    let name: String
    let modelID: String
    let pricing: Pricing?
    let providerID: String?
    let supportsVision: Bool
    let supportsTools: Bool
    let supportsThinking: Bool
    let contextWindow: Int?
    @Binding var isEnabled: Bool

    init(name: String, modelID: String, pricing: Pricing? = nil, providerID: String? = nil,
         supportsVision: Bool = false, supportsTools: Bool = false, supportsThinking: Bool = false,
         contextWindow: Int? = nil, isEnabled: Binding<Bool>) {
        self.name = name; self.modelID = modelID; self.pricing = pricing; self.providerID = providerID
        self.supportsVision = supportsVision; self.supportsTools = supportsTools; self.supportsThinking = supportsThinking
        self.contextWindow = contextWindow; self._isEnabled = isEnabled
    }

    var body: some View {
        HStack(alignment: .center, spacing: MiraTheme.Spacing.md) {
            MiraModelIcon(modelID: modelID, providerID: providerID, size: MiraTheme.Layout.providerModelIconSize)
            identityBlock.frame(maxWidth: .infinity, alignment: .leading)
            capabilityControls
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
        }
        .padding(.horizontal, MiraTheme.Spacing.md)
        .padding(.vertical, MiraTheme.Spacing.md)
        .frame(minHeight: MiraTheme.Layout.providerModelRowMinHeight)
        .accessibilityElement(children: .contain)
    }

    private var identityBlock: some View {
        VStack(alignment: .leading, spacing: MiraTheme.Spacing.xs) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: MiraTheme.Spacing.sm) {
                    title
                    modelIDChip
                }
                .fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: MiraTheme.Spacing.xs) {
                    title
                    modelIDChip
                }
            }
            if !information.isEmpty {
                Text(verbatim: information)
                    .font(MiraTheme.Settings.caption)
                    .foregroundStyle(MiraTheme.Settings.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(Text(verbatim: informationDescription))
                    .help(Text(verbatim: informationDescription))
            }
        }
    }

    private var title: some View {
        Text(verbatim: name)
            .font(MiraTheme.Settings.body.weight(.medium))
            .foregroundStyle(MiraTheme.Settings.text)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var modelIDChip: some View {
        Text(verbatim: modelID)
            .font(MiraTheme.Typography.composerModel)
            .foregroundStyle(MiraTheme.Settings.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, MiraTheme.Spacing.xs)
            .padding(.vertical, MiraTheme.Spacing.xs / 2)
            .background(MiraTheme.Colors.inset, in: .rect(cornerRadius: MiraTheme.Radius.small))
    }

    private var capabilityControls: some View {
        HStack(spacing: MiraTheme.Spacing.sm) {
            if supportsVision { capabilityIcon("eye", title: "Vision", style: MiraTheme.Colors.modelVision) }
            if supportsTools { capabilityIcon("wrench.and.screwdriver", title: "Tools", style: MiraTheme.Colors.modelTools) }
            if supportsThinking {
                capabilityIcon("brain", title: "Thinking", style: LinearGradient(
                    colors: [MiraTheme.Colors.modelVision, MiraTheme.Colors.modelThinking],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            Toggle(L10n.string("In Model Pool", locale: locale), isOn: $isEnabled)
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
                .accessibilityLabel(Text(L10n.format("Include %@ in Model Pool", locale: locale, modelID)))
                .help(Text(L10n.string("In Model Pool", locale: locale)))
        }
    }

    private func capabilityIcon<Style: ShapeStyle>(_ systemName: String, title: String, style: Style) -> some View {
        Image(systemName: systemName)
            .font(MiraTheme.Typography.modelCapability)
            .foregroundStyle(style)
            .frame(width: MiraTheme.Spacing.lg, height: MiraTheme.Layout.controlHeight)
            .accessibilityLabel(Text(L10n.string(title, locale: locale)))
            .help(Text(L10n.string(title, locale: locale)))
    }

    private var information: String {
        var parts: [String] = []
        if let contextWindow { parts.append(compactContext(contextWindow)) }
        if let pricing {
            // Locale-neutral price notation; the full spoken labels are localized separately.
            parts.append("\u{2191} \(pricing.input)/M")
            parts.append("\u{2193} \(pricing.output)/M")
        }
        return parts.joined(separator: " · ")
    }

    private var informationDescription: String {
        var parts: [String] = []
        if let contextWindow {
            parts.append(L10n.format("Context window: %@ tokens", locale: locale,
                                     contextWindow.formatted(.number.locale(locale))))
        }
        if let pricing {
            parts.append(L10n.format("Input %@/M · Output %@/M", locale: locale, pricing.input, pricing.output))
        }
        return parts.joined(separator: " · ")
    }

    private func compactContext(_ value: Int) -> String {
        if value >= 1_000_000 { return "\((Double(value) / 1_000_000).formatted(.number.precision(.fractionLength(0...1)).locale(locale)))M" }
        if value >= 1_000 { return "\((Double(value) / 1_000).formatted(.number.precision(.fractionLength(0...1)).locale(locale)))K" }
        return String(value)
    }
}
