# Mira prototype style foundations

`tokens.css` is the single source of shared visual values. `styles.css` and JSX inline styles consume these tokens. This is the existing prototype's style contract, not a new design system or project.

## Scale and usage

| Category | Tokens / values | Usage |
| --- | --- | --- |
| Typography | `--font-caption` 11px, `--font-small` 12px, `--font-body` 14px, `--font-heading` 16px, `--font-title` 20px | Counts and metadata; descriptions and compact controls; body and primary navigation; page headings; brand/window identity. A component normally uses two or three sizes. |
| Weight | `--weight-normal` 400, `--weight-medium` 500, `--weight-strong` 600 | Normal, selected/control, heading/emphasis. No fractional weights. |
| Line height | `--line-tight` 1.25, `--line-ui` 1.5, `--line-reading` 1.75 | Headings, controls, long text/CJK. Superscript citations retain a unit line box. |
| Text | `--text`, `--text-2`, `--text-3` | Primary, secondary, tertiary. Do not introduce a separate heading ink or extra muted level. Disabled controls may use opacity as a state. |
| Opaque surfaces | `--content-bg`, `--content-bg-2`, `--group-bg` | Page base and settings cards; subtle memory/knowledge/task cards and solid settings rail; grouped settings backdrop. List cards keep their subtle fill on hover and strengthen the border. |
| Interaction fills | `--fill-hover`, `--fill-active` | Hover and selected/pressed. These are states, not additional text or surface levels. |
| Borders | `--hairline`, `--hairline-strong` | Dividers/card outlines; controls/emphasis. Glass highlights use `--glass-border`. |
| Semantic color | `--tint-blue`, `--tint-green`, `--tint-amber`, `--tint-red` | Informational, active/success, pending/warning, error. Retain one color per status in each theme. |
| Spacing | `--space-1` … `--space-7`: 2, 4, 8, 12, 16, 24, 32px | Micro offsets, label/chip gaps, compact rows, row/card spacing, panel padding, section/page spacing, large content gutters. Zero and auto are layout keywords. |
| Radius | `--r-sm` 6px, `--r-md` 10px, `--r-lg` 14px, `--r-composer` 22px | Controls/tags, small cards, cards/windows, composer. `--r-pill` and 50% represent shapes, not more corner levels. |
| Control height | `--control-compact` 28px, `--control-regular` 32px | Buttons and regular fields. Switch geometry is separate. |
| Icons | `--icon-sm` 12px, `--icon-md` 16px, `--icon-lg` 20px, `--icon-display` 24px | Inline metadata, controls, primary navigation, empty-state illustrations. Provider brand silhouettes have their own fixed display boxes. |
| Motion | `--dur-fast` .16s, `--dur` .22s | Micro feedback and surface transitions. Execution progress timing and reduced-motion overrides are separate. |

## Material and layout boundaries

- Keep translucent sidebar, frosted composer, and stronger popover glass as three intentional materials. Content, toolbars, inspector, and settings remain opaque. Wallpaper gradients, glass, scrim, scrollbar, traffic lights, and elevation are separate rendering contexts; do not count their colors as text levels.
- Native traffic lights preserve their identifying hues. The dark theme changes color/material tokens only; typography and spacing do not change.
- Window dimensions, column widths, switch/thumb geometry, hairline thickness, provider brand boxes, and overlay anchors are structural values. They are not extra spacing tiers. The thread's 160px pre-measurement composer clearance and command palette's 96px anchor are deliberate layout exceptions.
- Main primary navigation and settings categories use body text, large icons, a 12px gap, and 8px vertical padding. Workspace names, conversation rows, and footer Settings also use the 14px body token. Group headings use the 12px small token. Counts stay at 11px.
- Footer Settings keeps transparent hover, color changes, and scale feedback; no rotation or translation. Provider row hover covers the entire card width.
- Keep button labels and metadata chips whole. In narrow columns, wrap whole chips/filter groups rather than individual words.
- When changing a shared value, edit the token instead of adding component-specific numbers. Only add a token for a new recurring role, not for a one-pixel visual preference. Increment the corresponding `?v=N` in `Mira.html`.

## Consistency audit — 2026-09-07

Source audit across the entry document, component CSS, and presentation JSX (excluding model/data fixtures and SVG path geometry):

