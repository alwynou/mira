# Mira 产品需求文档（PRD）

**文档版本：** v1.1  
**状态：** 当前产品基线（Current Product Baseline，可通过真实使用持续修订）  
**产品代号：** Mira  
**产品类型：** 面向个人的本地优先 AI 助理、Agent 工作空间与个人记忆知识系统  
**首发平台：** macOS  
**后续平台：** iOS  
**客户端技术基线：** 原生 Swift  
**模型接入方式：** BYOK（Bring Your Own Key，用户自带模型访问能力）与多 Provider（模型服务商或兼容端点）  
**服务端策略：** 不建设 Mira 自有业务后端；本地数据库与本地文件是规范事实源  
**最后更新：** 2026-09-04

---

# 0. 文档定位与维护规则

本文件回答以下产品问题：

- Mira 是什么，以及不是什么；
- 首要用户是谁；
- Mira 需要解决哪些长期问题；
- Conversation（对话）、Memory（记忆）、Knowledge（知识）、Structured Data（结构化数据）与 Agent（智能体）如何形成一个产品；
- 哪些边界属于产品身份，不能因为实现方便而被破坏；
- 哪些行为只是当前默认，允许在真实使用和 Eval（评估）后调整；
- 哪些能力仍属于产品假设，不应提前冻结成复杂基础设施。

本文件不负责：

- Swift 类型、数据库表和索引字段；
- Agent Runtime（智能体运行时）的精确状态机；
- Provider 的 Wire Protocol（线协议）；
- 页面像素级设计；
- 发布排期和人力估算；
- 某个版本的完整功能清单。

上述内容分别进入：

```text
ARCHITECTURE.md
具体技术架构与实现约束

MVP.md（后续）
第一条纵向用户闭环、验收标准与功能裁剪

ADR（Architecture Decision Record，架构决策记录）
关键取舍的背景、备选方案与变化原因
```

## 0.1 规则级别

为避免把尚未验证的假设写成不可改变的“最终规则”，本文使用三种级别。

### 产品不变量（Product Invariant）

构成 Mira 产品身份和信任边界的规则。

例如：

- Local-first（本地优先）；
- 无 Mira 自建业务后端；
- BYOK；
- 原始记录与派生知识分开；
- 用户可以查看和纠正长期记忆；
- 远程模型不能在用户不知情时获得本地全部数据。

除非产品方向发生根本变化，否则实现不得采用相反语义。

### 基线默认（Baseline Default）

当前认为最合理的默认行为，但允许通过真实使用、成本数据和 Eval 调整。

例如：

- 自动记忆的分级写入策略；
- 每轮预取多少条 Memory；
- Compact（上下文压缩）使用哪条模型路线；
- Working Memory（工作记忆）的生成方式；
- Apple 系统 App 的发布体验。

### 产品假设（Product Hypothesis）

可能有价值，但必须通过真实使用证明的方向。

例如：

- 用户是否经常使用 Graph View（知识图谱视图）；
- 是否需要独立的 Knowledge Synthesis（知识综合）对象；
- 自动关系发现是否能持续带来价值；
- Working Memory 是否需要每次通过 LLM（大语言模型）生成；
- 轻量财务记录是否会成为高频能力。

产品假设可以出现在完整 PRD 中，但不能要求 MVP 预先建设其全部基础设施。

## 0.2 维护规则

1. 项目只保留 `PRD.md` 与 `ARCHITECTURE.md` 两个主入口；历史由 Git 与 ADR 保存。
2. 新结论直接修改主文档，不创建 `v0.x`、`backup` 等并行版本。
3. PRD 只保存产品语义；字段、状态机、表结构只在架构文档出现一次。
4. 参考设计标注说明“借鉴什么”和“不照搬什么”，不把外部项目当作 Mira 的规范依赖。
5. MVP 不需要等待所有长期能力设计完毕；在核心不变量明确后，应尽快拆出第一条纵向闭环，并用使用结果修订基线默认与产品假设。
6. 英文缩写与专业术语首次出现时附中文说明。

---

# 1. 产品定义

Mira 是一个面向个人长期使用的、本地优先的 AI 系统。

它同时承担三种角色：

```text
Personal AI Assistant
个人 AI 助理

Personal Agent Workspace
个人 Agent 工作空间

Personal Memory & Knowledge System
个人记忆与知识系统
```

Mira 不只是聊天窗口。

聊天是最自然的交互入口之一，但 Mira 真正需要长期维护的是：

- 用户长期稳定的偏好、事实、目标和习惯；
- 项目中的决定、约束、计划、流程、经验和开放问题；
- 用户创建或导入的文档、笔记、文件和资料；
- 任务、提醒、日程、发生过的事件和轻量财务记录；
- Agent 的执行过程、工具结果和重要产物；
- 当前正在处理的事情和需要持续关注的上下文；
- 所有重要认知的来源、时间、适用范围和变化过程。

Mira 的核心产品模型不是：

> 用户拥有很多 AI 聊天记录。

而是：

> 用户拥有一个持续存在、能够行动、能够沉淀记忆、能够组织知识，并允许用户随时检查和修正的 Mira。

---

# 2. 第一目标用户

Mira 首先服务单个用户本人。

第一目标用户通常具备以下需求中的多项：

- 长期与 AI 讨论工作、项目、学习或生活；
- 经常需要重复解释自己的背景、偏好和项目状态；
- 同时使用多个模型或不同模型服务商；
- 希望 AI 能读取本地文件并调用授权工具；
- 希望重要结论不再被埋在聊天历史中；
- 希望资料、笔记、对话和记忆可以彼此关联；
- 希望自己的核心数据保存在本地并可导出；
- 希望知道 AI 为什么记住某件事、为什么调用某个工具、为什么给出某个结论。

Mira 当前不优先服务：

- 企业团队协作；
- 多租户 SaaS（Software as a Service，软件即服务）；
- 组织、成员、角色和审批体系；
- 面向开发者托管大量 Agent 的云平台；
- 完全不愿配置任何模型服务商的零配置用户；
- 需要 Mira 统一承担模型费用的用户。

---

# 3. 用户核心问题

## 3.1 AI 没有连续认知

用户经常需要重新解释：

- 自己是谁；
- 当前在做什么；
- 项目已经做过哪些决定；
- 哪些方案已经否决；
- 哪些表达和工作偏好需要长期遵守。

## 3.2 重要结论被埋在聊天历史中

Conversation 保留完整讨论过程，但不适合作为唯一长期知识载体：

- 内容过长；
- 中间尝试很多；
- 重要结论散落；
- 新旧观点会冲突；
- 几个月后难以重新找到。

## 3.3 个人资料彼此割裂

