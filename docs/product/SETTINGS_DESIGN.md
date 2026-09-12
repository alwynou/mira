# Native Settings Design

Mira Settings is a separate application window following the supplied macOS System Settings light and dark references. The conversation keeps Mira's existing neutral design and Contour Silver identity. Settings uses native macOS accent selection, grouped forms, standard controls and window materials.

## Reference and token ownership

The two 1670 × 1562 reference PNGs contain a `Color LCD` ICC profile and use approximately two source pixels per point. The table below preserves approximate color-managed sRGB observations, not official Apple constants. Interior patches were sampled without resizing; material colors vary by about 1–3 RGB levels and boundaries by 1–4 source pixels. Glyph bounds do not establish exact font sizes. `MiraTheme.Settings` owns the runtime tokens and system-color mappings exported under `settings` in `designs/mira-ui/tokens.json`. Reference-only measurements stay in this document.

| Role | Light reference | Dark reference | Implementation |
| --- | --- | --- | --- |
| Window/detail canvas | `#FFFFFF` | `#2A2C2C` | `Settings.canvas` |
| Grouped surface | `#F7F7F7` | `#303232` | Native grouped `Form` |
| Sidebar material | `#F9F9F9` | `#202222` | Native `NavigationSplitView` material; varies with surroundings |
| Primary text | `#262626` | `#DFE0E0` | `NSColor.labelColor` |
| Secondary text | `#7C7C7C` | `#A2A2A2` | `NSColor.secondaryLabelColor` |
| Separator | `#EBEBEB` | `#3A3C3C` | `Settings.separator` / shared `MiraSettingsDivider` |
| Accent control | approximately `#0476F6` | approximately `#117DFD` | `NSColor.controlAccentColor`; follows the user's accent |
| Selected sidebar | approximately `#0064E1` | approximately `#0059D1` | Native `List(.sidebar)` selection |
| Inactive control | `#DDDDDD` | `#434545` | Native control state |
| Raised control backing | `#E4E4E4` | `#404242` | Native Picker hover/active treatment |
| On-toggle knob | `#FFFFFF` | approximately `#DFEBFF` | Native switch |

Colored category symbols identify General, Providers, Models, Memory and Data & Privacy. They are decorative companions to localized text, not the only way to recognize a category. SF Symbols and standard system gray, blue, purple and green are used. Third-party provider/model marks keep their existing provenance and purpose.

## Typography and geometry

Dimensions below are desktop points, assuming approximately two source pixels per point. Font glyph bounds do not reveal an exact point size. The selected system-font sizes below are implementation choices consistent with the reference. Native controls retain platform font metrics, baseline alignment, minimum sizes and localization behavior.

| Token / role | Value | Owner |
| --- | --- | --- |
| Body / sidebar | 13 pt regular | `Settings.body` |
| Supporting description | 11 pt regular | `Settings.caption` |
| Category title | 15 pt semibold | `Settings.title`; native top-bar composition |
| Category title horizontal inset | 20 pt | `Settings.titleHorizontalInset` |
| Section heading | approximately 13 pt semibold | Native Form header; `Settings.section` |
| Sidebar content width | 200 pt | SwiftUI sidebar frame and column min/ideal/max are all 200 pt; native outer rim is additional |
| Sidebar row | 32 pt minimum | Native List row |
| Category icon | 20 × 20 pt | `Settings.sidebarIconSize` |
| Icon well radius | 5 pt | `Settings.iconRadius` |
| Sidebar row radius | approximately 9 pt | Native List selection |
| Icon-label gap | approximately 8 pt | Native Label |
| Single-line form row | Reference approximately 38–40 pt; grows with controls | Shared rows with native control metrics |
| Row with short description | Reference approximately 52 pt; grows with wrapping | Shared rows with native LabeledContent |
| Internal row vertical inset | 8 pt above/below separators | `Settings.rowVerticalInset`; outer edges keep native Form padding |
| Separator thickness | 1 pt (2 pixels at 2×) | `Settings.separatorHeight` |
| Group radius | approximately 10–12 pt | Native grouped Form |
| Adjacent group gap | approximately 10 pt | Native grouped Form |
| Gap before a titled section | approximately 28 pt | Native grouped Form |
| Detail outer gutter | approximately 20 pt | Native grouped Form |
| Row horizontal inset | approximately 10 pt | Native grouped Form |
| Label-description gap | 2 pt | `Settings.labelDescriptionGap` |
| New window content size | 840 × 720 pt | Settings window |
| Minimum content size | 760 × 560 pt | Settings root; native toolbar adds to the outer frame height |

The window is deliberately wider than the reference's approximately 723 pt frame to accommodate provider endpoints, model identifiers and English descriptions. The detail form takes the available width. A single Form owns vertical scrolling, including model lists. The root requests the stated minimum through SwiftUI, while macOS owns the final window constraints. Long descriptions and identifiers wrap; controls keep native focus and accessibility semantics. Traffic lights, outer corners, toolbar height, glass inset and titlebar effects remain entirely macOS-owned.

## Window and navigation

