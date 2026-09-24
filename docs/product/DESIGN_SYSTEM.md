# Mira Design System

This is the macOS 15 SwiftUI visual baseline for Mira. It is an inference from the supplied Codex screenshot: a neutral white canvas, translucent sidebar beneath native window chrome, charcoal type, compact navigation, generous whitespace, and a dark circular primary action. It is not an official Codex token set.

## Tokens

| Token | Light | Dark | Use |
|---|---|---|---|
| `canvas` | `#FFFFFF` | `#1B1B1B` | Main window background |
| `surface` | `#FFFFFF` | `#252525` | Cards and raised surfaces |
| `active` | `#34C759` | `#30D158` | Active provider indicators |
| `modelVision` | `#1C64C7` | `#70AFFF` | Model vision capability and thinking gradient start |
| `modelTools` | `#CE6A0F` | `#FFAD5B` | Model tool capability |
| `modelThinking` | `#8050B5` | `#C095E8` | Thinking gradient end |
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

Color values are appearance-aware. They resolve against Mira's selected display mode; Follow System inherits the current macOS appearance immediately, including when returning from an explicit Light or Dark choice. Native window chrome and hosted SwiftUI panes must switch together.

## Sidebar material

The sidebar uses the native material supplied by `NSSplitViewItem(sidebarWithViewController:)` in `MiraWindowShell`. Keep its content background clear and use `MiraTheme.Colors.canvas` for the window container and detail screens. This prevents the desktop from showing directly through the sidebar's surrounding rim. The sidebar now has a subdued, near-opaque treatment over the canvas; wallpaper color is minimal. Native glass still owns the edge, blur, and accessibility treatment; it has no app-controlled RGB or opacity token.

Preserve the full-height sidebar, including its titlebar area. The native window titlebar is transparent to the material beneath it, without a separate fill or separator. Only the native narrow top, leading, and bottom insets expose the window canvas. Do not override the system glass style, inspect or mutate native glass ancestors, or add custom visual-effect backdrops. The portable export records this system-owned surface under `systemSurfaces.sidebar`. Keep translucent row styling independent of the sidebar material.

Sidebar selection, hover, and pressing share one `sidebarOverlay` fill at 4% opacity (`opacity.sidebarHighlight`). `MiraSidebarRow` draws it once; hovering or pressing an already selected row never adds a second layer or darkens it. The button style forwards pressed state without drawing another background. Text and icons stay fully opaque. Reduce Transparency and Increase Contrast use the same solid `sidebarHighlight` color for these states; increased contrast also retains the selected-row outline.

## Scale and layout

The screenshot suggests a 34 pt navigation row, 30 pt controls, a 220–300 pt sidebar, and an 760 pt reading/composer measure. Spacing uses 4, 8, 12, 16, 24, and 32 pt steps. Radii are 6 pt for small controls, 9 pt for rows, 16 pt for panels, and 22 pt for the composer.

The conversation shell uses `NSSplitViewController` and `NSToolbar`, with each pane hosted by SwiftUI. On macOS 26.1+, the conversation title is rendered in an AppKit split accessory so the system can apply its scroll-edge effect. The title is leading-aligned in the detail pane with a 16 pt local inset when the sidebar is expanded and additional native-button clearance when collapsed; its trailing clearance follows native toolbar controls. Navigation between conversations, Memories and Knowledge recalculates this clearance after the destination's toolbar items finish layout, including Add memory and Import Markdown. The native window name remains synchronized. Earlier systems retain the AppKit title. New conversation, Execution details, and Knowledge stay together on the right. New conversation retains Command-N and its sidebar entry. The conversation sidebar toggle and window controls remain native. The separate settings window keeps its own sidebar visible.

AppKit owns column widths: the sidebar retains its token bounds, the execution inspector uses 180–480 pt, and the conversation has no minimum width. Hosted content cannot impose an additional window minimum. Opening the inspector compresses the conversation at the current window width and preserves the sidebar; only a user sidebar toggle or divider gesture collapses it. Continuing to drag the inspector left after reaching its maximum must leave the sidebar and outer window layout stationary, including while the mouse remains held. The native shell fills its parent viewport throughout the gesture. Content stays clipped to its allocated viewport. Execution details uses the native inspector material and divider; its background need not match the conversation canvas. Sidebar translucency remains system-owned.

执行详情中的键值字段根据自身可用宽度选择横向或上下布局。窄栏中，长标签与值分别占用整行；宽栏中短字段保持横向。长路线标识保留完整文本，不因视觉压缩截断审计事实。此行为由检查器局部的 `LabeledContentStyle` 实现，不改变原生分栏的 180–480 pt 边界或其他设置表单。

