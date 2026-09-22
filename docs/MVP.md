# Mira MVP 范围与实施计划

The [bilingual process-restart memory evaluation](engineering/MEMORY_CONTINUITY_VERIFICATION.md) adds a two-process host harness, exact memory/source/receipt preservation checks and bounded budget accounting. English and Chinese ordinary-memory recall passed after orderly process restart. Both explicit saves passed receipt/source/deduplication checks, but their restart follow-ups remain unqualified after the bounded recovery runs reached their establishment caps. A launcher path-alias defect and its original reports are preserved; all runs used 24/32 authorizations. Chinese recall also exposed noncanonical visible citation formatting. [#52](https://github.com/alwynou/mira/issues/52) remains open for these gaps; broad M3 quality is unchanged.

The [memory save acknowledgment correction](engineering/MEMORY_SAVE_ACKNOWLEDGMENT_VERIFICATION.md) shares conversation instructions between the app and evaluators, distinguishing current-conversation understanding from a receipt-backed save or future-use promise. Focused package and host checks passed. An initial Chinese sample still made a premature future-use promise; the final bounded first-reply sample acknowledged the preference without that promise and retained normal background capture. The task used 8/8 authorizations; later extraction/follow-up stages in the confirmation run were capped and are not a full workflow pass. General model wording reliability and broad M3 quality remain open.

The [withdrawal near-miss evaluation](engineering/MEMORY_WITHDRAWAL_NEAR_MISS_VERIFICATION.md) adds authored English/Chinese quotation, hypothetical and ambiguity cases with exact unchanged-state checks before/after background extraction and reopening. Failed evaluations retain available execution audit and partial usage without replacing their primary error; reply lookup binds the exact execution. Final English quotation and Chinese hypothetical samples passed, with all four exploratory/confirmation reports preserved and 22/24 authorizations used. Premature saved-memory wording is tracked separately in [#49](https://github.com/alwynou/mira/issues/49). This is evaluation coverage, not a change to production semantic authorization or a broad M3 quality claim.

The [clear memory withdrawal increment](engineering/MEMORY_RETRACTION_VERIFICATION.md) archives an exact assertion without inventing a replacement, retains separate withdrawal provenance and prevents old-source recapture. Focused transaction, privacy, replay and reopen checks passed; bounded model evidence and the local native-window test limitation are recorded in the verification note. This does not close broad M3 semantic quality or the unclassified failure in [#43](https://github.com/alwynou/mira/issues/43).

The [Chinese memory correction follow-up](engineering/CHINESE_MEMORY_CORRECTION_VERIFICATION.md) preserves typed admission/completion errors in the evaluation harness. Two independent synthetic reruns completed with 14 of 24 allowed request authorizations, correct replacement history/source identity and fresh-session answers. The previous `storage` failure did not recur and remains unclassified in [#43](https://github.com/alwynou/mira/issues/43); these samples do not establish a general Chinese-memory success rate.

The [memory correction and extraction diagnostics increment](engineering/MEMORY_CORRECTION_VERIFICATION.md) adds exact foreground replacement with atomic source/revision guards, safe extraction error categories, a bounded thinking-capable output allowance and the existing aspect-key grammar in the model schema. Focused checks passed. Four synthetic live runs used 46 request authorizations: English correction, explicit-save follow-up and pure-background enrichment have successful samples. That sample left Chinese correction unqualified after an unclassified failure before its first state snapshot, tracked in [#43](https://github.com/alwynou/mira/issues/43). This does not close general M3 quality or unresolved retraction acceptance.

The earlier [bounded memory state evaluation](engineering/MEMORY_STATE_EVALUATION.md) records seven synthetic scenarios with 47 request authorizations, verifies forget/reopen and unsupported-inference handling, and preserves its original failures. Evaluator checks distinguish persisted memory state and lineage from reply keyword observations.

The [foreground memory enrichment follow-up](engineering/FOREGROUND_MEMORY_ENRICHMENT_VERIFICATION.md) addresses the separate `memory.remember` tool path and preserves authorized historical context across the resulting supersession. It corrects the earlier investigation's incomplete attribution of the reported duplicates to background extraction alone.

The [memory enrichment correction](engineering/MEMORY_ENRICHMENT_VERIFICATION.md) adds an explicit same-entity enrichment decision and atomic evolution with retained evidence, addressing duplicate current memories or lost added details. Synthetic verification and its limits are recorded separately; this increment does not close live-model memory-quality acceptance.

**版本：** v1.0  
**日期：** 2026-09-07

Production tool verification on 2026-09-15 reproduced inherited-context rejection across all eight registered tools and task-list/mutation failures after successful commits. Source ownership and immutable task-revision authorization are corrected, with Responses schema/stream fixes and scoped package/host checks. [Tool verification](engineering/TOOL_VERIFICATION.md) records the evidence, development-library reset, and remaining live-model/native workflow limits.

The 2026-09-16 [memory redesign plan](engineering/MEMORY_IMPLEMENTATION_PLAN.md) was first evaluated in an isolated [Qwen/MLX native prototype](engineering/MEMORY_EMBEDDING_PROTOTYPE.md). BF16 passed all prototype checks; the community 4-bit model retains one failed numeric-reference gate. These historical prototype results do not close M3 quality gates.

An [expanded BF16/4-bit comparison](engineering/EMBEDDING_PRECISION_COMPARISON.md) supported the user's selection of 4-bit for its substantially smaller resident footprint and preserved observed Recall@6, with BF16 retained as a development reference. The [production integration](engineering/LOCAL_MEMORY_IMPLEMENTATION.md) now connects this model to revision-bound vectors, hybrid recall and batched automatic extraction in the native app. Release and memory-quality gates remain open as recorded there.

The subsequent user-requested [daily quota removal](engineering/LOCAL_MEMORY_IMPLEMENTATION.md#daily-quota-removal-follow-up) removes the default 10,000-token extraction gate and budget settings after a real four-turn run was rejected before dispatch. Actual usage/cache accounting and per-request model limits remain.

The [memory search relevance correction](engineering/MEMORY_SEARCH_RELEVANCE.md) filters low-scoring vector neighbors so small libraries no longer return every memory for unrelated queries. Focused tool/store tests and a real local-model fixture passed; broad answerability calibration remains open.

**状态：** M0–M5 的核心功能和本机开发验证已实现，发布质量与跨平台验收仍待完成。普通对话自动记忆、记忆演变、自然召回、Markdown 问答预取，以及 M6 的任务和一次性本地提醒底层能力保留。2026-09-20 已重建 macOS Memory 管理界面，提供当前／历史、范围、搜索、排序、分页、详情、手动保存、编辑、替代、归档和遗忘；Knowledge 与 Tasks 管理界面仍暂缓。2026-09-08 移除旧界面的记录是历史状态，旧原生界面验收不代表当前版本已验收。Memory 管理的原生证据与未验证范围见 [Memory management verification](engineering/MEMORY_MANAGEMENT_VERIFICATION.md)；该增量不代表完整 M3 验收、真实模型质量通过或 macOS 15 原生运行验证。本机通知授权、应用完全退出后的普通提醒送达，以及重启后的到期状态曾通过用户配合验收。专注模式与正式分发按用户选择暂缓。其他历史证据与跳过项见 [功能增量验收](engineering/FUNCTIONAL_MILESTONES_VERIFICATION.md)。

服务商接入流程已按“配置并激活服务商 → 选择服务商模型 → 模型池 → 选择模型”更新，模型池阶段验收见 [模型池验收记录](engineering/PROVIDER_POOL_VERIFICATION.md)。新增服务商目录、models.dev 资料和用途筛选的当前范围见 [目录与筛选验收](engineering/MODEL_CATALOG_VERIFICATION.md)。

Thinking is now part of the M1–M2 implementation scope: provider controls, separate streaming display, process-local streams until settlement, and protocol-correct tool continuation. The contract is [Thinking](architecture/THINKING.md); acceptance and remaining live checks are recorded in [Thinking verification](engineering/THINKING_VERIFICATION.md).

Formula rendering now validates and resolves native images before drawing, with verbatim LaTeX fallback for undrawable images. Scoped regression and native acceptance evidence is recorded in [formula rendering verification](engineering/MATH_RENDERING_VERIFICATION.md).

已形成借鉴 DSH、坚持核心优先的 Swift [Agent 核心架构方案](architecture/AGENT_CORE_PROPOSAL.md)与[实施计划](engineering/AGENT_CORE_IMPLEMENTATION_PLAN.md)，包含作用域扩展、拟议会话日志方案、核心架构图和执行流程图。用户已于 2026-09-13 授权通过 Goal 在 `codex/agent-core` 分支实施；iOS 暂不实现。新会话以日志为权威，业务事实保留在独立领域 SQLite，各阶段通过证据验收，不提前标记核心已完成。

新核心已实现规范会话日志（DSH v3 语义事件、inline 正文和 transaction commit 标记，见[规范会话日志](architecture/AGENT_SESSION_LOG.md)）、执行循环、作用域模块、模型与工具、调度与审批、来源授权、业务回执、记忆／知识／任务、持久维护及独立资料库恢复。macOS 的会话、工作区、记忆、Data 和 Provider 设置直接使用新服务，完整 App 已恢复构建；没有旧会话 SQL 仓库、旧模型协议或兼容运行时。核心继续只依赖 Foundation，平台能力由宿主模块组装。

当前日志按语义 turn／step 结构记录请求、助手消息、尝试、工具调用和结果；结算时保存有序输出块，重放通过已提交消息和工具事件派生。流在结算前保持进程内，日志不保存完整 HTTP 请求副本或活动草稿 sidecar。[DSH source research](engineering/DSH_SESSION_LOG_RESEARCH.md)记录历史设计依据；其历史工程指标不改变当前[规范会话日志](architecture/AGENT_SESSION_LOG.md)。

当前验收与准确测试结果统一记录在[核心验证记录](engineering/AGENT_CORE_VERIFICATION.md)。持久偏移索引与完整状态检查点已实现并可从日志重建；会话全文检索与宿主服务已实现；六类[公开扩展挑战](engineering/AGENT_CORE_EXTENSION_CHALLENGE.md)已通过，默认循环和会话归约器未为案例修改；另已通过[16 个真实进程终止与恢复场景](engineering/AGENT_PROCESS_CRASH_VERIFICATION.md)。[历史记忆状态查询](architecture/AGENT_MEMORY_HISTORY.md)及宿主提示刷新已接通；[独立后台提取状态与费用查询](architecture/AGENT_EXTRACTION_QUERIES.md)已接入检查器；[规模实测](engineering/AGENT_CORE_SCALE_VERIFICATION.md)已覆盖十万真实消息的文件读取路径及一万记忆／五万知识片段的领域检索，修复候选正文排序超时、短语排名和启动全库正文遍历问题；同库核心启动 P95 已从约 7.00 秒降至 2.45 秒，恢复摘要保持日志与必需扩展校验；联合参考库、完整上下文及原生启动仍未通过验收。剩余失败矩阵、尚未关闭的原生行为边界与完整原生流程列为后续验收；首轮本地演示不代替这些验收。原验收行为与未关闭缺口见[验收承接清单](engineering/AGENT_CORE_ACCEPTANCE_TRANSFER.md)。用户于 2026-09-14 确认收缩范围，以已确认正确性修复、核心关键链路及集成回归、中文文档与图示收尾；该范围的[核心重建已完成](engineering/AGENT_CORE_COMPLETION.md)。联合规模、严格 P95、完整原生矩阵、Instruments 和穷举故障窗口列为后续产品验收，不再自动扩大本次 Goal；iOS 不实现。

BYOK 模型层已按[批准方案](architecture/BYOK_MODEL_LAYER_PROPOSAL.md)完成直接重写：连接与多调用规格分离、字段事实解析、完整发现缓存和公共资料刷新、日志会话选择，以及有序输出／独立隐藏续接均已接通。Chat、Anthropic、Responses 的合成协议验收与完整包 1,040 项测试通过；宿主 267 项通过、1 项真实账号测试按开关跳过，最终 App 构建及本机原生检查完成。未知模型 ID 可保存和启用，无内置目录或强制探测门槛；缺少明确上下文限制时发送前提示补充。中文架构图、执行流程图、数据清理及真实端点／在线刷新等未验证范围见[BYOK 验收记录](engineering/BYOK_MODEL_LAYER_VERIFICATION.md)。不保留旧格式兼容层。

普通回复误触发块数量上限及重试重复回答已修复：传输片段合并到稳定语义块，Thinking 完整追加；用户重试先清理该问题的旧生成数据，再在原回答位置重新生成。删除失败阻止新派发，重开补完清理。完整包 1,052 项、宿主 269 项通过（另 1 项真实账号测试跳过），App 构建与本机演示停止／重试／重开检查完成；证据和线上端点等剩余范围见[修复验收](engineering/STREAM_RETRY_CORRECTION.md)。

Historical M1 streaming layout, auto-follow, and bounded appended-text fades passed local native checks; evidence and remaining scale/platform limits are recorded in [streaming performance](engineering/STREAMING_PERFORMANCE.md). The follow-up [long-conversation measurements](engineering/LONG_CONVERSATION_PERFORMANCE.md) cover 100 retained messages and smooth automatic scrolling. This improves streaming service latency but does not close the strict 100 ms/frame-hitch or manual platform gates.

After the isolated [MarkdownView/ListViewKit comparison](engineering/RENDERER_COMPARISON.md), the user approved direct adoption. Mira now uses MarkdownView with ListViewKit, and the previous renderer source and dependencies are removed. [Replacement verification](engineering/RENDERER_REPLACEMENT.md) records local evidence and remaining native/platform acceptance gaps. The [core workflow follow-up](engineering/CORE_WORKFLOW_VERIFICATION.md) fixes memory navigation/receipt and knowledge source-presentation defects, with synthetic application-reopen and backup continuity checks. These checks improve v0.1 readiness without closing the remaining real-model, native interaction, or delivery gates. The [streaming layout correction](engineering/MARKDOWN_LAYOUT_VERIFICATION.md) fixes post-layout metric changes and stale fade snapshot restoration, with failing-before/passing-after overlap coverage and native stable-prefix checks. The [floating composer](engineering/FLOATING_COMPOSER.md) uses `NSVisualEffectView` with window-local blending, full material opacity, and a 14 pt bottom gap.

A user-authorized [live DeepSeek memory walkthrough](engineering/CORE_WORKFLOW_VERIFICATION.md#authorized-native-memory-follow-up) passed save, explicit remote-use review, new-conversation recall, semantic replacement, historical citations, and forgetting without reviving the old preference. The subsequent [natural association and retained-history fix](engineering/NATURAL_MEMORY_VERIFICATION.md) corrects lifecycle labels and local-only acknowledgments, verifies an ordinary template request, and preserves forgotten-memory replies with tags while excluding them from future model context. This single-model smoke test does not close automatic-memory quality, other-provider, restart, or platform acceptance.

The [ordinary capture and stable-prefix fix](engineering/AUTOMATIC_CAPTURE_PREFIX_VERIFICATION.md) extends automatic-active recognition to bounded routine preferences, adds native Chinese short-word recall, separates dynamic memory from system instructions, and makes capture-off status explicit. It retains opt-in configuration, dedicated extraction routing, and conservative review gates; it does not establish general semantic-memory quality.

The [everyday conversation baseline](engineering/EVERYDAY_MEMORY_VERIFICATION.md) adds 32 natural scenarios and a native XCUITest suite. Three native UI workflows passed. That historical increment accepted 2/16 authored positive cases; its 12-dispatch real-model sample confirmed one successful continuity case and one missed activation, with two incomplete cases. The current [natural memory evolution](engineering/NATURAL_MEMORY_EVOLUTION_VERIFICATION.md) replaces the extraction contract and broadens the deterministic gate. The historical report remains unchanged; current measurements belong to the new verification records and do not close the independent M3 quality gates.

The [usage and cost increment](engineering/USAGE_COST_VERIFICATION.md) adds provider cache/thinking counters and frozen per-call estimates, with separate foreground/background presentation. Unsupported or incomplete billing dimensions remain explicitly unknown. This does not close attended acceptance or introduce a monetary hard limit.


The user-selected [Contour Silver app icon](product/VISUAL_IDENTITY.md) is integrated; [native rendering and Debug build evidence](engineering/APP_ICON_DESIGN.md) is recorded separately from platform runtime acceptance.

The [Mira design system](product/DESIGN_SYSTEM.md) extracts a screenshot-inspired neutral visual language into SwiftUI tokens, reusable components, and a portable JSON export. Native implementation and verification scope are recorded in [interface verification](engineering/DESIGN_SYSTEM_VERIFICATION.md).

The conversation composer and context shelf share a floating window-local material over the native transcript, with dynamically measured document-tail clearance and a full-height native scroll viewport, a quiet constant border/shadow, centered tips, and compact model controls. Reply typography is compact, and streaming preserves reading position without automatic scrolling. See [floating composer verification](engineering/FLOATING_COMPOSER.md). The conversation memory-extraction disclosure and unused view are removed; background extraction and Memory settings remain available. Replacement feedback presentation is deferred. The [composer shortcut update](engineering/COMPOSER_SHORTCUTS.md) removes the centered hint and uses Return to send and Command-Return for a newline.

Settings now has a standalone SwiftUI Window scene and NavigationSplitView following the supplied macOS System Settings references, with a fixed 200 pt sidebar and no sidebar toggle. Scoped light/dark tokens and measured typography/layout are recorded in [Settings design](product/SETTINGS_DESIGN.md). Native grouped forms, menus, controls and sidebar selection replace the prior same-window settings mode and custom selector rendering. Providers use a continuous borderless icon selector, populated secure key fields, inline test feedback and model actions beside the section title. Open settings sessions retain page selections, scroll positions and unsaved drafts; closing resets transient state. Provider hit areas, lazy model rows, scoped configuration notifications and bounded reads address switching stalls. Activation controls persist a locally validated enabled state when a key is available; explicit Test and model use report credential failures, and save notifications cannot discard their own result. The [first-activation fix](engineering/PROVIDER_KEY_ACTIVATION.md) refreshes model switches immediately and preserves the newly configured provider selection. See [provider settings performance](engineering/PROVIDER_SETTINGS_PERFORMANCE.md). The five settings categories remain. Current acceptance evidence and outstanding platform checks are recorded in [native settings verification](engineering/NATIVE_SETTINGS_VERIFICATION.md).

Conversation switching now activates independent cached pages without reloading snapshots, retaining drafts and native viewports. A bounded recent-page cache releases older rendering resources while preserving reading state. New Conversation reuses one unsent draft; first send atomically creates the conversation and queued turn without empty records on failure. Native first placement targets the destination before display. A centered circular glass Jump to latest action remains available during scrolling, with bottom-edge visibility tolerance; verification and remaining performance limits are recorded in [conversation switching](engineering/CONVERSATION_SWITCHING.md).

The conversation window uses an AppKit split controller and toolbar with SwiftUI pane content. The macOS 26 conversation title is leading-aligned to the detail pane with a 16 pt local inset and additional native-button clearance when the sidebar is collapsed. Assistant rows use a compact expandable activity line in place of the repeated Mira avatar; live status moves from thinking to answering, and bounded tool summaries remain inspectable. Cancellation or interruption preserves visible partial output for continuation or retry without replaying incomplete tools or opaque continuation data. [Focused conversation-flow verification](engineering/CONVERSATION_FLOW_VERIFICATION.md) records phase, history, authorization, and native UI checks. Completion now hands the last streamed body to durable content without clearing or rebuilding identical Markdown; [focused completion-rendering verification](engineering/COMPLETION_RENDERING_VERIFICATION.md) records retention, fade, and native continuity checks. [Window-shell verification](engineering/APPKIT_WINDOW_SHELL.md) covers the 850 pt inspector layout, native commands, retained drafts, and pane-state synchronization; platform and performance limits remain explicit. Its [native scroll-edge titlebar](engineering/CONVERSATION_TITLEBAR.md) uses one native NSScrollView beneath a 52 pt split accessory on macOS 26.1+, with virtual rows, progressive blur, and a title that moves with the native sidebar. The outer SwiftUI scroll host and wheel forwarding are removed. Earlier systems retain the native window title; focused acceptance and remaining platform checks are recorded in the titlebar evidence.

The [appearance transition fix](engineering/APPEARANCE_TRANSITIONS.md) removes competing application/SwiftUI overrides so Dark → Follow System restores hosted panes consistently, with failing-before/passing-after native hosting coverage.

本文只决定做什么、按什么依赖顺序做、完成到什么程度可以进入下一阶段。产品行为由 [PRD 与领域产品规范](PRD.md) 定义，技术契约由 [架构总览及领域设计](ARCHITECTURE.md) 定义，测试数值门槛由 [质量标准](engineering/QUALITY.md#quality-gates) 统一维护。

## 1. 已确认的范围

用户已确认：

- 首个 MVP 聚焦对话、可纠正记忆、Markdown 文件检索和最小 Agent 工具循环。
- Task / Reminder 在紧接着的下一版本推进。
- 首批接入 Chat Completions、Anthropic Messages；2026-09-14 按已批准 BYOK 重设计增加完整 OpenAI Responses，本增量不实现 Google 原生。
- 支持 2024 年发布的 macOS 15 及后续版本，采用直接下载安装，不走 Mac App Store。
- 文档按职责拆分，PRD 与架构总览不承担全部详细设计。

工具链、依赖锁定、签名与分发默认见 [开发约定](engineering/DEVELOPMENT.md)。版本号是范围标识，不是发布日期承诺。

## 2. v0.1 的完成定义

用户可以配置自己的 Provider，在 Workspace 中对话，明确保存或自动形成有来源的记忆，在新对话中正确召回，并查看、编辑、撤销和遗忘；可以导入 Markdown，让 Agent 搜索并引用资料；退出重开后，原始数据和已提交结果仍可用。

完成必须同时满足功能、来源与隐私边界、异常恢复、数据导出恢复以及质量门槛。出现跨 Workspace 泄漏、遗忘后自动复活、无授权写入、错误引用或不可恢复数据丢失时，不以“聊天已经能用”为理由发布。

### 2.1 功能清单与规范入口

| ID | v0.1 范围 | 规范来源 | 验收阶段 |
|---|---|---|---|
| F01 | Workspace / Inbox、创建与归档对话、固定项目背景、文本消息与历史浏览 | [工作空间产品规范](product/WORKSPACE_AND_CONVERSATION.md)、[Runtime](architecture/RUNTIME.md) | M1 |
| F02 | 两类 Provider 连接、API Key、手工 Model ID、用途级配置、能力验证、流式与取消 | [Provider 设计](architecture/PROVIDERS.md) | M1 |
| F03 | 单对话单活动执行、工具配对、拒绝与错误回执、有界循环和最小执行检查器 | [Runtime](architecture/RUNTIME.md) | M2 |
| F04 | 手动保存、明确记住、批量自动捕获开关、来源与 Scope、修改 / 替代 / 撤销 / 遗忘 | [记忆产品规范](product/MEMORY_AND_KNOWLEDGE.md)、[记忆设计](architecture/MEMORY_AND_KNOWLEDGE.md) | M3 |
| F05 | Active Memory 有限预取、Agent 主动搜索、最小 Context Inspector 与有效引用 | [Context](architecture/CONTEXT.md)、[Search](architecture/SEARCH.md) | M3 |
| F06 | 用户选择 Markdown 文件导入快照、版本化 Source / Chunk、本地搜索与来源查看 | [知识产品规范](product/MEMORY_AND_KNOWLEDGE.md)、[知识设计](architecture/MEMORY_AND_KNOWLEDGE.md) | M4 |
| F07 | 文件授权、Workspace / 对象发送策略、来源继承、数据清理及审计正文保留 | [隐私产品规范](product/DATA_AND_PRIVACY.md)、[平台与安全](architecture/PLATFORM_AND_SECURITY.md) | M1–M5，相关路径开放前完成 |
| F08 | 数据库与 Blob 一致备份、恢复、迁移失败保护、重启后的执行中断状态 | [存储设计](architecture/DOMAIN_AND_STORAGE.md) | M1 初步验证，M5 完整验收 |
| F09 | Token 与估算费用、后台预算 / 暂停、错误可行动、键盘操作与基础可访问性 | [Agent 产品规范](product/AGENT_AND_CONTEXT.md)、[质量标准](engineering/QUALITY.md) | M1–M5 |

### 2.2 首版工具范围

所有工具经 Guarded Pipeline 调度；授权由宿主与 Use Case 校验，模型不能自行授予权限。

| 工具 | 输入 / 输出范围 | 副作用与阶段 |
|---|---|---|
| `memory.search` | query、受限数量与过滤；返回当前 Scope 内可发送的有界结果及引用 | 只读；M3 |
| `memory.get` | Memory ID；返回通过 Scope / Privacy 校验的指定版本正文与来源 | 只读；M3 |
| `memory.remember` | 当前用户原文引用、内容、主体和 Scope；返回已提交 Memory 或明确失败 | 内部写入；明确保存无需额外确认，M3 |
| `memory.retract` | Exact current memory ID/revision and current-user quote; archives without a replacement | Internal write; clear withdrawal, M3 |
| `knowledge.search` | query 与 Source 过滤；返回有界 Chunk 预览和证据句柄 | 只读；M4 |
| `source.open` | Source ID / version；返回元数据、标题和有界目录 / 预览 | 只读；M4 |
| `source.read_chunk` | Chunk ID；返回已授权版本正文与定位 | 只读；M4 |

M2 使用 Fake Tool 验证完整管线，测试工具不进入发布注册表。Memory 编辑、遗忘、候选批准与 Source 导入由明确 UI 操作完成；首版不开放通用 `memory.update`、任意数据库查询或文件写入工具。检索普通默认只使用 Active Memory；候选审核通过 UI 完成。

### 2.3 最小界面

| 区域 | 首版必需内容 |
|---|---|
| Sidebar | Inbox、Workspace、Settings；Memory 管理界面已实现。Knowledge 与 Tasks 仍为待实现入口 |
| Conversation | 消息、发送 / 取消 / 重试、模型和执行状态、历史记忆状态提示、引用入口 |
| Workspace | 名称、项目背景、发送策略；不建设层级 Workspace |
| Memory | 当前／历史、范围与搜索、排序分页、证据和修订详情、手动本地记忆、编辑、替代、归档、遗忘及正文清理占位；不提供自动候选收件箱 |
| Knowledge | 管理界面仍待实现；底层检索和对话引用保留 |
| Inspector | 实际 Context、有效来源、被省略原因、Step / Tool / 错误、Usage |
| Settings | Provider / 用途路线、自动记忆、隐私、备份 / 恢复 / 清理 |

高级 Home / Today、Graph、Timeline 聚合、专用 Note 编辑器、独立 Artifact 工作台不在 v0.1。第一版只建立当前能力需要的导航和数据模型。

## 3. 开发里程碑与依赖

```text
M0 工程与最小可靠基础
  ↓
M1 可恢复的 BYOK 对话
  ↓
M2 最小工具循环与请求审计
  ↓
M3 可纠正记忆与跨对话连续性
  ↓
M4 Markdown 资料与 Agent 检索
  ↓
M5 完整数据恢复、质量评估与 v0.1 交付
  ↓
M6 Task / Reminder（v0.2）
```

每个里程碑补该能力的失败与边界 Fixture，再实现最小纵向路径。M0 不预建整套产品 Schema、所有 Port、图谱、同步、通知或财务模块。以下定义交付与退出条件；实际证据见 [实施与验收记录](engineering/IMPLEMENTATION_STATUS.md)。

### M0：工程与最小可靠基础

**前置：** 文档职责清楚，已确认平台和首版范围，已审阅当前约束。

**交付：** MiraMac Host、MiraKit 的 Core / Data / Providers 三个 Target、依赖锁、首个 Migration、Clock / ID / Fake Provider 测试替身、结构化错误和资料库路径、基础 CI。

**退出条件：**

1. 最低目标系统可编译；Core 不导入 SwiftUI、GRDB 或平台实现。
2. 临时资料库可创建、关闭重开，Migration 失败保留旧数据；生产目录与测试目录隔离。
3. 验证实际 App 链接的 SQLite / FTS5，记录最低系统的搜索能力验证任务。
4. 合成 Fixture 能通过 Fake Provider 产生一次可追踪请求，普通日志不含凭据或正文。

**不做：** 为未来字段提前建表、全套页面或所有 Provider 参数。

### M1：可恢复的 BYOK 对话

**依赖：** M0。

**交付：** Provider Settings、两类协议、标准化 Connection / ModelDescriptor / route preset / purpose binding 配置、Workspace / Inbox、文本对话、流式 Draft、取消 / 最后失败回合重试、Message 持久化、最小数据备份恢复与模型用量。

当前实现按用途和作用域解析路线（显式选择、Conversation、Workspace、Global），在排队及发送前校验能力和 Workspace 连接策略，并为执行保存不可变路线快照。真实 Provider、Keychain 和宿主平台验收仍待完成。

**退出条件：**

1. 同一套 Adapter Fixture 覆盖正常流、拆包、错误、输出上限、取消和 Usage 缺失。
2. 手工 Model ID 可保存；窗口 / 能力未知时受影响用途有明确提示，不能在数据发送后才发现配置缺失。
3. 用户消息与 queued Execution 原子提交；双窗口重复发送、断网和关闭 UI 不造成重复消息或幽灵执行。
4. 崩溃恢复到已持久化 Draft 边界，旧失败回复不污染重试的成功历史。
5. 基础资料库可导出并恢复到隔离目录；Provider 凭据不会进入备份。

**阶段使用限制：** 先用合成和可丢弃内容验证；完整长期资料投入使用要经过 M5。

### M2：最小工具循环与请求审计

**依赖：** M1。

**交付：** Turn / Step / Attempt、Guarded Pipeline、ModelOutput、完整 Tool Call / Result 交换、ContextBuilder、每 Attempt Snapshot、最小 Inspector、执行资源限额。

**退出条件：**

1. Fake Tool 覆盖两步工具调用、多个并行安全工具、独占屏障、非法参数、拒绝、超时和未调度取消。
2. 每个工具调用都有唯一终止结果，保持模型顺序；当前用户输入恰好注入一次。
3. 同一 Turn 内能继续使用工具结果；下一 Turn 不遗留临时检索，也没有孤立工具结果协议。
4. 路线、能力和 Token 预算在构建前已确定；策略收紧后未发送请求必须重建。
5. Inspector 能展示实际请求、内容版本、来源与省略原因；超预算行为明确，尚无 Compact 时引导开启新对话。

### M3：可纠正记忆与连续性

当前工程证据：[手动记忆](engineering/MEMORY_VERIFICATION.md) · [自动记忆](engineering/AUTOMATIC_MEMORY_VERIFICATION.md)。质量门槛仍为独立验收项。

**依赖：** M2。

**交付：** Memory、Evidence、ExtractionDecision、LocalJob、候选审核、Revision / 最小 replaces、抑制与清理、预取、记忆工具和 UI。

**退出条件：**

1. 明确保存事务成功才返回“已记住”；后台自动提取未完成时不伪装已保存。
2. 新 Conversation 能召回相关 Memory 并点击原始证据；Inbox 与 Workspace 隔离正确。
3. Assistant 建议、引用、假设、敏感自动捕获与冲突按策略处理；不将模型自报置信度当作唯一校验。
4. 用户撤销 / 拒绝 / 遗忘后，同源重试、Job 重启、重建与提取器升级不复活内容。
5. Memory 含义变化保留已确认替代；删除新记忆不自动恢复旧认知；并发写入不产生重复 Active。
6. 所有记忆工具和自动提取遵守来源、Scope、Privacy 与预算；完成 [记忆质量门槛](engineering/QUALITY.md#quality-gates)。

**裁剪：** enriches / confirms / challenges 高级发现、通用 Entity 归并、LLM Working Memory 暂缓；保留模型扩展方向，不提前做完整关系编辑器。

Working Memory 只组合用户固定项与当前 Workspace 的有效决定；尚未实现的任务 / 日程贡献为空，不为填满上下文制造摘要或提前实现后续领域。

### M4：Markdown 资料与 Agent 检索

当前工程证据：[Markdown 资料与备份验收](engineering/KNOWLEDGE_VERIFICATION.md)。原生交互与规模性能仍分别记录。

**依赖：** M3。

**交付：** 显式文件选择、托管 Blob、Source Version / Chunk、Markdown 解析、中文 / 英文 / 代码搜索、Source 工具与有效引用、文件发送策略。

**退出条件：**

1. 同一文件重复导入、同名不同文件、显式更新资料、解析失败、超限与坏编码有确定结果。
2. 修改原文件不静默改变已导入快照；重新导入新版本不使旧证据指向新正文。
3. 两字中文、三字中文、中英混合、类型名和路径按 Search Fixture 正确检索；扫描超限会披露结果不完整。
4. Agent 能 search → open / readChunk → 引用回答，拒绝猜测的跨 Scope ID 与无效引用。
5. 未获发送授权的资料不会通过片段、摘要或工具结果进入远程请求；Markdown 内容不自动发起网络请求。
6. Blob 安装、数据库提交、引用扫描与 GC 故障注入不丢失已有规范数据。

**裁剪：** PDF、OCR、网页抓取、目录实时监听、外部 Vault 双向同步、向量检索和图谱暂缓。

### M5：v0.1 质量与交付

当前工程证据：[M5 本机验收](engineering/M5_VERIFICATION.md) · [本机打包流程](engineering/LOCAL_DELIVERY.md)。

**依赖：** M1–M4。

**交付：** 完整备份 / 恢复 / 清理流程、两类真实 Provider 验证记录、性能与记忆评估、可访问性检查、本机安装验证；对外下载版另完成签名与公证。

**退出条件：**

1. [质量标准](engineering/QUALITY.md#quality-gates) 全部适用门槛通过；确定性检查与真实模型质量分别记录。
2. 包含两 Workspace、Global Memory、候选 / 抑制、多个资料版本和历史执行的数据集，备份后能在空目录恢复并保持 ID / 引用 / 状态。
3. 无效备份、缺失 Blob、更新的 Schema、恢复中断和磁盘写入失败不会覆盖唯一有效资料库。
4. 恢复不会自动调用模型、重新授权文件或重放副作用；清理过的内容不从缓存恢复。
5. 验证 macOS 15 与当前 macOS；每个支持 CPU 架构必须有明确测试证据，未测试平台不能标记已支持。
6. 使用合成数据进行真实 Provider 探测，再连续 7 天实际使用；新增严重问题修复后复跑受影响检查。
7. 下载产物的安装、更新、当前资料库恢复、签名 / 公证以及卸载时数据保留说明完整。开发阶段旧格式明确拒绝并保留，不做迁移兼容。没有签名条件时只能标记本机开发可用，不能声称对外交付完成。

### M6：Task / Reminder（v0.2）

**依赖：** 已有对话、执行、来源、存储与恢复能力。用户已授权在需人工配合的 v0.1 验收项暂缓时继续实现 M6；该授权不等于发布质量门槛通过。

**当前实现：** 保留任务用例、独立候选、`task.list` / `task.change`、原消息时间与时区、一次性本地通知及恢复后暂停提醒。原任务列表、编辑、状态操作、候选审核和权限恢复管理界面已移除，替代界面待实现。产品范围见 [Records](product/RECORDS.md)，技术契约见 [Tasks and reminders](architecture/TASKS_AND_REMINDERS.md)。

**交付：** 明确命令创建 / 修改任务和一次性提醒、RecordProposal、Revision + Evidence、本地通知、完成 / 取消与失败状态。

**退出条件：**

1. 相对时间固定在原消息的时间和时区，晚一天确认不漂移；夏令时重复 / 不存在时间需明确选择。
2. 提醒记录提交与操作系统调度状态分开显示；未获权限时保留记录并提供恢复入口。
3. 稳定通知 ID 支持更新 / 取消，重试不重复排程；应用退出后的系统通知行为在真机验证。
4. 记录变更可追溯，恢复备份不自动重新安排全部提醒。

Apple Calendar / Reminders 单向发布作为其后的独立增量：实现 NotificationDelivery / ExternalProjectionLink 的切换、失败、状态不确定与去重核对后再开放；不阻塞本地 Task / Reminder 先使用。CalendarEvent、EventRecord 与财务范围分别按真实需求继续拆分。

Ordered multiround conversation activity now preserves reasoning, intermediate text, tool arguments and full results across reopening. Running process rows avoid a duplicate turn header, reasoning expansion hides its summary, and tools use a shared Input/Output card. Disclosure chevrons follow the text on hover, failed tool triggers use a semantic failure color, and JSON sections stay on a compact horizontally scrollable line. Completed process groups include final-round reasoning and keep only final answer text outside. Focused evidence and remaining limits: [multiround process verification](engineering/MULTIROUND_PROCESS_VERIFICATION.md).

Conversation model selection now initializes the first active pool model as the default, supports fixed or follow-last defaults, and exposes a provider-grouped picker with the actual model name. Focused persistence, settings, localization, and native UI evidence: [model selection verification](engineering/MODEL_SELECTION_VERIFICATION.md).

The composer model selector now uses a compact native grouped menu. Provider information respects saved capability declarations and displays dated official DeepSeek peak/off-peak price ranges; [focused model information evidence](engineering/MODEL_INFORMATION_VERIFICATION.md) records source verification and native checks.

The first composer focus no longer initializes the macOS OTP AutoFill panel. The documented app configuration now requires explicit one-time-code fields; [focused first-focus evidence](engineering/COMPOSER_FIRST_FOCUS_VERIFICATION.md) records the reproduced system window and correction.

## 4. 明确后置项及启动条件

| 后置能力 | 重新启动的条件 |
|---|---|
| Compact | 实际长对话频繁触达窗口，已有 Context / Source 版本与回归集 |
| Responses / 其他 Provider 协议 | 用户实际选择需要该协议的模型，补齐独立 Adapter Fixture |
| PDF / OCR / 多模态 | Markdown 路径可靠且出现真实导入需求，明确本地解析与远程处理边界 |
| 向量检索 | FTS 与别名检索在评估集中仍存在可量化语义召回缺口 |
| Graph / Entity 高级关系 / Synthesis | 真实使用证实探索或综合价值，不以模块预留作为建设理由 |
| Apple 单向发布 | 本地提醒交付可靠，已准备 EventKit 权限、失败核对与通知切换测试 |
| iOS / 同步 / Handoff | macOS 核心稳定，单独确定数据共享范围与冲突策略 |
| Shell / 自动化 / Helper / 第三方工具 | 明确用户场景、分发能力矩阵、权限和取消 / 副作用审计后重新设计 |
| 应用级加密 / 安全擦除 | 明确威胁模型、密钥恢复和备份策略后单独设计，不能仅增加布尔字段 |

## 5. 开发前条件与发布前条件

**目前进度：** 已实现 M1 的可恢复对话、Markdown 与标准化用途级路线配置，以及 M2 的多步工具交换、逐次审计、权限检查和限额。M3 已注册三个实际记忆工具，并保留可纠正状态、来源抑制、派生内容清理与历史引用；确定性证据见 [记忆验收记录](engineering/MEMORY_VERIFICATION.md)。自动记忆保留独立配置与后台任务；M4 保留资料工具与完整文件备份；M5 已完成可独立执行的规模性能、恢复与本机开发包验证。自然记忆与资料预取、M6 任务 / 一次性提醒底层实现保留。Memory 管理界面已重建；Knowledge 与 Tasks 界面仍待设计与实现，历史界面验收不视为当前版本的验收。Memory 管理的原生运行与质量边界见 [Memory management verification](engineering/MEMORY_MANAGEMENT_VERIFICATION.md)。真实 Provider 的广泛质量验证、Keychain 故障演练及完整平台交互验收仍待补；M3–M6 尚未完成全部发布验收。

**实施时填写的证据：** 实际选用的模型 ID / 端点及能力验证结果、Package.resolved、最低系统与各 CPU 的验证环境。无需在文档中写入密钥。

**发布时满足的条件：** 所有适用质量门槛、备份恢复演练、真实使用记录，以及对外下载安装所需签名身份与公证。环境或凭据暂不可用时，标记对应验证未完成，不让它阻塞无依赖的 M0 工作，也不将其误写成已通过。

完成每个里程碑时更新本文件的状态和证据链接；规范变更写回唯一负责文档，评审记录只保留理由和定位。

Code blocks now use a shared height limit with native two-axis scrolling and final-line scrollbar clearance. Focused rendering and native evidence is recorded in [code block scrolling verification](engineering/CODE_BLOCK_SCROLLING_VERIFICATION.md).


### Local memory integration — 2026-09-16

The `codex/memory-embedding-prototype` branch now integrates the pinned Qwen3 0.6B 4-bit MLX adapter, revision-bound SQLite vectors, semantic/lexical recall, bounded communication/language profile, always-automatic capture using the conversation model, confirmation-free explicit saves and v3 batched model extraction. Automatic extraction skips ambiguous items instead of creating a review inbox. Archive/recovery/privacy paths include derived-index invalidation and batch lineage. See [implementation evidence](engineering/LOCAL_MEMORY_IMPLEMENTATION.md) for exact passing checks, the open native window-animation failure, unverified minimum-size UI, and remaining quality gates. The removed management screens remain deferred; this does not close M3 release acceptance. A follow-up removes capture mode and dedicated extraction-model setup, freezes the actual completed conversation route, and reuses bounded request prefixes with provider tool calls disabled. The follow-up passed 173 focused package tests, native settings tests and the host target; live cache-hit savings and minimum-window verification remain open in the same evidence record.
