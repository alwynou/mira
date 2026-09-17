# Native Settings Design

Mira Settings is a separate application window following the supplied macOS System Settings light and dark references. The conversation keeps Mira's existing neutral design and Contour Silver identity. Settings uses native macOS accent selection, grouped forms, standard controls and window materials.

## Reference and token ownership

The two 1670 × 1562 reference PNGs contain a `Color LCD` ICC profile and use approximately two source pixels per point. The table below preserves approximate color-managed sRGB observations, not official Apple constants. Interior patches were sampled without resizing; material colors vary by about 1–3 RGB levels and boundaries by 1–4 source pixels. Glyph bounds do not establish exact font sizes. `MiraTheme.Settings` owns the runtime tokens and system-color mappings exported under `settings` in `designs/mira-ui/tokens.json`. Reference-only measurements stay in this document.

| Role | Light reference | Dark reference | Implementation |
| --- | --- | --- | --- |
| Window/detail canvas | `#FFFFFF` | `#2A2C2C` | `Settings.canvas` |
| Grouped surface | `#F7F7F7` | `#303232` | Native grouped `Form`; shared `Settings.groupSurface` for lazy collections |
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
| Provider selection card | 108 pt wide, at least 96 pt high, 8 pt radius | `Settings.providerCardWidth`, `providerCardMinHeight`, `providerCardRadius` |
| Selected provider fill | Accent at 10% opacity with accent outline | `Settings.providerCardSelectionOpacity` |
| New window content size | 840 × 720 pt | Settings window |
| Minimum content size | 760 × 560 pt | Settings root; native toolbar adds to the outer frame height |

The window is deliberately wider than the reference's approximately 723 pt frame to accommodate provider endpoints, model identifiers and English descriptions. The detail takes the available width. Each page has one vertical scroll surface. Providers uses a row-lazy collection; the other categories use grouped Form. The root requests the stated minimum through SwiftUI, while macOS owns the final window constraints. Long descriptions and identifiers wrap; controls keep native focus and accessibility semantics. Traffic lights, outer corners, toolbar height, glass inset and titlebar effects remain entirely macOS-owned.

## Window and navigation

- Settings is a singleton SwiftUI `Window` scene (`mira.settings`). App menu, Command-comma and in-app settings links use `openWindow` to open or focus it. It is suppressed at app launch and does not restore itself on a later app launch.
- Opening settings leaves every conversation window, draft, reading position, model choice, inspector and running execution in place.
- Settings uses SwiftUI `.windowManagerRole(.associated)` and opens in front of the current conversation. In Stage Manager it joins the active window set instead of displacing the conversation into the recent-window strip. It remains independently movable, resizable and closable.
- SwiftUI `NavigationSplitView` owns both columns. The native full-height sidebar has five categories, a fixed 200 pt content width and no Toggle Sidebar toolbar item. Its content is clear over the system material. The window canvas supplies the surrounding rim, with no separate titlebar fill or custom glass backdrop.
- On macOS 26, the detail's category title is a SwiftUI `safeAreaBar` coupled to the page's soft scroll-edge effect. Its height comes from the native toolbar's top safe-area inset. The detail ignores the original top inset outside that bar so it occupies the toolbar region, without adding a second title row. Content progressively blurs and fades under the title while the title stays clear. A native SwiftUI toolbar spacer preserves toolbar chrome without adding an action. Its duplicate visible title is hidden. Settings has no app-owned `NSWindow`, split controller, hosting controller or toolbar delegate. Earlier systems retain the native window title and clipped detail content. There is no return-to-conversation row, sidebar collapse command or nonfunctional navigation control.
- The app retains one `SettingsModel` independently of the scene, retaining visited categories, provider selections, field drafts and scroll positions within one open settings session. Category navigation pauses page observations while retaining the page hierarchy. Closing the window clears transient credentials and drafts, releases visited pages and returns navigation to General. Reopening reloads persisted values; an already-running library maintenance operation retains its owner. SwiftUI owns the window and view lifecycle. Persistent preference changes continue to apply to all Mira windows.
- Display-language changes update the sidebar, form and title while settings remains open. Appearance inherits the existing app-wide preference, including returning to Follow System.

## Native component composition