The window container owns the conversation's `canvas` background. The conversation detail repeats the shared opaque canvas beneath its transcript; AppKit supplies the execution-details inspector's system material. On macOS 26, the conversation item lets AppKit adjust its safe area beneath neighboring native panes. Message bubbles, composer surfaces, and execution-record cards retain their component backgrounds.

The conversation transcript extends beneath the titlebar through one native `NSScrollView`, using the vendored ListViewKit virtualizer. On macOS 26.1 and later, a real 52 pt `NSSplitViewItemAccessoryViewController` holds `MiraConversationHeaderView` and selects the system `.soft` scroll-edge effect. `Layout.conversationHeaderHeight` owns this height. The split shell cancels the inherited titlebar inset so the accessory, traffic lights and native toolbar actions share one row. The title uses public control frames and the detail safe area during sidebar motion, inspector changes and window resizing; it does not publish asynchronous SwiftUI title padding. The system owns progressive blur and accessibility treatment, without custom blur, fade masks or native glass ancestor manipulation. There is no outer transcript ScrollView, hidden host scrollbar or wheel forwarding. The first row retains 24 pt of space below the header; the floating composer keeps its measured bottom clearance. Earlier systems retain the native window title and standard AppKit titlebar treatment. Sidebar material and toolbar actions remain system-managed.

## Component anatomy and states

`MiraSidebarRow` owns row padding, typography, width, height, and selected fill. Its parent owns the `Button`, action, label content, and accessibility label. `MiraRowButtonStyle` provides a neutral row hover and pressed treatment. `MiraIconButtonStyle` applies the same treatment to a 30 pt square. `MiraPrimaryButtonStyle` is a compact dark text button. `MiraSecondaryButtonStyle` is the bordered neutral action for secondary commands on the canvas. `MiraCircleButtonStyle` is the 30 pt round primary action and visibly dims when disabled. `MiraGlassCircleButtonStyle` is the 36 pt neutral floating action (`Layout.floatingControlSize`), using interactive native Liquid Glass on macOS 26 and regular material on earlier systems. Reduce Transparency or Increase Contrast uses a solid shared surface and outline. `MiraSurface` supplies only a surface fill and border; callers own padding.

Hover and pressed states are immediate and have no animation, so Reduce Motion users receive the same clear state changes. Increased contrast outlines selected rows and interactive row/icon controls. The composer has a quiet 1 pt border and a small background shadow; neither intensifies on focus. Its text insertion caret and native controls retain focus feedback. Disabled controls lower opacity while preserving their shape and placement. Native `Button` focus and keyboard behavior remain owned by SwiftUI.

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

The reading column and composer share an 760 pt maximum content width with 24 pt outer gutters. The welcome state centers the existing Contour Silver mark above a regular-weight title. A provider setup action appears when required. The composer floats over the full-height transcript. Its workspace/local-library shelf, input, and model controls share one rounded glass surface with the existing composer radius, 24 pt horizontal gutters, and a 14 pt bottom margin (`Layout.composerBottomInset`). The composer uses `MiraComposerBackdropView`, an `NSVisualEffectView` with `.withinWindow` blending, `.headerView` material, and `.active` state on all supported macOS versions. It samples conversation content within the window. The shared 22 pt corner radius, 1 pt border at 70% opacity, and 6% black shadow (4 pt radius, 2 pt vertical offset) provide subtle separation without a focus halo. There is no added tint or background fill. The material view uses full opacity in both appearances (`Opacity.composerMaterialLight` is 100%). Native material translucency remains system-defined; foreground controls, input text, border, and shadow keep their existing treatment. The conversation detail paints the shared opaque canvas behind transcript content. Reduce Transparency or Increase Contrast uses the opaque shared surface. The control row shows execution status on the leading side and the model/send controls on the trailing side, with no centered sending or keyboard hint. The model label displays the resolved model name using 11 pt `composerModel` and secondary text color, with an intrinsic label capped at 160 pt and 8 pt spacing to Send. It opens a native menu using shared `MiraModelPickerItems`: compact system typography and spacing, subdued provider section headings, and a current-model checkmark. There is no popover arrow or custom fixed-width panel. Model-default settings offer a fixed model or Follow last selected model; inheritance is not a separate row in the conversation picker. A native horizontal stack separates status and actions with flexible space. There is no separate tips row. The transcript scrolls behind the panel. The complete overlay height, including reply/archival notices and outer spacing, is measured and added as blank document tail space so the final row rests above the panel. The native scroll view keeps a zero bottom content inset and a full-height viewport behind the panel. Tail space updates with multiline input, wrapping, notices and window resizing; no fixed composer height participates in this calculation. Jump to latest is a centered circle 8 pt above this measured region, with only an `arrow.down` symbol. Its localized label remains available to VoiceOver and hover help. The glass button stays mounted and uses a 160 ms opacity transition, disabled by Reduce Motion. It remains visible during scrolling; visibility depends only on distance from the bottom, with a small 8 pt show / 2 pt hide tolerance to avoid layout-rounding flicker. Its appearance never changes transcript insets or the composer position. Local library storage must never imply local model execution.