用户的知识可能同时存在于：

- 本地 Markdown；
- PDF、图片和其他文件；
- 代码仓库；
- 对话历史；
- 日历、提醒和任务；
- 不同 AI 工具。

Mira 需要在不抹平来源边界的前提下，让它们可以共同搜索、引用和关联。

## 3.4 Agent 能执行，但难以信任

普通 Agent 产品经常不能清楚解释：

- 本轮使用了哪些记忆和资料；
- 为什么选择这些上下文；
- 调用了什么工具；
- 哪一步失败；
- 是否发生写入或外部副作用；
- 是否可以取消、重试、撤销或恢复。

## 3.5 本地数据与远程模型之间缺少明确边界

用户希望使用强大的远程模型，但不希望：

- 所有资料默认上传；
- 密钥由未知服务器持有；
- 本地能力依赖某个中心服务持续在线；
- 无法导出自己的记忆和知识；
- 无法删除或纠正 AI 的长期认知。

---

# 4. 产品愿景

Mira 最终应成为用户长期使用的个人 AI 工作空间与个人认知基础设施。

它能够：

1. 理解当前输入与用户所处的项目上下文；
2. 在不同 Conversation 中延续对用户和项目的认识；
3. 从对话和资料中沉淀值得长期保留的 Memory；
4. 从原始来源中重新寻找证据，而不是只相信旧摘要；
5. 让文档、笔记、Memory、实体和关系形成可探索的知识网络；
6. 识别知识的补充、支持、冲突和替代；
7. 调用用户授权的本地和平台工具执行任务；
8. 从自然语言中创建任务、提醒、日程、事件和财务记录；
9. 根据当前问题构建精简、可解释的模型上下文；
10. 允许用户查看、编辑、否定、归档和删除长期知识；
11. 允许用户追溯重要认知、结构化记录和回答的来源；
12. 在未来通过不同 Apple 设备访问同一套长期知识与状态，同时保留各平台独立的原生体验。

---

# 5. 产品不变量

## 5.1 Personal First（个人优先）

Mira 默认只有一个数据所有者，不提前引入团队、组织、管理员或多租户模型。

## 5.2 Local First（本地优先）

核心数据首先写入本地数据库或本地文件，并可在离线状态下查看、编辑和搜索。

## 5.3 No Mira Backend（无 Mira 自建业务后端）

Mira 不建设用于以下目的的自有业务服务器：

- 代理模型请求；
- 保存用户 Conversation；
- 保存用户 Memory 和知识库；
- 执行核心 Agent 任务；
- 作为本地应用启动和查询数据的前置条件。

未来同步可以使用 Apple 提供的能力或用户控制的其他传输方式，但本地应用不能退化成云端客户端。

## 5.4 BYOK（用户自带模型访问能力）

远程模型由用户配置自己的 Provider、凭据、模型和端点。Mira 不提供开发者统一密钥，也不替用户承担推理费用。

## 5.5 Mac First（优先 macOS）

macOS 是首个完整宿主环境，优先承载：

- 多 Conversation；
- 文件和项目工作流；
- Agent 执行；
- Memory 与知识整理；
- Context 与 Execution Inspector；
- 较长时间的本地任务。

## 5.6 Native Experience（平台原生体验）

macOS 与未来 iOS 可以使用不同的信息架构和 UI。共享的是核心逻辑和数据语义，而不是界面布局。

## 5.7 Raw 与 Derived 分离

```text
Raw / Canonical
原始或规范记录

Conversation
Message
Execution
Tool Result
Knowledge Source
Structured Record

        ↓ 提取、整理、索引

Derived
派生知识或投影

Memory
Compact
Working Memory
Entity Mention
Relation Proposal
Search Index
Graph Projection
```

派生内容不能静默删除或改写原始来源。

## 5.8 User Control（用户掌控）

用户必须能够：

- 查看和编辑 Memory；
- 撤销自动记忆；
- 处理候选和冲突；
- 查看来源；
- 控制数据是否允许发送给远程 Provider；
- 控制工具权限；
- 导出数据；
- 删除或遗忘内容。

## 5.9 Explainable Context（上下文可解释）

用户应能够检查本轮模型看到了哪些长期记忆、项目规则、资料片段和工具定义。

可审计不等于所有内容永久留在后续上下文中。

## 5.10 Native Swift（原生 Swift）

共享 Core、Agent Runtime、Context、Memory、Knowledge、Provider 适配和本地数据层统一使用 Swift；Apple 专属能力由各平台 Host / Adapter 实现。

## 5.11 Simple by Default（默认简单）

完整产品保留扩展空间，但不为尚未出现的需求提前建设：

- 动态二进制插件系统；
- 通用 DAG（Directed Acyclic Graph，有向无环图）工作流语言；
- 多套可写事实源；
- 企业权限体系；
- 专用图数据库；
- 当前不存在的同步 Runtime；
- 同一概念的多层抽象框架。

---

# 6. 产品核心闭环

Mira 的核心闭环是：

```text
Capture
捕获对话、文件、事件和用户操作
      ↓
Understand
理解当前问题、项目和用户状态
      ↓
Recall
找回少量真正相关的长期知识
      ↓
Act
调用模型和授权工具完成任务
      ↓
Preserve
保存原始交流、执行过程和结果
      ↓
Distill
沉淀值得长期保留的 Memory 或结构化记录
      ↓
Connect
连接来源、笔记、实体与相关知识
      ↓
Correct
用户可以撤销、修正、替代和遗忘
      ↓
Reuse
在未来 Conversation 中再次正确使用
```

Mira 最先需要验证的核心价值不是“图谱有多复杂”，而是：

> 一条值得记住的内容，能否被正确提取、在未来恰当召回、展示来源，并在错误时被低成本纠正。

---

# 7. 产品信息架构

macOS 的长期信息架构包括：

```text
Mira
├── Home / Today
├── Inbox
├── Workspaces
│   ├── Project Context
│   ├── Working Memory
│   ├── Conversations
│   ├── Project Memory
│   ├── Knowledge
│   └── Artifacts
├── Memories
├── Knowledge
├── Schedule & Records
│   ├── Calendar
│   ├── Reminders
│   ├── Tasks
│   ├── Events
│   └── Finance
├── Search
├── Timeline / Activity
└── Settings
```

并非每个入口都必须在第一个 MVP 中出现，但领域边界不能彼此混用。

## 7.1 Home / Today

用于展示当下最需要关注的少量内容：

- 未完成任务；
- 即将到来的日程和提醒；
- 当前活跃 Workspace；
- 最近自动记住且可撤销的内容；
- 需要审核的少量高风险候选；
- 失败或等待用户处理的 Agent 任务。

