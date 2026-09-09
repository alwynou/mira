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
        .overlayPreferenceValue(MiraSettingsSelectPreference.self) { presentations in
            if let presentation = presentations.first {
                GeometryReader { geometry in
                    let anchor = geometry[presentation.anchor]
                    Color.clear
                        .contentShape(.rect)
                        .onTapGesture { presentation.dismiss() }
                        .accessibilityHidden(true)
                    MiraSettingsSelectMenuLayout(anchor: anchor) {
                        presentation.content
                            .background(MiraTheme.Colors.surface, in: .rect(cornerRadius: MiraTheme.Radius.row))
                            .overlay {
                                RoundedRectangle(cornerRadius: MiraTheme.Radius.row)
                                    .strokeBorder(MiraTheme.Colors.border, lineWidth: 1)
                            }
                            .shadow(color: .black.opacity(MiraTheme.Opacity.selectShadow),
                                    radius: MiraTheme.Spacing.xs, y: MiraTheme.Spacing.xs / 2)
                    }
                }
            }
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

/// Measure intrinsic content first, then apply only the caller's width bounds.
private struct MiraSettingsSelectWidthLayout: Layout {
    let minimum: CGFloat
    let maximum: CGFloat?

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let ideal = content.sizeThatFits(.unspecified)
        let width = max(minimum, min(ideal.width, maximum ?? .infinity))
        let constrained = content.sizeThatFits(ProposedViewSize(width: width, height: proposal.height))
        return CGSize(width: width, height: constrained.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
    }
}

/// Keep the trailing edge anchored without a measurement-state update or fixed menu width.
private struct MiraSettingsSelectMenuLayout: Layout {
    let anchor: CGRect

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let menu = subviews.first else { return }
        let size = menu.sizeThatFits(.unspecified)
        let x = max(0, min(anchor.maxX - size.width, bounds.width - size.width))
        menu.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + anchor.maxY + MiraTheme.Spacing.xs),
                   anchor: .topLeading, proposal: ProposedViewSize(size))
    }
}

private struct MiraSettingsSelectPresentation {
    let anchor: Anchor<CGRect>
    let content: AnyView
    let dismiss: () -> Void
}

private struct MiraSettingsSelectPreference: PreferenceKey {
    static var defaultValue: [MiraSettingsSelectPresentation] { [] }

    static func reduce(value: inout [MiraSettingsSelectPresentation],
                       nextValue: () -> [MiraSettingsSelectPresentation]) {
        value.append(contentsOf: nextValue())
    }
}

/// A compact selector whose menu is rendered above the settings page's scrolling content.
struct MiraSettingsSelect: View {
    struct Option: Identifiable {
        let id: String
        let title: LocalizedStringKey
    }