The conversation does not display a memory extraction disclosure or status panel. Reply/archival notices join the measured floating bottom region. Automatic extraction remains controlled by Memory settings; its replacement feedback presentation is deferred. The optional execution inspector can show scoped extraction job status and per-attempt accounting using existing labels, disclosure groups, and neutral typography. This does not add a transcript status panel or shared tokens.

Knowledge uses the same canvas, list selection, typography and control treatments as Memory. Its source list is 320 pt wide, switching to list-to-detail navigation below a 790 pt main pane; document reading content is capped at 680 pt. These dimensions are owned by `MiraTheme.Layout.knowledgeListWidth`, `knowledgeCompactBreakpoint` and `knowledgeReaderContentMax`. The native toolbar owns import, and the existing `MiraMarkdownView` owns rich text rendering.

User messages are right aligned in a quiet inset bubble. Assistant replies use one compact status line in place of a repeated Mira avatar. The turn-level line appears while waiting or after settlement; once ordered live content arrives, process rows show the activity directly without a duplicate header. While running, each round appears in order: an independent reasoning disclosure, intermediate answer text, and tool rows. Reasoning shows its summary only when collapsed. Generic tool disclosures retain their inline summary and expose one Input/Output card with selectable monospaced text and independently scrollable sections. The shared `MiraHoverDisclosureButton` places a font-sized chevron after the text, visible on hover or keyboard focus without shifting the label. Overflow places it at the trailing edge over a left-to-right transparent-to-canvas fade. Disclosures use SF Symbols `chevron.right` when collapsed and `chevron.down` when expanded. All symbols preserve their native aspect ratio and regular weight instead of stretching into a square. Tool rows use SF Symbols `wrench.fill`; failed tool rows use `xmark.circle.fill` and apply the shared appearance-aware `Colors.failure` token to the trigger text and leading status symbol. The disclosure chevron retains the neutral secondary-text color, including on failed tools. JSON input/output is compact on one horizontally scrollable line; other output retains its original line breaks. After completion, all reasoning (including the final round), intermediate text, and tools fold into a process count summary, with only the final answer text outside the group; reopening the group restores the original order. Opaque continuation data stays hidden. Assistant replies keep their native Markdown renderer, citations, recoverable output, and reading-position behavior. Streaming growth and finalization do not automatically scroll. Initial conversation placement, sending a new user message, and Jump to latest perform one positioning operation; later reply growth leaves the reading position unchanged. Resizing the window or composer preserves bottom alignment only when already near the latest content. Markdown body and table text use 14 pt, fenced code 12 pt, headings 20 pt (large headings 24 pt), and prose uses 2 pt line spacing. Native code/table controls own their internal text metrics; those metrics must not be changed after their enclosing block height has been measured. Paragraph/heading-before/final block spacing is 8 pt, list/general spacing 4 pt, and transcript row bottom spacing 24 pt. These values come from the shared theme. Table cell padding and minimum row height remain owned by the pinned renderer; table typography and surrounding block spacing use the smaller shared scale. Markdown tables, quotes, inline code, and fenced-code chrome use the neutral palette. Links retain an underline; syntax highlighting keeps its semantic colors through MarkdownView’s built-in Xcode syntax palette. The transcript clips to its content viewport so scrolled prose cannot draw over window controls. Memory opens its management screen in the main pane, using the shared window shell and a responsive list/detail layout for current and historical records. Knowledge opens its source list and document reader in the same shell. Tasks retains an inert sidebar row with a “Not implemented yet” help label; no placeholder page or sheet is mounted for it.

The reference's account avatar, development branch controls, and Codex logo are not Mira features. macOS owns window buttons, the resizable sidebar, menus, focus rings, and toolbar controls. The conversation's material and top-edge composition are defined above. The host OS can render these differently from the reference image.

