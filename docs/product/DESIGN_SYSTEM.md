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

The sidebar uses the native material supplied by `NSSplitViewItem(sidebarWithViewController:)` in `MiraWindowShell`. Keep its content background clear and use `MiraTheme.Colors.canvas` for the window container and detail screens. This prevents the desktop from showing directly through the sidebar's surrounding rim. The sidebar now has a subdued, near-opaque treatment over the canvas; wallpaper color is minimal. Native glass still owns the edge, blur, and accessibility treatment; it has no app-controlled RGB or opacity token.

Preserve the full-height sidebar, including its titlebar area. The native window titlebar is transparent to the material beneath it, without a separate fill or separator. Only the native narrow top, leading, and bottom insets expose the window canvas. Do not override the system glass style, inspect or mutate native glass ancestors, or add custom visual-effect backdrops. The portable export records this system-owned surface under `systemSurfaces.sidebar`. Keep translucent row styling independent of the sidebar material.

Sidebar selection, hover, and pressing share one `sidebarOverlay` fill at 4% opacity (`opacity.sidebarHighlight`). `MiraSidebarRow` draws it once; hovering or pressing an already selected row never adds a second layer or darkens it. The button style forwards pressed state without drawing another background. Text and icons stay fully opaque. Reduce Transparency and Increase Contrast use the same solid `sidebarHighlight` color for these states; increased contrast also retains the selected-row outline.

## Scale and layout

The screenshot suggests a 34 pt navigation row, 30 pt controls, a 220–300 pt sidebar, and an 760 pt reading/composer measure. Spacing uses 4, 8, 12, 16, 24, and 32 pt steps. Radii are 6 pt for small controls, 9 pt for rows, 16 pt for panels, and 22 pt for the composer.

The shared conversation/settings shell uses `NSSplitViewController` and `NSToolbar`, with each pane hosted by SwiftUI. The window uses the native AppKit title with no custom width cap or title replacement. New conversation, Execution details, and Knowledge stay together on the right. New conversation retains Command-N and its sidebar entry. The conversation sidebar toggle and window controls remain native; settings keeps its sidebar visible without a toggle.

AppKit owns column widths: the sidebar retains its token bounds, the execution inspector uses 180–480 pt, and the conversation has no minimum width. Hosted content cannot impose an additional window minimum. Opening the inspector compresses the conversation at the current window width and preserves the sidebar; only a user sidebar toggle or divider gesture collapses it. Continuing to drag the inspector left after reaching its maximum must leave the sidebar and outer window layout stationary, including while the mouse remains held. The native shell fills its parent viewport throughout the gesture. Content stays clipped to its allocated viewport. Execution details uses the native inspector material and divider; its background need not match the conversation canvas. Sidebar translucency remains system-owned.

The window container owns the conversation's `canvas` background. Conversation and execution-details pane roots do not paint separate full-pane fills; AppKit supplies the inspector's system material. On macOS 26, the conversation item lets AppKit adjust its safe area beneath neighboring native panes. Message bubbles, composer surfaces, and execution-record cards retain their component backgrounds.

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

User messages are right aligned in a quiet inset bubble. Assistant replies keep their native Markdown renderer, thinking disclosure, citations, recoverable output, and reading-position behavior. Markdown tables, quotes, inline code, and fenced-code chrome use the neutral palette. Links retain an underline; syntax highlighting keeps its semantic colors through the renderer’s built-in GitHub theme. The transcript clips to its content viewport so scrolled prose cannot draw over window controls. Memory, Knowledge, and Tasks retain their sidebar rows but have no navigation action while replacement management interfaces are pending. Their help label indicates that they are not implemented yet. No placeholder page or sheet is mounted.

The reference's account avatar, development branch controls, and Codex logo are not Mira features. macOS owns window buttons, the resizable sidebar, menus, focus rings, and toolbar treatments. The host OS can render these differently from the reference image.

## Settings composition

Settings is a mode of the current main window. Its existing AppKit split controller stays in place while the sidebar and detail hosts switch to settings content. The execution inspector is temporarily hidden, with its conversation visibility preference retained for return. The same window size, native corners, traffic-light insets, full-height sidebar material, and column width remain in use. Entering settings reveals the sidebar and prevents collapse through divider gestures or sidebar commands. Settings has no sidebar toggle, toolbar return action, or backward/forward/title strip. Returning restores the conversation's previous sidebar visibility. The app menu and Command-comma target the focused main window; in-app settings links target their own window.