| Category | Before | After |
| --- | --- | --- |
| Font sizes | 16 distinct values | 5 shared values |
| Font weights | 11 distinct values | 3 shared values |
| Text line heights | 8 values including citation geometry | 3 roles plus the citation line box |
| Neutral text colors | 5 overlapping levels | 3 roles |
| Divider/control border colors | 3 levels | 2 roles |
| Opaque surface backgrounds | 4 colors | 3 roles |
| Ordinary layout spacing | Many near-duplicate pixel values | 7 shared steps |

Component CSS and presentation JSX contain no literal font sizes/weights or raw text/background colors. Colors and elevations are centralized in `tokens.css`. Runtime review covers light conversation/settings/provider/purpose/model-edit screens and dark settings/memory/knowledge/tasks/inspector screens. Browser measurements confirm the rendered text sizes belong to the shared scale. These are HTML prototype checks, not native SwiftUI acceptance.

## SwiftUI mapping — spec vs prototype-only

The prototype is a **visual reference, not a pixel contract**. SwiftUI has its own feel; match the *roles* (layout, color intent, hierarchy, spacing rhythm), not the exact values. Two groups of tokens:

**Portable (reproduce the intent).** These carry the design decisions:

| Prototype token | SwiftUI intent |
| --- | --- |
| `--text` / `--text-2` / `--text-3` | `.primary` / `.secondary` / `.tertiary` foreground styles |
| `--hairline` / `--hairline-strong` | `Divider`, `.separator`, or `.quaternary` strokes |
| `--fill-hover` / `--fill-active` | hover/selection states — list selection, `.quaternary` fill; don't hand-roll if the control gives it |
| `--accent` (ink) / `--accent-text` | monochrome primary action (label `.primary` on filled black/white) — **not** the system blue accent; keep blue for focus only |
| `--tint-blue/green/amber/red` | status roles: info / success / pending / error (one per status per theme) |
| `--content-bg` | window/content base — `Color(nsColor: .textBackgroundColor)` |
| `--content-bg-2` | raised/subtle cards & solid rail — `Color(nsColor: .controlBackgroundColor)` |
| `--group-bg` + white cards | **`Form { }.formStyle(.grouped)`** gives this grouped backdrop + inset cards for free |
| `--sidebar-bg` (glass) | `NavigationSplitView` sidebar vibrancy (automatic) — do not paint a solid color |
| `--font-caption…title` (5 sizes) | `.caption` / `.footnote` / `.body` / `.headline` / `.title3` (or explicit `Font.system(size:)`) |
| `--weight-normal/medium/strong` | `.regular` / `.medium` / `.semibold` |
| `--line-tight/ui/reading` | default / default / larger `lineSpacing` (reading & CJK) |
| `--space-1…7` (2·4·8·12·16·24·32) | one `CGFloat` spacing enum reused for padding/`spacing:` |
| `--r-sm/md/lg` (6·10·14), `--r-composer` 22, pill | `RoundedRectangle(cornerRadius:)`; pill = `Capsule()` |
| `--control-compact/regular` (28·32), `--icon-*` | `controlSize` / SF Symbol `imageScale`; sizes are guidance, not exact |

**Prototype-only (let SwiftUI/system provide it — do not port values).** `--wallpaper` (desktop shows through window vibrancy), `--glass-*` alphas (→ `.ultraThinMaterial` sidebar, `.thinMaterial`/`.regularMaterial` composer & popovers), all `--sh-*` shadows (→ material elevation + system window/sheet shadows), `--scrim`, `--scroll-thumb`, `--thumb`, `--dur*`/`--ease` (→ `.snappy`/`.easeOut`), `--traffic-*` (real `NSWindow` buttons).

**Layout the framework gives you for free:**
- Two columns + on-demand third pane → `NavigationSplitView` (sidebar + detail) plus the `.inspector { }` modifier (macOS 14+) for the right pane.
- Floating glass composer that content scrolls behind **without hiding the last message** → `.safeAreaInset(edge: .bottom) { composer }` — it reserves the space natively, replacing the prototype's measured `padBottom`.
- Grouped settings look (`--group-bg` + cards) → `Form` + `.formStyle(.grouped)`.
- Settings as a separate smaller window → the `Settings { }` scene (⌘,).

So `tokens.css` stays the prototype's source of truth for *this* HTML; for Swift, treat the "Portable" table as the brief and ignore the "Prototype-only" values.
