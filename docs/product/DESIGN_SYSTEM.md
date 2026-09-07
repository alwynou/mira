# Mira Design System

This is the macOS 15 SwiftUI visual baseline for Mira. It is an inference from the supplied Codex screenshot: a neutral white canvas, translucent sidebar beneath native window chrome, charcoal type, compact navigation, generous whitespace, and a dark circular primary action. It is not an official Codex token set.

## Tokens

| Token | Light | Dark | Use |
|---|---|---|---|
| `canvas` | `#FFFFFF` | `#1B1B1B` | Main window background |
| `surface` | `#FFFFFF` | `#252525` | Cards and raised surfaces |
| `inset` | `#F5F5F5` | `#303030` | Composer and quiet insets |
| `text` | `#202020` | `#F2F2F2` | Primary text |
| `secondaryText` | `#666664` | `#B8B8B5` | Supporting text |
| `tertiaryText` | `#92928F` | `#858582` | Metadata and hints |
| `border` | `#E8E8E8` | `#41413F` | Quiet outlines |
| `hover` | `#E5E5E3` | `#353534` | Pointer hover |
| `selected` | `#E3E3E3` | `#41413F` | Selected and pressed state |
| `sidebarOverlay` | `#000000` | `#FFFFFF` | Translucent sidebar interaction overlay |
| `sidebarHighlight` | `#EFEFEF` | `#303030` | Opaque sidebar highlight for accessibility settings |
| `accent` | `#1D1D1B` | `#F2F2F0` | Primary action fill |
| `onAccent` | `#FFFFFF` | `#1A1A1A` | Text or icon on accent |

Color values are appearance-aware. They use the current system light/dark appearance and do not force a color scheme.

## Sidebar material

The sidebar uses the native material supplied by `NavigationSplitView`. Keep its content background clear and the conversation window's container background clear (`.containerBackground(.clear, for: .window)`) so the system can blend and blur colors behind the window. Detail screens retain their opaque canvas. The glass tint follows its surroundings and system appearance; it has no fixed RGB or opacity token. macOS owns the opaque treatment when Reduce Transparency is enabled.

Preserve the original native translucency and full-height sidebar, including its titlebar area. Do not override the system glass style, inspect or mutate native glass ancestors, or add custom visual-effect backdrops. The portable export records this system-owned surface under `systemSurfaces.sidebar`. Keep translucent row styling independent of the sidebar material.

Sidebar selection, hover, and pressing share one `sidebarOverlay` fill at 4% opacity (`opacity.sidebarHighlight`). `MiraSidebarRow` draws it once; hovering or pressing an already selected row never adds a second layer or darkens it. The button style forwards pressed state without drawing another background. Text and icons stay fully opaque. Reduce Transparency and Increase Contrast use the same solid `sidebarHighlight` color for these states; increased contrast also retains the selected-row outline.

## Scale and layout

The screenshot suggests a 34 pt navigation row, 30 pt controls, a 220–300 pt sidebar, and an 760 pt reading/composer measure. Spacing uses 4, 8, 12, 16, 24, and 32 pt steps. Radii are 6 pt for small controls, 9 pt for rows, 16 pt for panels, and 22 pt for the composer.

## Component anatomy and states

`MiraSidebarRow` owns row padding, typography, width, height, and selected fill. Its parent owns the `Button`, action, label content, and accessibility label. `MiraRowButtonStyle` provides a neutral row hover and pressed treatment. `MiraIconButtonStyle` applies the same treatment to a 30 pt square. `MiraPrimaryButtonStyle` is a compact dark text button. `MiraCircleButtonStyle` is the 30 pt round primary action and visibly dims when disabled. `MiraSurface` supplies only a surface fill and border; callers own padding.

Hover and pressed states are immediate and have no animation, so Reduce Motion users receive the same clear state changes. Increased contrast outlines selected rows and interactive row/icon controls. The composer uses a stronger focused outline. Disabled controls lower opacity while preserving their shape and placement. Native `Button` focus and keyboard behavior remain owned by SwiftUI.

## Component inventory and reuse

```swift
Button { selectInbox() } label: {
    MiraSidebarRow(isSelected: selection == .inbox) {
        Label("Inbox", systemImage: "tray")
    }
}
.buttonStyle(MiraRowButtonStyle())

MiraSurface {
    Text("Content")
        .padding(MiraTheme.Spacing.lg)
}

Button(action: send) {
    Image(systemName: "arrow.up")
}
.buttonStyle(MiraCircleButtonStyle())
```

Keep product copy in localization resources. These components provide structure and state styling only; they do not introduce new user-facing strings.

## Typography

Use the macOS system sans serif and SF Symbols. The desktop point scale is 28 regular for the welcome title, 20 semibold for the app name, 14 regular for body/navigation, and 12 regular for section labels and supporting copy. User-authored text and provider identifiers remain verbatim. Keep essential metadata at `secondaryText`; `tertiaryText` is reserved for decorative or redundant hints.

## Conversation composition

The reading column and composer share an 760 pt maximum content width with 24 pt outer gutters. The welcome state centers the existing Contour Silver mark above a regular-weight title. A provider setup action appears when required. The composer has a quiet workspace/local-library shelf behind a white rounded input surface; model selection and the send/stop action occupy its lower edge. The remote-send disclosure remains visible below the composer. Local library storage must never imply local model execution.

The memory extraction disclosure appears once the conversation has messages or execution history. Empty conversations keep the welcome state clear.

User messages are right aligned in a quiet inset bubble. Assistant replies keep their native Markdown renderer, thinking disclosure, citations, recoverable output, and reading-position behavior. Markdown tables, quotes, inline code, and fenced-code chrome use the neutral palette. Links retain an underline; syntax highlighting keeps its semantic colors through the renderer’s built-in GitHub theme. The transcript clips to its content viewport so scrolled prose cannot draw over window controls. Memory/knowledge/task management retain their established native layouts while using the shared neutral palette and primary action style.

The reference's account avatar, development branch controls, and Codex logo are not Mira features. macOS owns window buttons, the resizable sidebar, menus, focus rings, and toolbar treatments. The host OS can render these differently from the reference image.

## Reusable deliverables

- `Apps/MiraMac/DesignSystem/MiraTheme.swift` is the source of truth.
- `designs/mira-ui/tokens.json` is its portable export; regenerate with `python3 scripts/export_design_tokens.py` after changing tokens. Dimensions are desktop points, not source-image pixels. The JSON is a simple Mira interchange format, not an asserted third-party standard.
- `MiraComponents.swift` contains the row, icon, primary, circle, and surface primitives.
- `MiraBrandMark.swift` uses appearance variants of the existing supplied vector identity.
- `MiraComponentPreview.swift` provides self-contained light and dark Xcode previews. It opens no database or model provider.

The screenshot is a visual reference only. Its desktop wallpaper and personal sidebar content are not copied into the application or committed as fixtures.

For process-local dark appearance QA, launch a Debug build with `--design-preview-dark`. This flag is compiled out of Release and changes no system preference.
