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
            MiraModelIdentityLayout {
                title
                modelIDChip
            }
            let information = information
            if !information.isEmpty {
                let description = informationDescription
                Text(verbatim: information)
                    .font(MiraTheme.Settings.caption)
                    .foregroundStyle(MiraTheme.Settings.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(Text(verbatim: description))
                    .help(Text(verbatim: description))
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

/// Reflows the same two text views instead of measuring duplicate horizontal and
/// vertical hierarchies for each newly visible model. Measurements survive the
/// repeated width proposals made while the lazy collection is scrolling.
private struct MiraModelIdentityLayout: Layout {
    struct Measurement {
        let size: CGSize
        let titleSize: CGSize
        let identifierSize: CGSize
        let titleOrigin: CGPoint
        let identifierOrigin: CGPoint
    }

    struct Cache {
        var measurements: [CGFloat: Measurement] = [:]
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache.measurements.removeAll(keepingCapacity: true)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        measurement(proposal: proposal, subviews: subviews, cache: &cache).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let layout = measurement(proposal: proposal, subviews: subviews, cache: &cache)
        subviews[0].place(at: CGPoint(x: bounds.minX + layout.titleOrigin.x, y: bounds.minY + layout.titleOrigin.y),
                          anchor: .topLeading, proposal: ProposedViewSize(layout.titleSize))
        subviews[1].place(at: CGPoint(x: bounds.minX + layout.identifierOrigin.x, y: bounds.minY + layout.identifierOrigin.y),
                          anchor: .topLeading, proposal: ProposedViewSize(layout.identifierSize))
    }

    private func measurement(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> Measurement {
        let width = max(0, proposal.width ?? .infinity)
        if let cached = cache.measurements[width] { return cached }
        let title = subviews[0].dimensions(in: .unspecified)
        let identifier = subviews[1].dimensions(in: .unspecified)
        let inlineWidth = title.width + MiraTheme.Spacing.sm + identifier.width
        let result: Measurement
        if inlineWidth <= width {
            let baseline = max(title[.firstTextBaseline], identifier[.firstTextBaseline])
            let titleY = baseline - title[.firstTextBaseline]
            let identifierY = baseline - identifier[.firstTextBaseline]
            result = Measurement(
                size: CGSize(width: inlineWidth, height: max(titleY + title.height, identifierY + identifier.height)),
                titleSize: CGSize(width: title.width, height: title.height),
                identifierSize: CGSize(width: identifier.width, height: identifier.height),
                titleOrigin: CGPoint(x: 0, y: titleY), identifierOrigin: CGPoint(x: title.width + MiraTheme.Spacing.sm, y: identifierY))
        } else {
            let titleSize = subviews[0].sizeThatFits(.init(width: width, height: nil))
            let identifierSize = subviews[1].sizeThatFits(.init(width: width, height: nil))
            result = Measurement(
                size: CGSize(width: max(titleSize.width, identifierSize.width), height: titleSize.height + MiraTheme.Spacing.xs + identifierSize.height),
                titleSize: titleSize, identifierSize: identifierSize, titleOrigin: .zero,
                identifierOrigin: CGPoint(x: 0, y: titleSize.height + MiraTheme.Spacing.xs))
        }
        // Window resizing must not accumulate every historical width.
        if cache.measurements.count >= 4 { cache.measurements.removeAll(keepingCapacity: true) }
        cache.measurements[width] = result
        return result
    }
}