Home 不是强制启动页。应用默认可以恢复用户上次位置。

## 7.2 Inbox

Inbox 承载：

- 未归类 Conversation；
- Quick Capture（快速捕获）；
- 待处理导入；
- 尚未决定 Workspace 的内容。

## 7.3 Workspace

Workspace 表示一个长期项目、主题或生活领域。

基线默认采用单层 Workspace，不建设层级继承。跨 Workspace 组织通过标签、链接、实体和搜索完成。

---

# 8. Conversation 与 Workspace

## 8.1 Conversation

Conversation 表示一次相对连续的话题或任务上下文。

它是：

- 消息组织边界；
- Agent Execution 的关联边界；
- Compact 的主要边界；
- 上下文连续性的主要可见载体。

它不是：

- 长期 Memory 本身；
- Workspace 的全部知识；
- 结构化任务或日程的替代品。

## 8.2 Workspace

Workspace 可以拥有：

- 多个 Conversation；
- Project Context；
- Project Memory；
- Knowledge Source 与 Note；
- Artifact；
- 项目相关 Task、CalendarEvent 和 FinancialTransaction。

Conversation 可以没有 Workspace，默认归入 Inbox。

## 8.3 Conversation 与长期连续性

新的 Conversation 不需要加载另一个 Conversation 的全部历史。

它可以通过：

- Project Context；
- Working Memory；
- 相关 Global Memory；
- 相关 Project Memory；
- Agent 主动检索原始来源；

恢复必要的长期连续性。

---

# 9. Memory System（记忆系统）

## 9.1 Memory 的定义

Memory 是一条值得长期保留、可以脱离原始 Conversation 独立理解，并可能在未来再次帮助用户的认知单元。

基线主类型：

```text
fact          事实
preference    偏好
decision      决定
goal          目标
constraint    约束
procedure     流程
learning      经验或学习
context       重要背景
```

类型保持小而稳定；生活领域通过标签、范围和实体表达。

事件、金额、截止时间、完成状态等可操作数据不以 Memory 代替。

## 9.2 Global Memory 与 Project Memory

二者使用同一个 Memory 系统，仅通过 Scope（适用范围）区分。

### Global Memory

描述用户本人跨项目可复用的长期信息，例如：

- 沟通偏好；
- 稳定习惯；
- 长期目标；
- 用户明确要求全局记住的规则。

### Project Memory

描述某个 Workspace 内的长期认知，例如：

- 已确认架构决定；
- 项目约束；
- 关键经验；
- 重要开放问题；
- 当前有效方案。

其他 Workspace 的 Project Memory 默认不进入当前对话。

## 9.3 Memory 的分级产生策略

这是**基线默认**，需要通过真实使用和 Eval 持续调整。

### A. 用户明确要求记住

例如：

> 记住，Mira 不建设自有后端。

处理：

- 校验后直接生效；
- 标记为用户明确意图；
- 提供编辑、来源和删除入口；
- 不再要求用户重复审核。

### B. 用户清晰表达稳定事实、偏好或决定

例如：

> 我不喜欢过度设计。

在满足以下条件时可以自动生效：

- 内容确实由用户表达；
- 不是问句、引用、假设或 Assistant 建议；
- 有长期复用价值；
- 主体和范围明确；
- 不属于敏感或高风险内容；
- 不会静默替代一条已确认的重要 Memory。

Mira 应在对话或 Activity 中轻量提示：

```text
Mira 记住了：
你倾向避免过度设计。

[撤销] [编辑] [查看来源]
```

这类 Memory 可以参与召回，但权威性低于用户明确要求记住的内容。

### C. 推断、敏感、冲突或低置信内容

以下内容进入 Candidate（候选），不参与普通召回：

- Mira 根据多次行为推测的偏好；
- 外部资料中推断出的用户立场；
- 会替代一条已确认 Memory 的新内容；
- 涉及敏感个人信息；
- 主体、时间或范围不明确；
- 提取置信度较低；
- 可能只是当前情绪或短期状态。

Candidate 集中进入审核入口，不应每次打断 Conversation。

## 9.4 Memory 生命周期

用户可见状态：

```text
active
当前有效并可参与召回

candidate
等待审核，不作为普通事实注入

archived
仍保留，默认不参与日常召回

rejected
候选被否定

removed
用户明确删除或遗忘
```

“被替代”“被支持”“被质疑”等语义通过知识关系表达。

## 9.5 Revision 与 Evolution

### Revision（修订）

同一认知的非语义性调整：

- 修正文字；
- 改标题；
- 补标签；
- 增加来源；
- 改善表达但核心含义不变。

### Evolution（演化）

认知本身发生变化：

```text
replaces   新认知替代旧认知
enriches   新认知补充旧认知
confirms   独立信息支持旧认知
challenges 新信息质疑旧认知
```

高影响的 `replaces` 在用户确认前不能让旧 Memory 退出正常召回。

## 9.6 来源与发言归属

Mira 必须区分：

- 用户明确说出的事实或决定；
- Assistant 的建议；
- Mira 的推断；
- Tool Result；
- 外部资料中的观点；
- 多来源形成的总结。

例如：

> Assistant 建议使用 PostgreSQL。

不能自动变成：

> 用户决定使用 PostgreSQL。

## 9.7 时间语义

Memory 需要区分：

- 事情发生的时间；
- Mira 记录的时间；
- 有效开始和结束时间；
- 最后确认时间；
- 时间精度与模糊程度。

“用户目前在新加坡”属于可能过期的状态，不应被当作永久事实。

## 9.8 Memory 的召回体验

普通 Conversation 采用两阶段模式：

```text
有限预取
为普通对话提供自然的“记得”体验

Agent 主动深度检索
处理历史性、全量性、综合性问题
```

预取只带入少量高相关、当前有效、范围匹配的 Memory；没有高相关内容时可以不注入。

当用户询问“我们过去讨论过哪些方案”“找出所有来源”等问题时，Agent 应主动调用 Memory / Knowledge 搜索工具，而不是依赖一次预取猜中所有内容。

用户可以查看：

- 本轮用了哪条 Memory；
- 为什么被召回；
- 适用范围；
- 来源；
- 当前状态；
- 是否被用户明确确认。

> **参考设计标注｜Nowledge Mem**  
> 借鉴其将原始对话与可独立复用的 Memory 分开、保留来源、Working Memory 与知识演化的思路。Mira 不照搬固定审核队列：对清晰的用户陈述采用“自动生效 + 易撤销”，把推断、敏感和冲突内容保留为 Candidate。

---

# 10. Project Context 与 Working Memory

## 10.1 Project Context（项目上下文）

Project Context 是当前 Workspace 中需要长期遵守的权威背景与规则，例如：

