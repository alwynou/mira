import SwiftUI

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
    let isKeyboardFocused: Bool
    let minimumHeight: CGFloat
    @ViewBuilder let content: () -> Content

    init(isSelected: Bool = false, isKeyboardFocused: Bool = false,
         minimumHeight: CGFloat = MiraTheme.Layout.rowHeight, @ViewBuilder content: @escaping () -> Content) {
        self.isSelected = isSelected
        self.isKeyboardFocused = isKeyboardFocused
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
        isSelected || (isEnabled && (isHovered || isPressed || isKeyboardFocused))
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

struct MiraSurface<Content: View>: View {
    let cornerRadius: CGFloat
    @ViewBuilder let content: () -> Content

    init(cornerRadius: CGFloat = MiraTheme.Radius.panel, @ViewBuilder content: @escaping () -> Content) {
        self.cornerRadius = cornerRadius
        self.content = content
    }

    var body: some View {
        content()
            .background(MiraTheme.Colors.surface, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
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