    let title: LocalizedStringKey
    @Binding var selection: String
    let options: [Option]
    let identifier: String
    var minimumWidth: CGFloat = MiraTheme.Layout.selectMinWidth
    var maximumWidth: CGFloat? = nil
    var menuMinimumWidth: CGFloat = MiraTheme.Layout.selectMenuMinWidth
    var menuMaximumWidth: CGFloat? = nil
    @State private var isPresented = false
    @State private var isHovered = false
    @FocusState private var isFocused: Bool
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.isEnabled) private var isEnabled

    private var selectedTitle: LocalizedStringKey {
        options.first { $0.id == selection }?.title ?? title
    }

    var body: some View {
        Button { isPresented.toggle() } label: {
            MiraSettingsSelectWidthLayout(minimum: minimumWidth, maximum: maximumWidth) {
                HStack(spacing: MiraTheme.Spacing.sm) {
                    Text(selectedTitle)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(1)
                    Spacer(minLength: 0)
                    Image(systemName: isPresented ? "chevron.up" : "chevron.down")
                        .font(MiraTheme.Typography.caption.weight(.medium))
                        .foregroundStyle(MiraTheme.Colors.secondaryText)
                        .accessibilityHidden(true)
                }
                .font(MiraTheme.Typography.body)
                .foregroundStyle(MiraTheme.Colors.text)
                .padding(.horizontal, MiraTheme.Spacing.md)
                .frame(height: MiraTheme.Layout.selectHeight)
            }
            .background(isPresented || isHovered || isFocused ? MiraTheme.Colors.hover : MiraTheme.Colors.inset,
                        in: .rect(cornerRadius: MiraTheme.Radius.row))
            .overlay {
                RoundedRectangle(cornerRadius: MiraTheme.Radius.row)
                    .strokeBorder(contrast == .increased ? MiraTheme.Colors.secondaryText : MiraTheme.Colors.border,
                                  lineWidth: 1)
            }
            .contentShape(.rect(cornerRadius: MiraTheme.Radius.row))
        }
        .buttonStyle(.plain)
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { isHovered = $0 && isEnabled }
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(selectedTitle))
        .accessibilityIdentifier(identifier)
        .onKeyPress(.downArrow) {
            isPresented = true
            return .handled
        }
        .anchorPreference(key: MiraSettingsSelectPreference.self, value: .bounds) { anchor in
            isPresented ? [MiraSettingsSelectPresentation(
                anchor: anchor,
                content: AnyView(MiraSettingsSelectWidthLayout(minimum: menuMinimumWidth, maximum: menuMaximumWidth) {
                    MiraSettingsSelectOptions(
                        selection: selection, options: options, identifier: identifier,
                        select: { value, restoreFocus in
                            selection = value
                            closeMenu(restoringFocus: restoreFocus)
                        },
                        dismiss: { closeMenu(restoringFocus: true) }
                    )
                }),
                dismiss: { closeMenu(restoringFocus: false) }
            )] : []
        }
        .onDisappear { closeMenu(restoringFocus: false) }
    }

    private func closeMenu(restoringFocus: Bool) {
        // The overlay can hide pointer-exit events. Discard stale hover when it closes.
        isHovered = false
        isPresented = false
        isFocused = restoringFocus
    }
}

private struct MiraSettingsSelectOptions: View {
    let selection: String
    let options: [MiraSettingsSelect.Option]
    let identifier: String
    let select: (String, Bool) -> Void
    @FocusState private var focusedOption: String?
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: MiraTheme.Spacing.xs) {
            ForEach(options) { option in
                Button { select(option.id, false) } label: {
                    MiraSidebarRow(isSelected: selection == option.id, isKeyboardFocused: focusedOption == option.id,
                                   minimumHeight: MiraTheme.Layout.selectHeight) {
                        HStack(spacing: MiraTheme.Spacing.sm) {
                            Text(option.title)
                                .font(MiraTheme.Typography.body)
                                .fixedSize(horizontal: false, vertical: true)
                                .layoutPriority(1)
                            Spacer(minLength: MiraTheme.Spacing.sm)
                            Image(systemName: "checkmark")
                                .font(MiraTheme.Typography.caption.weight(.semibold))
                                .opacity(selection == option.id ? 1 : 0)
                                .accessibilityHidden(true)
                        }
                        .padding(.vertical, MiraTheme.Spacing.xs)
                    }
                }
                .buttonStyle(MiraRowButtonStyle())
                .focusable()
                .focusEffectDisabled()
                .focused($focusedOption, equals: option.id)
                .accessibilityAddTraits(selection == option.id ? .isSelected : [])
                .accessibilityIdentifier("\(identifier).option.\(option.id)")
                .onKeyPress(.return) {
                    select(option.id, true)
                    return .handled
                }
                .onKeyPress(.space) {
                    select(option.id, true)
                    return .handled
                }
            }
        }
        .padding(MiraTheme.Spacing.sm)
        .onAppear { focusedOption = selection }
        .onMoveCommand { direction in
            guard !options.isEmpty else { return }
            let index = options.firstIndex { $0.id == focusedOption } ?? 0
            switch direction {
            case .up: focusedOption = options[max(0, index - 1)].id
            case .down: focusedOption = options[min(options.count - 1, index + 1)].id
            default: break
            }
        }
        .onKeyPress(keys: [.tab], phases: .down) { press in
            guard !options.isEmpty else { return .ignored }
            let index = options.firstIndex { $0.id == focusedOption } ?? 0
            let step = press.modifiers.contains(.shift) ? -1 : 1
            focusedOption = options[(index + step + options.count) % options.count].id
            return .handled
        }
        .onExitCommand { dismiss() }
    }
}