- 项目目标；
- 核心约束；
- 术语定义；
- 架构原则；
- 关键资料入口；
- 用户固定指令。

产品规则：

- 由用户维护；
- Mira 可以提出新增、修改或删除建议；
- Mira 不能静默改变；
- 大型文档只作为引用，不应每轮完整塞入 Context；
- 用户当前明确指令可以覆盖本轮行为，但不自动永久修改 Project Context。

## 10.2 Working Memory（工作记忆）

Working Memory 表示当前一段时间最应该关注的有限状态。

基线由两部分组成：

```text
Pinned Items
用户明确固定，系统不得覆盖

Generated / Deterministic Snapshot
由当前任务、近期决定、未完成事项和活跃 Conversation 形成
```

第一版优先使用确定性组合：

- 用户固定项；
- 最近的重要决定；
- 未完成 Task；
- 即将到来的日程；
- 等待处理的执行；
- 当前 Workspace 的明确开放问题。

LLM 生成摘要是可选增强，而不是 Working Memory 成立的前提。

Working Memory 是可重建投影，不是新的事实源。

---

# 11. Knowledge Base（知识库）

## 11.1 Knowledge Source（知识来源）

表示需要整体保留的原始资料，例如：

- Markdown；
- PDF；
- 网页快照；
- 代码文件；
- 图片、音频和视频；
- 导入的 Obsidian 笔记；
- Conversation 或 Tool Result 的可引用内容。

Source 可以被解析成可检索片段，但原文件和来源身份仍被保留。

## 11.2 Knowledge Note（知识笔记）

Knowledge Note 是用户或 Mira 创建的长形式、可编辑 Markdown 内容，例如：

- 架构文档；
- 学习总结；
- 方案比较；
- 项目阶段总结；
- 研究草稿；
- 多来源综合笔记。

Note 默认不是权威项目指令。需要成为项目规则时，用户可以将某一段固定到 Project Context。

Mira 生成的综合内容第一阶段直接作为：

```text
KnowledgeNote
origin = generated
state = draft
附带 Evidence
```

只有当真实使用证明其需要独立更新和生命周期时，才拆出专门的 Synthesis 对象。

## 11.3 Wiki Link 与 Backlink

Knowledge Note 支持：

- `[[Wiki Link]]`；
- Backlink（反向链接）；
- 标签；
- 引用 Memory；
- 引用 Source；
- 引用其他 Note。

链接应解析为稳定对象引用，避免仅靠标题字符串维持关系。

## 11.4 Entity 与 Relation

Entity（实体）用于统一别名、主体和概念，例如：

- 人；
- 项目；
- 产品；
- 技术；
- 组织；
- 地点；
- 概念。

系统可以自动提取 Entity Mention（实体提及），但正式实体创建与合并必须保守。

Relation（关系）分为：

- 确定性结构关系：来源于、属于、生成于、链接到；
- 用户明确建立的关系；
- AI 推断的语义关系。

AI 推断关系默认只是建议或低权重信号，不应静默改变当前事实。

## 11.5 Topic 与 Graph View 的定位

当前产品基线不把 Topic 社区检测作为权威领域对象。

基础组织优先使用：

- Tag；
- Entity；
- Wiki Link；
- Saved Search（保存的搜索）；
- 可重建的聚类。

Graph View 是知识关系的一种可视化和探索方式，不是第二套数据源，也不是 Mira 核心价值成立的前置条件。

它属于需要实际验证的产品假设：

- 用户是否经常打开；
- 是否真的帮助发现关系；
- 是否需要“选中节点继续询问”等深度交互。

## 11.6 Obsidian 互操作

Mira 支持：

- Markdown 正文；
- Wiki Link；
- Backlink；
- YAML Frontmatter（YAML 头信息）；
- Obsidian-compatible Export（兼容 Obsidian 的导出）；
- Markdown 导入。

但 Mira 的规范事实源仍是本地数据库与 Blob Store（文件内容存储）。

外部 Vault（知识库目录）不与 Mira 建立双向实时写入，避免双事实源和冲突合并。

> **参考设计标注｜Obsidian**  
> 借鉴 Markdown、Wiki Link、Backlink 与本地知识网络的编辑心智。Mira 的差异是：Memory 状态、Execution、来源、结构化数据和知识演化使用结构化存储，不强行表达成一组 Markdown 文件。

---

# 12. Agent 与工具执行

## 12.1 Agent 的职责

Agent 可以：

- 调用用户配置的模型；
- 查询 Memory 和 Knowledge；
- 读取当前 Context；
- 调用授权工具；
- 创建或修改结构化数据；
- 产生 Artifact；
- 请求用户确认或完成 UI 操作；
- 保存可追溯的执行过程。

## 12.2 用户可见状态

用户至少能够区分：

```text
准备上下文
等待模型
正在生成
等待工具
等待用户确认
正在执行工具
正在取消
已完成
失败
可重试
```

不能用一个持续旋转的 Loading 表示所有状态。

## 12.3 权限基线

```text
已授权范围内的只读操作
→ 可以直接执行

写入、外部发布和其他副作用
→ 需要明确用户意图或确认

删除、Shell、AppleScript、自动化
→ 默认逐次确认或采用更严格策略
```

Capability（能力存在）、OS Permission（系统权限）与 Tool Policy（Mira 工具策略）必须分开。

## 12.4 长任务

Agent 长任务可以持久化状态，并在 Mira 再次打开后恢复或明确标记为中断。

在没有独立 Helper（辅助进程）前，不承诺 App 完全退出后继续执行。

> **参考设计标注｜DeepSeek Harness**  
> 借鉴其 Step 驱动 Agent Loop、追加式执行日志、受保护工具管线、并行安全工具与独占工具的区分。Mira 不照搬动态插件运行时，也不把所有临时检索结果永久变成 Conversation 内容。

---

# 13. Model Provider 与 BYOK

## 13.1 Provider 管理

用户可以配置多个 Provider Connection（服务商连接），包括：

- 官方服务商 API；
- OpenAI-compatible 兼容端点；
- 聚合服务；
- 用户自建兼容端点；
- 本地模型服务。

## 13.2 Credential（凭据）

凭据由系统安全存储管理，普通数据库只保存引用，不保存明文密钥。

架构应允许：

- API Key；
- OAuth；
- 本地认证；
- 无凭据本地端点。

## 13.3 Model Discovery（模型发现）

Mira 可以读取 Provider 模型列表，但用户始终可以手工填写 Model ID。

发现失败不应阻止用户使用私有部署名或新模型。

## 13.4 用途级路由

用户可以为不同用途设置模型：

