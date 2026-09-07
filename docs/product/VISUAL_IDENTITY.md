# Mira visual identity

## App icon

The selected icon is **Contour Silver**: an asymmetrical, continuous ribbon that suggests Mira's M while conveying continuity between conversations, memory, and knowledge. This direction was selected by the user on 2026-09-07 after shape, color, and scale reviews.

- Keep the larger, centered silhouette, occupying approximately four-fifths of the canvas width. Its broad upper turn, continuous shaded surface, and lifted returning tail distinguish it from a plain letter or an infinity symbol.
- Use a black foundation and an achromatic silver-to-graphite ribbon. Let bright and dark reflections flow across the continuous foreground surface without an internal seam. Colored brand gradients are not part of the selected design.
- Retain the same geometry in all system appearances. User-selected clear and tinted treatments are supplied by the platform.
- Use two substantial layers: the continuous foreground ribbon and the returning loop. Thin decorative lines, additional symbols, and text are not part of the mark.
- Preserve the native rounded enclosure and let the system add material effects. Do not bake the standalone presentation SVG's enclosure or shadow into production layers.

The canonical source is `Apps/MiraMac/Resources/MiraAppIcon.icon`. [Engineering evidence and export instructions](../engineering/APP_ICON_DESIGN.md) distinguish the app source from the standalone vector presentation and native PNG exports.

## Website logo

Use `designs/mira-app-icon/final/mira-logo-black.svg` (graphite) on light backgrounds and `mira-logo-white.svg` (silver) on dark backgrounds. Each is a self-contained SVG with the selected ribbon geometry, tonal gradients, subtle edge highlights, and a soft shadow on a transparent background. Both share a 920 × 650 artboard with room for the shadow and contain no app enclosure, bitmap, font, script, or external dependency. Preserve their aspect ratio when sizing them. Their definition IDs are prefixed by variant so both can appear inline on the same page.

## Application interface

The macOS interface uses the [Mira design system](DESIGN_SYSTEM.md): a neutral canvas, quiet sidebar selection, generous reading space, and compact monochrome actions inspired by the user-supplied Codex reference. The existing Contour Silver mark remains the application identity.