`MiraSettingsPage` is a grouped Form. `MiraSettingsSection` emits a real Section; Form retains section headers, rounded backgrounds, outer insets, scrolling and native control adaptation. Inside each section, public `Group(subviews:)` composition inserts one shared separator between resolved rows. This is necessary because grouped Form ignores `listRowSeparatorTint` on the verified macOS host. `MiraSettingsDivider` draws a 1 pt line using the measured light/dark token and switches to `NSColor.separatorColor` for Increase Contrast. No private view inspection or global appearance override is used. `MiraSettingsRow` uses LabeledContent for title, description and trailing controls. `MiraSettingsFormRow` uses the centered field style described below.

`MiraSettingsTitlebar` owns the SwiftUI top-bar composition. Forms retain their automatic native background and request `.scrollEdgeEffectStyle(.soft, for: .top)` on macOS 26. Solid detail backgrounds and a clip outside the scrolling composition must not cover or cut off this region. No blur radius, opacity overlay, desktop transparency or custom backdrop view is used. Apple describes the distinction between control glass and progressive scroll-edge effects in [Build an AppKit app with the new design](https://developer.apple.com/videos/play/wwdc2025/310/?time=567).

`MiraSettingsSelect` hosts a native NSPopUpButton and NSMenu. Menu options are native items rather than individual SwiftUI view hierarchies, avoiding repeated view construction for large model catalogs. Unchanged entries retain the same menu across selection updates. A native sizing probe measures only the selected title, with measurements reused by title and control style. Short values stay compact even when the menu contains long alternatives; explicit width caps constrain long selected identifiers. It retains localized versus verbatim option titles and explicit clear/inherit actions. Missing selections show the placeholder without silently selecting or rewriting the stored value. Empty option lists disable the control. Native menus own selection checks, keyboard navigation, Escape dismissal, accessibility and display-edge placement. No custom control drawing, popup positioning, chevron animation or focus replacement is used.

Field rows use a scoped LabeledContent style with explicit center alignment between the title and native control. Supporting descriptions sit below that pair at full row width. This avoids the grouped Form's baseline alignment for API keys, proxy URLs and numeric inputs. Controls retain their native labels and focus. Text input values align to the leading edge; compact controls remain aligned within the trailing control column.

Action buttons delegate to bordered or bordered-prominent native styles. Save/Discard actions belong at the bottom of the configuration group they apply to, separated by the shared row divider; they do not form their own rounded card. Connection actions stay inside the provider connection group. Memory has no editable budget or Save/Discard actions. `MiraSettingsSection` also accepts trailing header actions; model refresh and manual addition use this slot beside Provider Models. Text fields use standard rounded borders. Toggles use native switches. The app does not freeze the dimensions or RGB values of native controls, so newer macOS rendering and system accessibility preferences can apply.

Providers uses `MiraSettingsLazyPage`: one ScrollView and LazyVStack. The provider rail and editor remain mounted in the scrolling header; the header scrolls normally. Small groups remain complete view units; model sections opt into `isCollection` and preserve their typed ForEach, with each model wrapped in `MiraSettingsLazyRow`. This avoids grouped Form's eager layout and keeps connection field identities together. The shared row shell reproduces the measured group surface (`Settings.groupSurface`), 10 pt inset/radius/gap and 28 pt titled-section top inset. Separators, typography, native fields, popup menus, buttons and switches are shared with Form pages. Section surfaces use opaque colors and retain the Increase Contrast separator treatment. Provider cards have an explicit rectangular hit area covering the full padded label. Model names and IDs use one pair of text views with cached adaptive layout: inline when they fit, stacked otherwise. This preserves wrapping while avoiding duplicate candidate hierarchies during scrolling.

The connection editor model is owned above lazy rows: scrolling and category navigation preserve drafts and explicit tests. Each provider editor is retained for the open window session. Closing the settings window clears those editors and cancels transient work.

## Category behavior

General retains Display Language and Display Mode. These are presentation preferences only: user text, historical data, model identifiers and requests remain verbatim. Appearance offers Dark, Light and Follow System. The app never writes a system-wide appearance preference.

Providers displays icon-and-name buttons in one horizontal scroll view above the selected service's form. The directory order is OpenAI, Anthropic, Kimi Code, Moonshot, DeepSeek and OpenRouter, regardless of activation state. Kimi Code and Moonshot remain distinct services. `MiraProviderSelectionCard` forms a continuous row with zero spacing and no item borders. Selection uses a subtle accent background and hover uses a separate background; it preserves native button semantics and exposes the selected accessibility trait. The selected card scrolls into view. The initial selection prefers an active saved connection, then an inactive connection, then the first unconfigured service. Switching services selects the corresponding retained detail editor, preserving each service's unsaved key, endpoint and test-model selection until the window closes. There is no provider-directory search or Add Provider screen.

The selected service retains activation, API key, proxy URL, test model, Test/Cancel, Save/Discard and model-pool controls. Saving is local; enabling persists the requested state when a nonempty entered or stored key is available and does not run a network probe. The switch immediately reflects the requested state while persistence is active; it returns to the persisted state on failure or cancellation. Repeated requests for the current state do not save again. With no entered or stored key, the switch remains clickable: an enable attempt keeps it off, focuses the secure field and shows a red outline with the localized required-key message directly below. Entering a nonempty value clears this validation state; discarding or closing also resets it. Opening settings and selecting providers never initiates a paid request. Explicit Test remains available for early credential validation, while model use remains the final check for the selected route. Stored key reuse, revision conflict checks, model capability checks, frozen routes and explicit external-test actions are unchanged. Model lists keep their icons, capability symbols, pricing/context information, native switches and context menus in the page's shared scroll flow.

`MiraSettingsCredentialField` loads the saved value into the native SecureField for the open window session, producing the same populated, masked appearance as a newly entered key. It does not use placeholder dots. The presentation model compares the draft to the saved value so an unrelated save does not rotate the credential. An empty replacement still reuses the stored credential. Keys remain persisted only in Keychain and are released from the editor when settings closes. Test feedback sits directly below its Test control in the same row without an intervening divider. Model refresh and manual addition appear at the right of the Provider Models title for configured services. Successful list loading has no footer or success banner. Empty results, failures and capability-test feedback remain inline with the model section.

Models retains the conversation default, scope selection, explicit inheritance/clear actions, Save/Discard and Manage Providers. Memory explains automatic capture using the conversation model and shows local embedding preparation/status. It has no capture-mode selector, extraction-model routing, or daily budget controls. Data & Privacy exposes current library diagnostics, independent backup restoration, explicit restored-library activation and unreferenced-file cleanup. This design change does not alter storage, provider contracts, prompts or schema.

## Verification

Current native evidence and unverified platform checks are recorded in [native settings verification](../engineering/NATIVE_SETTINGS_VERIFICATION.md). Regenerate tokens with `scripts/export_design_tokens.py`. The component gallery has self-contained English/light and Chinese/dark SwiftUI settings navigation examples without opening a library, using credentials or sending requests.

Apple describes this grouped settings pattern in [What's new in AppKit](https://developer.apple.com/videos/play/wwdc2022/10074/?time=294). The implementation follows the public native pattern; the supplied screenshots do not reveal Apple's private source or exact material constants.

## 新核心 Data 设置行为

2026-09-14：Data 页面直接使用新资料库服务。导出等待活动工作暂停，恢复先验证并创建独立目录，再由“打开恢复后的资料库”明确切换。切换会关闭原库并清理它专属的通知；正常用户库选择保存在宿主目录，重启继续使用所选库。显式开发数据路径和演示不会改写正常用户选择。清理移除未引用的托管文件，保留被引用的历史版本与现有备份；界面展示真实维护完成状态，移除旧实现的七天等待说明与无法由新维护协议提供的文件计数。关闭窗口清除展示结果，已接纳的操作继续由服务拥有。技术边界与流程图见[资料库设置契约](../architecture/MAC_LIBRARY_SETTINGS.md)。完整 App 的原生交互与视觉验收仍待 Provider 页面完成后执行。

## 新核心的模型配置交互

服务商连接、模型池与用途绑定分别编辑。连接的启用和保存只做本地校验；“测试”使用当前 URL／密钥草稿和合成输入，不携带对话内容，也不自动保存配置。窗口关闭后清除密钥草稿，已接纳保存继续完成。无法由当前表单处理的连接配置明确显示不可编辑状态，不显示可保存的猜测字段。

模型池编辑器显式选择 HTTP 协议家族，按模块描述符呈现思考模式、强度和预算。上下文窗口允许留空保存，但未知限制的模型不能执行。目录建议需主动应用；能力声明与测试验证分开，测试结果需主动保存。取消、保存后的关闭和键盘默认操作保持原生表单语义。

用途选择按全局、工作区和会话分开保存；记忆提取仅列出具备所需 JSON 能力的可用模型。会话范围每页 128 项，显式加载更多；普通刷新保留已经加载的会话页，维护后重置。多窗口同时编辑使用修订冲突反馈，不能覆盖另一窗口的新配置。