```text
conversation
agentReasoning
memoryExtraction
knowledgeProcessing
compact
embedding
vision
speech
```

一次 Agent Turn 内主模型路线保持固定。

跨 Provider Fallback（跨服务商降级）默认禁止；只有用户显式配置后才能发生。

## 13.5 使用量与费用

Mira 应展示：

- 输入和输出 Token；
- Provider 返回的 Cache Read / Write Token；
- 当前模型和连接；
- 基于价格目录计算的费用估算；
- 前台任务与后台任务的费用拆分。

费用必须标记为估算，不冒充服务商账单。

---

# 14. Context Engine 的产品行为

## 14.1 三层 Context

每轮模型请求由三类内容组成：

```text
Stable Header
稳定头部

Durable Conversation Surface
可持续的对话表层

Turn-scoped Context
仅当前请求有效的上下文
```

### Stable Header

包括：

- Mira 身份与系统规则；
- 权威等级和安全规则；
- 当前冻结的工具定义；
- 当前执行配置。

### Durable Conversation Surface

包括：

- 用户消息；
- Assistant 最终消息；
- 必须保持连续性的操作结果；
- Compact Checkpoint；
- 明确的用户 Steering（转向或纠正）。

### Turn-scoped Context

包括：

- 本轮相关 Memory；
- Knowledge Source 片段；
- Working Memory；
- 当前时间和环境状态；
- 临时搜索结果；
- 本轮用户输入。

Turn-scoped Context 保存在 Request Snapshot（请求快照）中以便审计，但下一轮不默认继续注入。

## 14.2 正确性优先于缓存

Mira 应尽量保持 Stable Header 和 Durable Conversation Prefix（持久对话前缀）稳定，以利用 Provider 的 Prompt / KV Cache（提示词 / 键值缓存）。

但不能为了缓存命中，把第三轮检索到的无关资料一直留到第三十轮。

产品原则是：

> 在不损害当前回答相关性、正确性和隐私边界的前提下保持前缀稳定。

## 14.3 有限预取与 Agent 主动检索

每轮开始前进行轻量本地预取，只提供少量高相关 Memory。

复杂历史问题由 Agent 主动调用：

- `memory.search`；
- `knowledge.search`；
- `source.open`；
- `timeline.search`。

这两条路径共同存在，不二选一。

## 14.4 Context Inspector

用户可以查看：

- Stable Header 的版本；
- 本轮使用的 Memory；
- 本轮使用的资料片段；
- 每项的来源与选择原因；
- 哪些内容因预算被省略；
- 哪些内容仅本轮有效；
- 是否切换了 Prefix Series；
- Provider 实际返回的缓存使用数据。

## 14.5 Prompt 呈现规则

架构必须定义稳定的 Prompt Composition Contract（提示词组合契约），包括：

- Mira 身份；
- 权威顺序；
- Memory 呈现格式；
- 未确认、过期和冲突信息的处理；
- 外部文档不得升级为系统指令；
- Prompt 和 Renderer（渲染器）版本追踪。

PRD 不冻结具体 XML 或 Markdown 语法，但要求不同 Provider 获得语义一致、可审计的上下文。

## 14.6 Compact

Compact 是 Conversation 内部的模型上下文压缩，不是 Memory，也不会删除原始 Message。

基线规则：

- 压缩最旧的连续完整区间；
- 保留最近 Conversation Tail；
- 不拆开 Tool Call 与对应 Tool Result；
- 结果只有确实减少 Token 时才落地；
- Compact 使用独立用途模型路线；
- 当 Compact Route 与主对话路线相同时，可以重放相同前缀尝试利用缓存；
- 当路线不同时，只发送必要的待压缩区间，不强求原会话缓存；
- Compact 后从替换点建立新的稳定前缀。

---

# 15. Structured Data（结构化数据）

Memory 与可操作的结构化记录必须分开。

## 15.1 基础对象

```text
EventRecord
已经发生、被观察或被记录的一件事

Task
需要完成的事项

Reminder
在某个时间或条件提醒用户

CalendarEvent
占据某段时间的安排

FinancialTransaction
收入、支出、退款或转账等轻量财务流水
```

## 15.2 EventRecord 边界

EventRecord 只描述已经发生或已经观察到的事件，不再同时表达“未来计划”。

未来计划进入 CalendarEvent；需要执行的行为进入 Task；需要通知的行为进入 Reminder。

事件本身可被搜索和回顾，默认不再重复生成同内容的“memorableEvent Memory”。只有从事件中形成长期认识时，才产生 Memory。

## 15.3 从 Conversation 自动提取

同一句话可以创建多个对象。

例如：

> 今天在盒马花了 126.8 元，明天下午三点提醒我报销。

可以产生：

- 一条 FinancialTransaction；
- 一条 Reminder；
- 原始 Conversation Message；
- 它们之间的 Evidence（证据）关系。

处理规则：

```text
明确命令
→ 直接创建或修改

明确事实但没有要求执行
→ 根据用户设置自动记录，或生成可撤销提示

金额、时间、对象或意图不明确
→ Candidate，等待确认
```

## 15.4 变更与溯源

结构化记录采用：

```text
当前有效状态
+
轻量 Revision 历史
+
Evidence Link
```

用户可以追溯：

- 原始值；
- 当前值；
- 谁修改；
- 哪句话或哪个 Tool Result 触发；
- 修改时间；
- 取消、完成或删除历史。

不建设完整 Event Sourcing（事件溯源）系统。

## 15.5 轻量财务记录的产品范围

FinancialTransaction 支持：

- 自然语言记账；
- 收入、支出、退款与转账；
- 金额、币种、商户、分类和备注；
- 按时间、类别、商户和 Workspace 汇总；
- 搜索和修改；
- CSV 导出；
- 退款或纠正关系。

当前明确不做：

- 银行账户自动同步；
- 信用卡对账；
- 复式记账；
- 税务核算；
- 投资资产净值；
- 将其包装成专业财务软件。

## 15.6 Mira 与 Apple Calendar / Reminders

Mira 内部 CalendarEvent 与 Reminder 是规范事实源。

用户可以选择单向发布到：

```text
Mira CalendarEvent → Apple Calendar
Mira Reminder      → Apple Reminders
```

当前产品边界：

- 不从 Apple 全量导入；
- Apple 端标题、时间、备注和优先级修改不回流；
- Apple 发布失败不回滚 Mira 内部记录；
- Mira 可以检查外部副本是否仍存在以及发布是否成功；
- 外部副本丢失时可以重新发布。

## 15.7 单一通知所有者

为了避免重复通知，每条 Reminder / CalendarEvent 必须只有一个默认通知所有者：

```text
deliveryOwner = mira
由 Mira 的本地通知负责

deliveryOwner = apple
由 Apple Calendar / Reminders 负责
```

