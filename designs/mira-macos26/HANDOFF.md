# Mira · macOS 26 UI — 设计交接 (HANDOFF)

这是一个用 HTML/React 做的高保真可交互原型,作为 Mira 原生 SwiftUI 落地的**视觉规格**。
换用其他 agent(Codex/Cursor 等)续做时,先读本文件。

## 文件结构（都在 designs/mira-macos26/）
- `Mira.html` — 入口:加载共享 tokens、基础样式和 CDN 脚本,按依赖顺序加载各 .jsx
- `tokens.css` — Shared light/dark colors, typography, spacing, radii, and control dimensions.
- `STYLE_GUIDE.md` — Token roles, consistency audit, and intentional geometry exceptions.
- `styles.css` — 组件样式(窗口/侧栏/工具栏/对话/输入框/记忆/知识/任务/检查器/设置/命令面板…)
- `icons.jsx` — SF Symbols 风格描线图标集(`I.xxx`)
- `data.jsx` — 全部 mock 数据(工作区/对话/记忆/知识/任务/服务商/模型池)
- `ui.jsx` — 共享基础件(Switch / Seg / IconBtn / FieldRow)
- `panes.jsx` — Sidebar + 四个内容面(ChatView/MemoryView/KnowledgeView/TasksView)
- `model-settings.jsx` — Interactive provider and model configuration screens, validation, and synthetic settings fixtures.
- `provider-catalog.jsx` — Supported provider directory and model metadata derived from the repository catalog.
- `assets/provider-icons/` — LobeHub provider SVGs, pinned source attribution, and MIT license.
- `settings.jsx` — Inspector(第三栏)+ 设置窗口 + 命令面板 + 模型弹层 + Toast
- `app.jsx` — App 编排:状态、路由、键盘快捷键,挂载到 #root
- `_d_meta.json` — 技能的项目资产索引(baoyu-design 用)

## 预览方式（多文件原型,必须走 HTTP,不能直接 file:// 打开）
```sh
python3 -m http.server 4311 --directory designs
# 浏览器打开:
http://localhost:4311/mira-macos26/Mira.html
```

## 重要:缓存
浏览器会缓存 .jsx / .css。`Mira.html` 里每个 `<script src>` 和 `<link>` 都带 `?v=N`。
**改了某个文件（包括 tokens.css）就把它的 `?v=N` 递增一位**,否则刷新看到的还是旧版。

