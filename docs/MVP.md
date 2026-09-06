# Mira MVP 范围与实施计划

**版本：** v1.0  
**日期：** 2026-09-06

**状态：** M0 工程基础已实现；M1 对话、Markdown 与标准化配置路由已实现，真实端点与平台验收待补；M2 工具循环基础已实现并进行合成验收。M3 手动记忆、纠正、工具、引用与默认关闭的自动提取已实现并通过确定性测试；真实模型质量与完整原生交互验收待补。M4 资料与完整备份已实现，M5 规模查询、大资料库恢复及本机开发包验证已通过。M3–M5 的真实模型、原生交互及分发门槛仍未完成，M6 未开始。

服务商接入流程已按“配置并激活服务商 → 选择服务商模型 → 模型池 → 选择模型”更新，当前验收见 [模型池验收记录](engineering/PROVIDER_POOL_VERIFICATION.md)。

本文只决定做什么、按什么依赖顺序做、完成到什么程度可以进入下一阶段。产品行为由 [PRD 与领域产品规范](PRD.md) 定义，技术契约由 [架构总览及领域设计](ARCHITECTURE.md) 定义，测试数值门槛由 [质量标准](engineering/QUALITY.md#quality-gates) 统一维护。

## 1. 已确认的范围

用户已确认：

- 首个 MVP 聚焦对话、可纠正记忆、Markdown 文件检索和最小 Agent 工具循环。
- Task / Reminder 在紧接着的下一版本推进。
- 首批接入 OpenAI 兼容接口与 Anthropic Messages；首版 OpenAI 兼容范围明确为 Chat Completions。
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
| F04 | 手动保存、明确记住、自动捕获开关、候选批准 / 拒绝、来源与 Scope、修改 / 替代 / 撤销 / 遗忘 | [记忆产品规范](product/MEMORY_AND_KNOWLEDGE.md)、[记忆设计](architecture/MEMORY_AND_KNOWLEDGE.md) | M3 |
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
| `memory.remember` | 当前用户原文引用、内容、主体和 Scope；返回已提交 Memory 或明确失败 / 待确认 | 内部写入；明确用户意图或有效确认，M3 |
| `knowledge.search` | query 与 Source 过滤；返回有界 Chunk 预览和证据句柄 | 只读；M4 |
| `source.open` | Source ID / version；返回元数据、标题和有界目录 / 预览 | 只读；M4 |
| `source.readChunk` | Chunk ID；返回已授权版本正文与定位 | 只读；M4 |

M2 使用 Fake Tool 验证完整管线，测试工具不进入发布注册表。Memory 编辑、遗忘、候选批准与 Source 导入由明确 UI 操作完成；首版不开放通用 `memory.update`、任意数据库查询或文件写入工具。检索普通默认只使用 Active Memory；候选审核通过 UI 完成。

### 2.3 最小界面

| 区域 | 首版必需内容 |
|---|---|
| Sidebar | Inbox、Workspace、Memories、Knowledge、Settings；不显示尚未实现的占位功能入口 |
| Conversation | 消息、发送 / 取消 / 重试、模型和执行状态、记忆处理反馈、引用入口 |
| Workspace | 名称、项目背景、发送策略；不建设层级 Workspace |
| Memory | Active / Candidate / Archived 筛选、来源、Scope、编辑与删除动作 |
| Knowledge | Markdown 导入、进度 / 失败、Source 列表、版本与片段查看、搜索 |
| Inspector | 实际 Context、有效来源、被省略原因、Step / Tool / 错误、Usage |
| Settings | Provider / 用途路线、自动记忆与预算、隐私、备份 / 恢复 / 清理 |

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

**依赖：** v0.1 数据和执行质量门槛通过。

**交付：** 明确命令创建 / 修改任务和一次性提醒、RecordProposal、Revision + Evidence、本地通知、完成 / 取消与失败状态。

**退出条件：**

1. 相对时间固定在原消息的时间和时区，晚一天确认不漂移；夏令时重复 / 不存在时间需明确选择。
2. 提醒记录提交与操作系统调度状态分开显示；未获权限时保留记录并提供恢复入口。
3. 稳定通知 ID 支持更新 / 取消，重试不重复排程；应用退出后的系统通知行为在真机验证。
4. 记录变更可追溯，恢复备份不自动重新安排全部提醒。

Apple Calendar / Reminders 单向发布作为其后的独立增量：实现 NotificationDelivery / ExternalProjectionLink 的切换、失败、状态不确定与去重核对后再开放；不阻塞本地 Task / Reminder 先使用。CalendarEvent、EventRecord 与财务范围分别按真实需求继续拆分。

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

**目前进度：** 已实现 M1 的可恢复对话、Markdown 与标准化用途级路线配置，以及 M2 的多步工具交换、逐次审计、权限检查和限额。M3 已注册三个实际记忆工具，并实现手动管理、可纠正状态、来源抑制、派生内容清理与历史引用；确定性证据见 [记忆验收记录](engineering/MEMORY_VERIFICATION.md)。自动记忆已有独立配置、任务、预算与审核实现，并通过确定性验收；M4 资料工具、完整文件备份与界面已实现并通过确定性测试和 CI；M5 已完成可独立执行的规模性能、恢复与本机开发包验证。真实 Provider、Keychain 故障演练及完整平台交互验收仍待补；M3–M5 尚未完成里程碑验收。

**实施时填写的证据：** 实际选用的模型 ID / 端点及能力验证结果、Package.resolved、最低系统与各 CPU 的验证环境。无需在文档中写入密钥。

**发布时满足的条件：** 所有适用质量门槛、备份恢复演练、真实使用记录，以及对外下载安装所需签名身份与公证。环境或凭据暂不可用时，标记对应验证未完成，不让它阻塞无依赖的 M0 工作，也不将其误写成已通过。

完成每个里程碑时更新本文件的状态和证据链接；规范变更写回唯一负责文档，评审记录只保留理由和定位。