发布到 Apple 并启用 Apple 通知后，Mira 不再为同一触发条件重复安排本地通知。

“是否只回读 Apple Reminder 的完成状态”保留为产品假设；当前不以隐式方式引入半双向同步。

> **参考设计标注｜Apple EventKit / UserNotifications**  
> EventKit 用于创建 Apple Calendar 与 Reminders 外部副本；UserNotifications 用于 Mira 自己负责的本地通知。Mira 的业务事实仍保存在本地数据库，外部系统状态不静默覆盖内部记录。

---

# 16. Artifact

Artifact 表示用户或 Mira 产生并值得长期保留的结果，例如：

- Markdown 文档；
- PDF；
- 图片；
- 表格；
- 报告；
- 计划；
- 项目文件；
- 导出的数据。

Artifact 与以下概念分开：

```text
Attachment
用户输入或引用的附件

Tool Result
某次执行产生的临时结果

Knowledge Source
被知识库整体保留并可解析的来源资料
```

一个对象可以在用户操作后从 Tool Result 提升为 Artifact 或 Knowledge Source，但不会自动复制多个文件副本。

---

# 17. Local-first、隐私与数据发送边界

## 17.1 本地能力

没有网络或没有 Provider 时，用户仍应能够：

- 打开和浏览本地数据；
- 编辑 Note、Memory、Task、CalendarEvent 和 FinancialTransaction；
- 使用本地搜索；
- 查看历史 Conversation；
- 导入和导出资料；
- 使用不依赖远程模型的本地工具。

## 17.2 数据发送披露

每次远程模型调用应能够解释：

- 发送给哪个 Provider；
- 使用哪个模型；
- 包含哪些类型的本地内容；
- 是否包含文件或图片；
- 是否包含长期 Memory；
- 哪些内容因 Workspace 隐私策略未发送。

## 17.3 敏感内容

敏感 Memory 或 Source 可以设置为：

- 仅本地保存；
- 可本地搜索但不可发送到远程模型；
- 仅允许指定 Provider 使用；
- 需要逐次确认。

---

# 18. 跨设备与未来同步边界

当前首先实现 macOS，本节只定义产品语义，不要求当前建设同步 Runtime。

## 18.1 默认数据边界

```text
设备本地
Conversation
Message
Execution
Tool Result
Compact
Provider Credential
Apple 外部副本标识

未来可共享
Workspace
Global Memory
Project Memory
Knowledge Note
部分 Knowledge Source
Task
Reminder
CalendarEvent
EventRecord
FinancialTransaction
```

## 18.2 Conversation 默认不全量同步

不同设备可以拥有不同本地 Conversation，但共享长期 Memory 与结构化状态。

未来可以提供显式 Handoff（接续快照），而不是默认同步完整历史。

## 18.3 不建设 Mira 同步服务器

未来同步候选可以包括 CloudKit / CKSyncEngine 等 Apple 能力，但 Mira 不建设自己的用户数据同步后端。

当前只保留稳定身份、修订和删除语义等最低兼容性，不提前建设 Change Journal、Sync Envelope 或复杂冲突引擎。

---

# 19. macOS 产品形态

## 19.1 定位

> Personal AI Workspace（个人 AI 工作空间）

macOS 重点支持：

- 多 Workspace；
- 多 Conversation；
- 文件和知识处理；
- Agent 执行；
- Memory 与 Context 检查；
- 长任务；
- 搜索与整理；
- 快捷键和多窗口体验。

## 19.2 推荐基础布局

```text
┌──────────────────────────────────────────────────────────────┐
│ Toolbar / Command                                            │
├──────────────┬──────────────────────────┬────────────────────┤
│ Sidebar      │ Main Content             │ Inspector          │
│              │                          │                    │
│ Home         │ Conversation / Note      │ Context            │
│ Inbox        │ Calendar / Search        │ Memory             │
│ Workspaces   │ Knowledge / Artifact     │ Execution          │
│ Memories     │                          │ Source             │
│ Knowledge    │                          │                    │
└──────────────┴──────────────────────────┴────────────────────┘
```

Inspector 可以在普通使用时收起，在调试、核对来源和管理权限时展开。

---

# 20. 核心用户场景

## 场景 A：跨 Conversation 延续项目讨论

1. 用户打开 Mira Workspace。
2. 新建 Conversation，询问此前架构决定。
3. Mira 预取少量相关 Project Memory。
4. Agent 在需要时继续搜索来源。
5. 回答中展示 Memory 来源和当前有效性。

## 场景 B：自动记住清晰的用户决定

用户说：

> Mira 的核心继续使用 Swift，不使用 Rust Core。

Mira：

1. 识别为用户明确决定；
2. 自动保存为 Project Memory；
3. 在对话中显示可撤销提示；
4. 下次讨论技术栈时正确召回；
5. 不把此前 Assistant 提出的 Rust 方案误记成用户决定。

## 场景 C：高风险冲突进入候选

用户说：

> 也许以后还是做个云端服务更方便。

Mira 不应直接替代“无 Mira 自建后端”的已确认规则，而应生成待审核冲突或仅保留为 Conversation 内容。

## 场景 D：导入资料并形成知识

1. 用户导入 PDF 或 Markdown。
2. Mira 保存原始 Source。
3. 文本被解析和索引。
4. 用户可以搜索片段并创建 Note。
5. 重要结论可以成为带 Evidence 的 Memory。
6. 外部文档里的指令不自动升级为系统指令。

## 场景 E：从对话创建提醒并发布到 Apple

用户说：

> 明天下午三点提醒我发架构文档，并同步到系统提醒事项。

Mira：

1. 创建内部 Reminder；
2. 保留源 Message；
3. 发布到 Apple Reminders；
4. 将通知所有者设为 Apple，避免重复通知；
5. 发布失败时保留 Mira 记录并显示可重试状态。

## 场景 F：轻量记账与纠正

用户说：

> 记一笔，今天买键盘花了 699 元。

随后说：

> 刚才是 679，不是 699。

Mira 保留当前金额 679 元，并允许查看原金额、修改来源和时间。

## 场景 G：复杂历史检索

用户问：

> 我们讨论过的所有 Memory 自动提取策略有哪些？各自为什么没选？

Mira 不只依赖预取，而是主动调用 Memory、Conversation 和 Source 搜索，综合多个来源回答。

## 场景 H：Agent 文件任务

1. 用户通过系统选择器授权项目目录。
2. Agent 在授权范围内搜索和读取文件。
3. 只读操作可直接执行。
4. 写入或删除需满足权限策略。
5. Execution Inspector 显示调用过程、失败和结果。

---