The five categories are General, Providers, Models, Memory, and Data & Privacy. The left column reuses `MiraSidebarRow` and the conversation sidebar's width, insets, and row spacing. Back to Mira uses the same row and button style as the categories, including its full-width hover/pressed background and accessibility treatment; its label and arrow use the quieter `secondaryText` color. Its row starts immediately below the native titlebar/traffic-light safe area, with no additional top padding and with `lg` bottom spacing before the categories; no Settings heading or reserved heading space separates them. Clicking Providers returns from a provider detail to the directory. Returning restores the conversation; conversation selection, composer draft, model choice, and reading intent remain owned by the window. Running conversations continue through the application runtime while settings is visible. The shared window content has an 850 × 620 pt minimum.

`MiraSettingsPage` supplies the same `canvas` background as conversation content and the existing reading-width cap; the status footer uses that canvas too. Providers and Models show the footer only for operation status or errors, without a persistent demo-mode notice or empty footer space. `MiraSettingsSection`, `MiraSettingsRow`, `MiraSettingsDivider`, and `MiraSettingsSearchField` compose groups using the existing surface, border, typography, spacing, and radius tokens. Panels use the shared `panel` radius and navigation uses the shared `row` radius. They introduce no separate settings palette or corner treatment. Native pickers, menus, disclosure groups, secure fields, and buttons retain keyboard and accessibility behavior.

Every category page begins with `MiraSettingsHeader`: the category name in the existing 20 pt semibold `title` style, followed by a concise description in the 12 pt `caption` style and `secondaryText` color. The two lines retain `sm` (8 pt) spacing. Below the subtitle, the header adds `sm` to the page's `xl` group spacing, placing the first content block 32 pt below the subtitle; subsequent groups retain 24 pt spacing. The title has the accessibility heading trait, and descriptions can wrap at narrow widths without clipping. General describes display language; Providers describes provider connections and models; Models describes defaults and the model pool; Memory describes automatic memory and extraction limits; Data & Privacy describes local storage, backups, and cleanup. Copy lives in the English/Simplified Chinese string catalog. Providers keeps Add Provider beside its header, and individual provider details retain their provider name and endpoint heading.

The settings page begins 64 pt below the window's top edge, using `Layout.settingsPageTopInset`. Its top inset replaces the native top safe-area offset instead of adding to it. Horizontal and bottom gutters remain `xxl`; scrolling content clips below the fixed top inset.

Providers uses a searchable list of saved connections and unconfigured bundled templates. Selecting a row opens its detail in the same column. Connection settings expand inline; changing API credentials or endpoint still requires explicit Save. A provider template is not an activated connection, and activating a provider does not enable models or certify capabilities. Model discovery and synthetic capability tests retain their explicit actions.

Models separates Purpose Defaults and Model Pool. Defaults show one card per implemented purpose (conversation and memory extraction), with a shared global/workspace/conversation scope selector. Selecting an option does not save it until Save Selection is pressed. Existing inherited and unavailable route states remain visible. Memory keeps capture, budget, route, reload, and save controls; Data & Privacy keeps diagnostics, backup, restore, and cleanup actions.

Changing categories or leaving settings retains preference drafts and local maintenance progress in window-owned presentation models. Only the active settings page is mounted and observing library updates. Inactive pages do not participate in layout, keyboard handling, or accessibility. Provider credentials are cleared when their editor leaves the detail column, and a dirty provider draft retains its original revision for conflict detection.

The supplied settings images define layout only. General retains the existing language setting; unimplemented appearance preferences, global search shortcuts, and additional model purposes are not introduced. The shared window supports the process-local dark appearance QA flag.

## Reusable deliverables

- `Apps/MiraMac/DesignSystem/MiraTheme.swift` is the source of truth.
- `designs/mira-ui/tokens.json` is its portable export; regenerate with `python3 scripts/export_design_tokens.py` after changing tokens. Dimensions are desktop points, not source-image pixels. The JSON is a simple Mira interchange format, not an asserted third-party standard.
- `MiraComponents.swift` contains the row, icon, primary, circle, and surface primitives.
- `MiraBrandMark.swift` uses appearance variants of the existing supplied vector identity.
- `MiraComponentPreview.swift` provides self-contained light and dark Xcode previews. It opens no database or model provider.

The screenshot is a visual reference only. Its desktop wallpaper and personal sidebar content are not copied into the application or committed as fixtures.

For process-local dark appearance QA, launch a Debug build with `--design-preview-dark`. This flag is compiled out of Release and changes no system preference.
