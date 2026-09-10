import SwiftUI
import AppKit

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

/// Centers the hint without letting either control group overlap it.
struct MiraComposerBarLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? MiraTheme.Layout.composerMax
        let sizes = measuredSizes(width: width, subviews: subviews)
        return CGSize(width: width, height: max(MiraTheme.Layout.controlHeight, sizes.map(\.height).max() ?? 0))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = measuredSizes(width: bounds.width, subviews: subviews)
        guard sizes.count == 3 else { return }
        for index in 0..<3 {
            let x = index == 0 ? bounds.minX + sizes[index].width / 2
                : (index == 1 ? bounds.midX : bounds.maxX - sizes[index].width / 2)
            subviews[index].place(at: CGPoint(x: x, y: bounds.midY), anchor: .center,
                                  proposal: ProposedViewSize(sizes[index]))
        }
    }

    private func measuredSizes(width: CGFloat, subviews: Subviews) -> [CGSize] {
        guard subviews.count == 3 else { return [] }
        let sideWidth = max(0, width * 0.4)
        let leading = subviews[0].sizeThatFits(.init(width: sideWidth, height: nil))
        let trailing = subviews[2].sizeThatFits(.init(width: sideWidth, height: nil))
        let centerWidth = max(0, width - 2 * (max(leading.width, trailing.width) + MiraTheme.Spacing.sm))
        let center = subviews[1].sizeThatFits(.init(width: centerWidth, height: nil))
        return [leading, center, trailing]
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
