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