## 已确定的设计约束（请遵守,不要推翻重来）
- 目标:macOS 26 (Tahoe / Liquid Glass) 原生质感;**克制、黑白灰**,唯一强调色=墨黑(发送键/开关);蓝色只用于 focus ring。
- 布局:**两栏默认**(玻璃侧栏 + 实心内容区)+ **按需第三栏**(右侧检查器,默认不显示)。所有功能同窗,非必要不开新窗。
- 材质关系(关键,别搞反):**侧栏=半透明玻璃 + 背景模糊 + 顶部内高光(光影)**;**内容区/工具栏/检查器=不透明实心**。窗口本体透明,让侧栏能模糊透出墙纸。
- 侧栏结构(自上而下):交通灯 + 收起按钮(顶行)→ **Mira 文字标题(无图标)** → 一级入口 **记忆/知识/任务与提醒(无外框图标)** → 分隔线 → 滚动区:**工作区(文件夹,可展开)在上、对话(扁平临时对话,无文件夹)在下**,两组标题都有 `+` → 底部:**设置**(不显示 Anthropic 状态条或外观切换按钮)。设置入口 hover 无背景色，仅图标与文字颜色加深、轻微放大，按下时加深并轻微缩小；不旋转或平移；外观在设置的通用页调整。
- 图标交互:**hover 不加方框**,只做颜色 + 轻微缩放;持续「激活/打开」状态用图标下方一个**小圆点**表示(见 `.icon-btn.on`)。
- 输入框(composer):**磨砂玻璃**、固定悬浮在对话区底部;对话从其**背后滚过并透过玻璃可见**;用动态 `padBottom`(测量 `.composer-wrap` 高度)保证滚到底时最后一条消息**不被遮挡**。结构=占位 + 底栏(`+` / 工具chip / 模型·思考强度 ▾ / 麦克风 / 黑色圆形发送)。
- 设置:**较小的独立居中窗口**(浮在变暗的主界面上),**自带交通灯**在左上;左侧分类栏用主侧栏的**实心配色**(不透明),右侧内容区用**更深一档的分组底色 `--group-bg`**,设置分组是浮在其上的**白色卡片**(块状区分)。红灯/Esc/点窗外均可关闭；顶部不再放「完成」按钮。
- 深色模式:主文字已**降亮**(`--text` #dedee3, with two secondary alpha levels),避免刺眼。
- Shared style values live in `tokens.css`; follow `STYLE_GUIDE.md`. Use five font sizes, three text colors, three font weights, and seven spacing steps. Primary sidebar destinations use body labels, large icons, space-4 gaps, space-3 vertical padding and space-1 margins; counts stay at the caption size. Workspace names, conversation rows and footer Settings use the 14px body token; group headings use the 12px small token.
- Conversation toolbar: show the conversation title only, with no workspace/model subtitle. When the sidebar is collapsed, reserve a leading slot for its restore button in every content toolbar; title text must never overlap it.
- Reply layout: omit the per-reply avatar/name/model header. Show thinking/execution status first, followed by context and tool steps, then the answer. From the first simulated execution phase, show a pending execution label before thinking begins.
- Expandable steps: the header and expanded content share one rounded surface and outer border. Expansion grows that surface; no detached content block or left-side quote rule. Apply this to both thinking and tool execution.
- Memory, knowledge, and task list cards use `--content-bg-2` to separate them from the `--content-bg` page. Hover strengthens the border without introducing another fill token.
- Citation card numbers use plain secondary text with no filled badge background.
- CJK:系统 PingFang 栈,`.cjk` uses `--line-reading` (1.75)。React 18 + Babel standalone,内联 JSX;跨文件组件通过 `Object.assign(window, {...})` 共享。

## 在 Codex(或其他 agent)里怎么开始
1. 让它读本项目:`designs/mira-macos26/`(先读 `_d_meta.json` 与本 HANDOFF.md,再读 `Mira.html`)。
2. 触发同一个设计技能:说“用 baoyu-design 技能,继续 designs/mira-macos26 这个项目”。技能会识别 harness 并读它自己的 Codex 参考文档。
3. 起服务器预览(见上),边改边刷新;改文件记得递增 `?v=N`。

## 待办 / 可继续的方向
- 把这套规格整理成 SwiftUI 的组件/间距 token 清单(NavigationSplitView + List/Section + .ultraThinMaterial 侧栏)。
- 记忆/知识/任务的更多状态与空态、拖拽把对话移进工作区、模型/思考强度选择弹层的真实内容。
- 导出静态截图集或做 2 种布局变体对比。

## Provider and model settings prototype

- The settings category is named “模型”. Keep the existing 760 × 520 maximum window, solid sidebar, grouped background and white cards.
- Settings category navigation shares the primary sidebar typography, icon, and spacing tokens. Provider directory hover fills the entire card width; keep separators inset and clip row backgrounds to the card corners.
- Providers: always list every supported service, including inactive ones. Clicking a provider opens its detail page for API Key configuration, endpoint/protocol settings, simulated connectivity testing, and activation. Local/custom connections can use keyless authentication on loopback endpoints.
- Activation immediately reveals the provider's supported model list. Each model has an activation switch; turning it on adds it directly to the shared model pool, and turning it off removes it. Search and incremental display cover the full catalog. Each row shows the Model ID once, followed by supported tools/thinking/vision capabilities (text-only models show text). The provider hero has an activation switch; deactivation retains model selections and configuration. Do not show manual model creation or a separate deactivation action at the bottom.
- Provider directory and model metadata originate from `Packages/MiraKit/Sources/MiraProviders/Resources/ModelCatalog.json`. Local/custom endpoint entries and the initial configured models are prototype fixtures. Provider logos use unmodified LobeHub SVG silhouettes; see `assets/provider-icons/README.md` and `LICENSE` for the pinned source and attribution.
- Models: “用途默认” is first and selected on category entry. The searchable pool contains activated models from active providers, with eligibility filters, parameter/capability/thinking editing, and purpose defaults. Stale models and unavailable defaults remain visibly unavailable; never silently pick a replacement.
- The settings toolbar always shows back and forward arrows, disabled at history boundaries. History includes categories, model subtabs, and detail pages; navigating after going back discards the forward branch. Do not place navigation-back or Done buttons inside the detail content or toolbar. Active status text and dots use the existing `--tint-green` token.
- Model details open in view mode. A right-aligned Edit/Save button above the information card controls editing; saving validates fields and returns to view mode on the same page. Show activation status before the provider subtitle. Place the immediate model-pool toggle directly below the information card, before capability settings. No bottom Cancel/Save action row.
- Configuration lives in App state: closing/reopening Settings preserves it; reloading resets the synthetic fixtures. Credentials are represented only by a configured flag after save. Never persist or transmit raw credentials from this prototype.
- The composer uses the same eligible model pool and model IDs, opens model management, and reflects the selected model's thinking setting. New conversations use the conversation default. Unavailable selections preserve the message draft.
- Verification: browser checked provider hero activation/deactivation, green status and single-ID capability rows, persistent back/forward history, default purpose tab, model view/edit/save states, invalid output/context validation, and saved values surviving history navigation. Earlier checks covered missing-key activation validation, simulated connection testing, model activation/pool synchronization, pool-to-composer updates, unavailable defaults after provider deactivation, and light/dark settings layouts. These are prototype checks, not native app or live-provider acceptance.