- Settings is a singleton SwiftUI `Window` scene (`mira.settings`). App menu, Command-comma and in-app settings links use `openWindow` to open or focus it. It is suppressed at app launch and does not restore itself on a later app launch.
- Opening settings leaves every conversation window, draft, reading position, model choice, inspector and running execution in place.
- Settings uses SwiftUI `.windowManagerRole(.associated)` and opens in front of the current conversation. In Stage Manager it joins the active window set instead of displacing the conversation into the recent-window strip. It remains independently movable, resizable and closable.
- SwiftUI `NavigationSplitView` owns both columns. The native full-height sidebar has five categories, a fixed 200 pt content width and no Toggle Sidebar toolbar item. Its content is clear over the system material. The window canvas supplies the surrounding rim, with no separate titlebar fill or custom glass backdrop.
- On macOS 26, the detail's category title is a SwiftUI `safeAreaBar` coupled to the grouped Form's soft scroll-edge effect. Its height comes from the native toolbar's top safe-area inset. The detail ignores the original top inset outside that bar so it occupies the toolbar region, without adding a second title row. Content progressively blurs and fades under the title while the title stays clear. A native SwiftUI toolbar spacer preserves toolbar chrome without adding an action. Its duplicate visible title is hidden. Settings has no app-owned `NSWindow`, split controller, hosting controller or toolbar delegate. Earlier systems retain the native window title and clipped detail content. There is no return-to-conversation row, sidebar collapse command or nonfunctional navigation control.
- The app retains one `SettingsModel` independently of the scene, preserving category, memory draft and maintenance progress across close/reopen. Page disappearance clears credential inputs and stops transient provider requests. SwiftUI owns the window and view lifecycle. Persistent preference changes continue to apply to all Mira windows.
- Display-language changes update the sidebar, form and title while settings remains open. Appearance inherits the existing app-wide preference, including returning to Follow System.

## Native component composition

`MiraSettingsPage` is a grouped Form. `MiraSettingsSection` emits a real Section; Form retains section headers, rounded backgrounds, outer insets, scrolling and native control adaptation. Inside each section, public `Group(subviews:)` composition inserts one shared separator between resolved rows. This is necessary because grouped Form ignores `listRowSeparatorTint` on the verified macOS host. `MiraSettingsDivider` draws a 1 pt line using the measured light/dark token and switches to `NSColor.separatorColor` for Increase Contrast. No private view inspection or global appearance override is used. `MiraSettingsRow` uses LabeledContent for title, description and trailing controls. `MiraSettingsFormRow` uses the centered field style described below.

`MiraSettingsTitlebar` owns the SwiftUI top-bar composition. Forms retain their automatic native background and request `.scrollEdgeEffectStyle(.soft, for: .top)` on macOS 26. Solid detail backgrounds and a clip outside the scrolling composition must not cover or cut off this region. No blur radius, opacity overlay, desktop transparency or custom backdrop view is used. Apple describes the distinction between control glass and progressive scroll-edge effects in [Build an AppKit app with the new design](https://developer.apple.com/videos/play/wwdc2025/310/?time=567).

`MiraSettingsSelect` uses a SwiftUI menu Picker. It retains localized versus verbatim option titles and explicit clear/inherit actions. Missing selections show the placeholder without silently selecting or rewriting the stored value. Empty option lists disable the control. Native menus own selection checks, keyboard navigation, Escape dismissal, accessibility and display-edge placement. No custom control drawing, popup positioning, chevron animation or focus replacement is used.

Field rows use a scoped LabeledContent style with explicit center alignment between the title and native control. Supporting descriptions sit below that pair at full row width. This avoids the grouped Form's baseline alignment for API keys, proxy URLs and numeric inputs. Controls retain their native labels, focus and trailing value alignment.

Buttons delegate to bordered or bordered-prominent native styles. Save/Discard actions belong at the bottom of the configuration group they apply to, separated by the shared row divider; they do not form their own rounded card. Provider actions stay inside the provider connection group, and memory actions stay inside the budget group. Text fields use standard rounded borders. Toggles use native switches. The app does not freeze the dimensions or RGB values of native controls, so newer macOS rendering and system accessibility preferences can apply.

## Category behavior

General retains Display Language and Display Mode. These are presentation preferences only: user text, historical data, model identifiers and requests remain verbatim. Appearance offers Dark, Light and Follow System. The app never writes a system-wide appearance preference.

Providers uses one native provider selector, grouped into Active and Inactive entries, above the selected service's form. The directory remains OpenAI, Anthropic, Kimi Code, Moonshot, DeepSeek and OpenRouter. Kimi Code and Moonshot remain distinct services. There is no provider-directory search or Add Provider screen. The first displayed entry is selected by default; switching services clears transient credential input and cancels pending tests.

The selected service retains activation, API key, proxy URL, test model, Test/Cancel, Save/Discard and model-pool controls. Saving is local; activation still requires the established successful test. Opening settings and selecting providers never initiates a paid request. Stored key reuse, revision conflict checks, model capability checks, frozen routes and explicit external-test actions are unchanged. Model lists keep their icons, capability symbols, pricing/context information, native switches and context menus in the Form's scroll flow.

Models retains conversation and memory-extraction purpose defaults, scope selection, explicit inheritance/clear actions, Save/Discard and Manage Providers. Memory retains capture mode, conditional model setup guidance, daily token budget, remaining budget and Save/Discard. Data & Privacy retains library diagnostics, backup/restore and cleanup actions with their existing semantics. This design change does not alter storage, provider contracts, prompts or schema.

## Verification

Current native evidence and unverified platform checks are recorded in [native settings verification](../engineering/NATIVE_SETTINGS_VERIFICATION.md). Regenerate tokens with `scripts/export_design_tokens.py`. The component gallery has self-contained English/light and Chinese/dark SwiftUI settings navigation examples without opening a library, using credentials or sending requests.

Apple describes this grouped settings pattern in [What's new in AppKit](https://developer.apple.com/videos/play/wwdc2022/10074/?time=294). The implementation follows the public native pattern; the supplied screenshots do not reveal Apple's private source or exact material constants.