# 21. 冷启动体验

Mira 不能要求用户积累大量 Memory 后才体现价值。

## 21.1 首次即可获得的价值

首次配置 Provider 后，用户可以立即：

- 对话；
- 创建 Workspace；
- 写 Project Context；
- 读取授权文件；
- 创建 Task、Reminder 和 CalendarEvent；
- 导入 Markdown / PDF；
- 使用本地搜索。

## 21.2 可选快速初始化

用户可以选择填写：

- 称呼和语言偏好；
- 希望 Mira 的回答风格；
- 当前关注项目；
- 自动记忆偏好；
- 是否导入已有 Markdown / Obsidian 资料。

所有步骤都可跳过。

## 21.3 首条 Memory 反馈

Mira 在第一次形成有效 Memory 时应清晰展示：

- 记住了什么；
- 来源在哪里；
- 作用范围；
- 如何撤销或编辑。

用户应在第一天就理解 Mira 与普通聊天窗口的差异。

---

# 22. Background Intelligence（本地后台智能）与成本

## 22.1 可执行的后台工作

在用户允许时，Mira 可以执行：

- Memory 提取；
- Source 解析与分块；
- 全文索引；
- 重复 Memory 检查；
- Entity Mention 提取；
- 搜索索引重建；
- 可选 Embedding（向量嵌入）；
- 用户主动触发的知识整理。

## 22.2 默认保护

- 前台 Conversation 优先于后台任务；
- 后台远程模型调用有每日 Token / 费用预算；
- 达到预算后暂停，不静默超额；
- 可以选择只在充电、空闲或手动触发时执行；
- 非核心的关系发现、综合和图聚类默认按需运行；
- App 完全退出后不承诺继续执行。

## 22.3 成本可见性

Settings 与 Activity 中应区分：

- Conversation 成本；
- Agent 工具循环成本；
- Memory Extraction 成本；
- Compact 成本；
- Knowledge Processing 成本；
- Embedding 成本。

用户可以关闭某类后台远程处理，或为其选择更便宜 / 本地的模型路线。

---

# 23. 数据所有权、导入、导出与删除

用户应能够导出：

- Conversation；
- Memory；
- Knowledge Note；
- Source 元数据和可导出原文件；
- Task、CalendarEvent、Reminder 和 EventRecord；
- FinancialTransaction CSV；
- Artifact；
- Execution 摘要和来源关系。

支持的主要格式可以包括：

- Markdown；
- JSON；
- CSV；
- 原始文件目录；
- Obsidian-compatible Folder。

删除语义需要区分：

```text
Archive
退出默认使用但保留

Remove
从当前视图或范围移除

Forget
删除长期 Memory 及其派生使用关系

Permanent Delete
在允许范围内物理清理规范数据和 Blob
```

删除不能只移除索引而留下不可见的规范内容。

---

# 24. 非功能产品要求

## 24.1 离线可用

本地浏览、编辑、搜索和数据管理不依赖网络。

## 24.2 数据可靠性

- 关键写入具备原子性；
- 崩溃后不会出现永久 Running 的幽灵任务；
- Assistant 流式内容可以恢复已展示部分；
- 索引损坏时可重建；
- Blob 删除前验证真实引用。

## 24.3 可恢复性

用户可以：

- 重试失败模型调用；
- 重试 Apple 发布；
- 恢复被归档内容；
- 查看中断的 Agent 执行；
- 重新生成派生索引。

## 24.4 可访问性与可理解性

- 支持键盘导航；
- 支持 VoiceOver；
- 不只依赖颜色表达状态；
- 自动操作有明确状态词；
- 错误提供可行动建议；
- Memory 和工具副作用有撤销或纠正入口。

## 24.5 性能体验

- 打开本地页面不应等待远程模型；
- 搜索先返回本地结果；
- 大型 Tool Result 不完整塞入 UI 或 Context；
- 后台任务不明显抢占前台交互；
- Context 构建和 Memory 预取应有可观测耗时。

---

# 25. 成功标准与评估闭环

## 25.1 核心产品成功标准

### 连续性

在新的 Conversation 中，Mira 能找回真正相关的长期认知。

### 准确性

不会把 Assistant 建议、外部文档观点或用户假设误记成已确认决定。

### 低干扰

自动记忆不形成永远清不完的审核收件箱；用户可以快速撤销错误记忆。

### 可追溯

Memory、结构化记录和重要回答可以回到原始 Message、Source 或 Tool Result。

### 可纠正

用户能编辑、替代、归档、删除和遗忘。

### Agent 可控

工具调用、权限、失败、重试和副作用对用户可见。

### 数据自主

没有 Mira 后端时，数据仍可长期使用、备份和导出。

## 25.2 必须建立的 Eval

产品实施需要至少四类 Eval：

1. Memory Extraction：是否该记、是否正确归属、是否正确 Scope；
2. Memory Retrieval：是否在需要时召回、是否泄漏其他 Workspace、是否召回已被替代版本；
3. End-to-End Continuity：形成 Memory 后在新 Conversation 中能否正确使用并引用来源；
4. Provider Matrix：同一 Fixture 在不同用户模型下是否稳定。

指标至少包括：

- 提取 Precision / Recall（准确率 / 召回率）；
- Speaker Attribution Accuracy（发言者归属准确率）；
- Scope Accuracy（范围准确率）；
- Retrieval Hit@K；
- Irrelevant Injection Rate（无关注入率）；
- Superseded Recall Rate（错误召回旧版本比例）；
- Source Citation Accuracy（来源引用准确率）；
- 自动记忆撤销率和纠正率。

---

# 26. 当前基线默认

| 主题 | 当前默认 |
|---|---|
| 自动 Memory | 明确“记住”直接生效；清晰稳定用户陈述可自动生效并可撤销；推断、敏感、冲突进入 Candidate |
| Candidate | 不参与普通召回，只在审核和专门整理场景出现 |
| Memory Retrieval | 少量预取 + Agent 主动深度检索 |
| Context Lifetime | 临时检索只在当前请求有效；Conversation 与必要操作结果才进入持久表层 |
| Prefix Cache | 保持 Stable Header 与 Durable Conversation 稳定，不以长期保留噪声换取缓存 |
| Working Memory | 用户固定项 + 确定性快照；LLM 摘要为可选增强 |
| Knowledge Synthesis | 第一阶段作为带 Evidence 的生成 Draft Note，而非独立重型对象 |
| Topic | Tag、Entity、保存搜索和可重建聚类优先 |
| Graph View | 可选探索视图，不是核心事实源或首个闭环前提 |
| Provider Route | 用途级确定性路由；一次 Agent Turn 内冻结 |
| Provider Fallback | 默认禁止跨 Provider 静默切换 |
| Apple 发布 | Mira → Apple 单向；一个通知所有者；外部副本状态可检查 |
| FinancialTransaction | 对话驱动的轻量现金流记录，不建设专业账本 |
| Sync-ready | 只保留最低稳定身份和修订语义，不提前建设同步 Runtime |
| Workspace | 单层 |
| Core | 原生 Swift |