## Settings composition

Settings opens in one standalone SwiftUI `Window` scene. `NavigationSplitView` owns the columns; the sidebar has a fixed 200 pt content width and no Toggle Sidebar toolbar item. The scene uses `.windowManagerRole(.associated)` to stay alongside the conversation in Stage Manager. The conversation window, transcript, draft, model selection and inspector remain mounted and retain their geometry. The app menu and Command-comma open or focus the same settings window, including after closing all conversation windows. Category navigation preserves selected providers, drafts and scroll positions in the open settings session. Closing settings resets navigation and unsaved drafts, stops transient provider work, clears credential editors and releases page observers; persisted preferences remain saved.

Settings follows the user's macOS System Settings light/dark references. Its scoped tokens live in `MiraTheme.Settings`; conversation tokens remain independent. The native sidebar uses system selection and small colored category symbols. SwiftUI `Form` with `.grouped`, `Section`, `LabeledContent`, native `NSPopUpButton` menus, switch-style `Toggle`, and standard text fields/buttons provide the form layout, focus rings, menus, grouping and separators. Provider selection uses the shared icon-and-name card buttons in a horizontal scroll view, in a continuous borderless row with distinct selection and hover backgrounds. Shared sections support trailing title actions, and the credential field displays the saved value through the same native secure input used for new entries, with leading text alignment. A required credential error uses the shared small radius, a system-red outline and inline caption; the existing secure input retains focus and accessibility semantics. The component gallery includes the empty/error state. Selectors size to the currently selected title within explicit width caps. Native window controls and the sidebar material retain their macOS rendering and accessibility behavior. There are no custom popup drawings, chevron animations, or nested vertical provider list scroll panes.

The full reference measurements, token ownership, layout rules and category behavior are defined in [Settings design](SETTINGS_DESIGN.md). Settings row separators use the measured `MiraTheme.Settings.separator` through the shared section component; native grouped Form's default lines are too dark and do not honor List separator tint. Increase Contrast uses the system separator color. Screenshot colors are evidence, not an asserted Apple token set. System-owned colors, materials and control geometry can vary with macOS version, accent, contrast and transparency preferences.

The provider page uses the shared `MiraSettingsLazyPage` to keep large model directories responsive. The rail and editor remain mounted in the scrolling header; collection sections realize only visible rows and a prefetch region. Model identity text reflows through a cached Layout instead of duplicate horizontal/vertical hierarchies. Its opaque group surfaces and geometry use `MiraTheme.Settings`, matching the measured Form appearance. The full card rectangle accepts selection, including padding. Editor ownership is independent of row visibility, so scrolling preserves the credential draft.

## Reusable deliverables

- `Apps/MiraMac/DesignSystem/MiraTheme.swift` is the source of truth.
- `designs/mira-ui/tokens.json` is its portable export; regenerate with `python3 scripts/export_design_tokens.py` after changing tokens. Dimensions are desktop points, not source-image pixels. The JSON is a simple Mira interchange format, not an asserted third-party standard.
- `MiraComponents.swift` contains the row, icon, primary, secondary, circle, and surface primitives.
- `MiraBrandMark.swift` uses appearance variants of the existing supplied vector identity.
- `MiraComponentPreview.swift` provides self-contained light and dark Xcode previews. It opens no database or model provider.

The screenshot is a visual reference only. Its desktop wallpaper and personal sidebar content are not copied into the application or committed as fixtures.

For process-local dark appearance QA, `--design-preview-dark` supplies the initial mode only when no valid display-mode preference is saved. Saved Dark, Light, or Follow System always takes precedence, including during a running QA session. The flag is compiled out of Release and changes no system preference.

Provider model badges respect the saved invocation’s effective capability and modality facts, including explicit negative declarations. Catalog-only rows remain advisory. Official DeepSeek input/output price ranges are labeled off-peak–peak, with a dated pricing-source link and the UTC schedule available in help text. These published ranges do not imply a flat execution cost estimate.

## Bounded Markdown code blocks

Code blocks grow naturally up to `MiraTheme.Markdown.maximumCodeBlockHeight` (320 pt including the fixed language/copy toolbar). Taller blocks scroll vertically inside that viewport; long lines scroll horizontally without forced wrapping. Line numbers track the vertical document offset. Native scrollbar clearance keeps the final line readable while a horizontal scrollbar is visible. Short blocks retain their natural height. The same rule applies to answers and expanded process content. The native transcript yields wheel input to overflowing code regions.