---

# 27. 产品假设与待验证问题

以下问题保留为假设，不阻塞首个纵向闭环：

1. Graph View 是否会成为高频入口；
2. 是否需要独立 Knowledge Synthesis 实体；
3. 自动 Entity / Relation 建议的长期价值；
4. Working Memory 是否需要 LLM 定期总结；
5. 自动生效 Memory 的最佳范围和撤销率阈值；
6. Memory 预取的最佳条数和 Token 预算；
7. FinancialTransaction 的真实使用频率与所需报表；
8. 是否允许窄范围回读 Apple Reminder 完成状态；
9. Conversation Handoff 的产品需求强度；
10. iOS 是否需要接近单会话的交互外观；
11. 是否需要可信的第三方 Tool 扩展机制；
12. 是否需要本地 Helper 维持 App 退出后的长任务。

---

# 28. 当前明确不做

- Mira 自建模型代理或用户数据后端；
- 团队与企业权限系统；
- 强制云账号；
- 所有 Conversation 默认全量同步；
- Apple Calendar / Reminders 的完整双向同步；
- 外部 Markdown Vault 与 Mira 数据库实时双向写入；
- 不经授权的自主写入、删除或自动化；
- 专用图数据库作为事实源；
- 动态二进制插件市场作为基础架构；
- 专业银行对账、复式记账或税务系统；
- 将 Candidate 当作已确认事实注入普通对话；
- 为缓存命中永久保留无关临时检索结果。

---

# 29. MVP 拆分原则

MVP 将单独形成 `MVP.md`。

MVP 不需要等待所有长期产品假设定型。核心不变量和第一条数据闭环明确后，应按纵向路径实施、使用、评估和反向修订文档。

建议第一条纵向闭环围绕：

```text
Conversation
  ↓
清晰用户陈述自动形成 Memory
  ↓
新 Conversation 中正确召回
  ↓
查看来源
  ↓
编辑 / 撤销 / 删除
  ↓
Task / Reminder 基础创建
```

MVP 可以暂缓高级知识图谱、自动综合和未来同步，但不能采用与产品不变量相反的数据语义。

---

# 30. 参考设计映射

## 30.1 DeepSeek Harness

借鉴：

- Step 驱动的 Agent Loop；
- 追加式 Session / Execution Log；
- 从日志派生模型可见内容；
- Guarded Tool Pipeline（受保护工具管线）；
- Parallel-safe / Exclusive 工具并发分类；
- Provider-neutral 模型契约；
- Compact Shadow（压缩遮蔽）与 Recent Tail；
- 同路线 Compact 时重放稳定前缀的缓存优化。

不照搬：

- TypeScript / Cordis 物理实现；
- “Everything is a plugin”的动态生命周期；
- Coding Agent 中所有运行内容都适合长期留在个人助理 Context 的假设；
- Compact 必须使用主对话模型的规则。

主要资料：

- [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)
- [Agent Loop](https://github.com/deepseek-ai/deepseek-harness/blob/master/packages/core/agent-loop/README.md)
- [Session](https://github.com/deepseek-ai/deepseek-harness/blob/master/packages/core/session/README.md)
- [Tools](https://github.com/deepseek-ai/deepseek-harness/blob/master/packages/core/tools/README.md)
- [Compaction](https://github.com/deepseek-ai/deepseek-harness/blob/master/packages/compaction/compaction/README.md)
- [Compaction Basic](https://github.com/deepseek-ai/deepseek-harness/blob/master/packages/compaction/compaction-basic/README.md)

## 30.2 Nowledge Mem

借鉴：

- Trace / Conversation 与 Atomic Memory 分开；
- Working Memory；
- 来源、发言归属和演化关系；
- Library / Knowledge Source；
- 混合检索；
- 多来源综合与知识连接。

不照搬：

- 固定的服务端或自托管形态；
- 所有自动提取都进入长期审核队列；
- 初期就建设完整 Topic 社区检测和重型 Synthesis 生命周期；
- 其全部类型、评分和后台频率。

主要资料：

- [Memories](https://mem.nowledge.co/zh/docs/memories)
- [AI Context](https://mem.nowledge.co/zh/docs/ai-context)
- [Knowledge Graph](https://mem.nowledge.co/zh/docs/knowledge-graph)
- [Search Architecture](https://mem.nowledge.co/zh/docs/concepts/search-architecture)
- [Background Intelligence](https://mem.nowledge.co/zh/docs/concepts/background-intelligence)

## 30.3 Obsidian

借鉴 Markdown、Wiki Link、Backlink、本地文件心智和知识关系探索。

主要资料：

- [Internal Links](https://obsidian.md/help/links)
- [Graph View](https://obsidian.md/help/plugins/graph)

## 30.4 Apple 平台能力

- EventKit：创建 Apple Calendar / Reminders 外部副本；
- UserNotifications：Mira 自己负责的本地通知；
- Keychain：Provider Credential；
- Security-scoped Bookmark：持续访问用户授权文件；
- CKSyncEngine：未来 Apple 生态同步候选，而非当前依赖。

主要资料：

- [EventKit](https://developer.apple.com/documentation/eventkit)
- [UserNotifications](https://developer.apple.com/documentation/usernotifications)
- [Keychain Services](https://developer.apple.com/documentation/security/keychain-services)
- [App Sandbox File Access](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)
- [CKSyncEngine](https://developer.apple.com/documentation/cloudkit/cksyncengine)

## 30.5 GRDB 与 SQLite

- GRDB 作为 Swift 本地 SQLite 应用数据工具；
- SQLite 作为本地应用文件和规范数据库；
- FTS5 用于基础全文检索；
- WAL（Write-Ahead Logging，预写日志）与事务用于可靠本地写入；
- 大型文件进入 Blob Store。

主要资料：

- [GRDB.swift](https://github.com/groue/GRDB.swift)
- [SQLite FTS5](https://www.sqlite.org/fts5.html)
- [SQLite WAL](https://www.sqlite.org/wal.html)
- [SQLite Application File Format](https://www.sqlite.org/appfileformat.html)

---

# 31. 一句话产品定义

> **Mira 是一个面向个人、以本地数据为事实源、通过 BYOK 使用多模型、能够行动并持续沉淀可追溯记忆与知识的原生 AI 助理和 Agent 工作空间。**
