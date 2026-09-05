# Mira 产品需求总纲

**文档版本：** v1.2  
**更新日期：** 2026-09-05  
**状态：** 开发前规范基线；实现与验收尚未执行。

定义产品定位、用户问题、产品不变量与成功标准。具体交互和领域行为由 product 目录负责，本文不保存状态机、Schema 或实施排期。

## 文档职责与阅读顺序

| 文档区域 | 唯一职责 |
|---|---|
| [产品总纲](PRD.md) 与 [product/](product/WORKSPACE_AND_CONVERSATION.md) | 产品身份、用户场景、领域行为与用户可见承诺 |
| [架构总览](ARCHITECTURE.md) 与 [architecture/](architecture/RUNTIME.md) | 模块边界、领域模型、协议、状态机和存储契约 |
| [开发约定](engineering/DEVELOPMENT.md) | 平台、工具链、工程结构和交付方式 |
| [质量标准](engineering/QUALITY.md) | 测试、评估数据集与量化发布门槛 |
| [MVP 拆分](MVP.md) | 版本范围、依赖、实施顺序和里程碑退出条件 |
| [评审记录](reviews/2026-09-05-DOCUMENT_REVIEW.md) | 问题、理由、解决位置和仍待验证的证据 |
| [参考资料](REFERENCES.md) | 外部设计借鉴、官方资料与验证来源 |

规则分为产品 / 架构不变量、可调整的基线默认和待验证假设。修改行为时在负责该规则的文档中更新，并同步依赖引用；不复制多份状态机、字段表或验收阈值。MVP 负责选择本次实施哪些能力，不改变被选能力的信任边界。历史由 Git 保存，关键取舍可补充 ADR，不要求为每个概念预建决策文件。

## 领域文档

- [工作空间、对话与用户场景](product/WORKSPACE_AND_CONVERSATION.md)：定义用户如何组织工作空间、开展对话、冷启动及完成核心场景；不定义运行时数据模型。
- [记忆与知识产品规范](product/MEMORY_AND_KNOWLEDGE.md)：定义 Memory、Project Context、Working Memory、Knowledge 与 Artifact 的用户语义、反馈和纠正体验；技术模型由对应 architecture 文档负责。
- [Agent、模型接入与上下文产品规范](product/AGENT_AND_CONTEXT.md)：定义执行状态、权限体验、Provider 管理和模型上下文的用户行为；不定义协议字段或调度实现。
- [结构化记录产品规范](product/RECORDS.md)：定义事件、任务、提醒、日程和轻量财务记录的业务含义及 Apple 发布体验；版本范围由 MVP 决定。
- [数据生命周期、隐私与可靠性产品规范](product/DATA_AND_PRIVACY.md)：定义本地使用、远程发送、后台处理、同步边界、删除与恢复的产品承诺；实现契约在 architecture 目录。

---

<a id="s01"></a>

## 1. 产品定义

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

<a id="s02"></a>

## 2. 第一目标用户

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

<a id="s03"></a>

## 3. 用户核心问题

<a id="s03-01"></a>

### 3.1 AI 没有连续认知

用户经常需要重新解释：

- 自己是谁；
- 当前在做什么；
- 项目已经做过哪些决定；
- 哪些方案已经否决；
- 哪些表达和工作偏好需要长期遵守。

<a id="s03-02"></a>

### 3.2 重要结论被埋在聊天历史中

Conversation 保留完整讨论过程，但不适合作为唯一长期知识载体：

- 内容过长；
- 中间尝试很多；
- 重要结论散落；
- 新旧观点会冲突；
- 几个月后难以重新找到。

<a id="s03-03"></a>

### 3.3 个人资料彼此割裂

用户的知识可能同时存在于：

- 本地 Markdown；
- PDF、图片和其他文件；
- 代码仓库；
- 对话历史；
- 日历、提醒和任务；
- 不同 AI 工具。

Mira 需要在不抹平来源边界的前提下，让它们可以共同搜索、引用和关联。

<a id="s03-04"></a>

### 3.4 Agent 能执行，但难以信任

普通 Agent 产品经常不能清楚解释：

- 本轮使用了哪些记忆和资料；
- 为什么选择这些上下文；
- 调用了什么工具；
- 哪一步失败；
- 是否发生写入或外部副作用；
- 是否可以取消、重试、撤销或恢复。

<a id="s03-05"></a>

### 3.5 本地数据与远程模型之间缺少明确边界

用户希望使用强大的远程模型，但不希望：

- 所有资料默认上传；
- 密钥由未知服务器持有；
- 本地能力依赖某个中心服务持续在线；
- 无法导出自己的记忆和知识；
- 无法删除或纠正 AI 的长期认知。

---

<a id="s04"></a>

## 4. 产品愿景

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

<a id="s05"></a>

## 5. 产品不变量

<a id="s05-01"></a>

### 5.1 Personal First（个人优先）

Mira 默认只有一个数据所有者，不提前引入团队、组织、管理员或多租户模型。

<a id="s05-02"></a>

### 5.2 Local First（本地优先）

核心数据首先写入本地数据库或本地文件，并可在离线状态下查看、编辑和搜索。

<a id="s05-03"></a>

### 5.3 No Mira Backend（无 Mira 自建业务后端）

Mira 不建设用于以下目的的自有业务服务器：

- 代理模型请求；
- 保存用户 Conversation；
- 保存用户 Memory 和知识库；
- 执行核心 Agent 任务；
- 作为本地应用启动和查询数据的前置条件。

未来同步可以使用 Apple 提供的能力或用户控制的其他传输方式，但本地应用不能退化成云端客户端。

<a id="s05-04"></a>

### 5.4 BYOK（用户自带模型访问能力）

远程模型由用户配置自己的 Provider、凭据、模型和端点。Mira 不提供开发者统一密钥，也不替用户承担推理费用。

<a id="s05-05"></a>

### 5.5 Mac First（优先 macOS）

macOS 是首个完整宿主环境，优先承载：

- 多 Conversation；
- 文件和项目工作流；
- Agent 执行；
- Memory 与知识整理；
- Context 与 Execution Inspector；
- 较长时间的本地任务。

<a id="s05-06"></a>

### 5.6 Native Experience（平台原生体验）

macOS 与未来 iOS 可以使用不同的信息架构和 UI。共享的是核心逻辑和数据语义，而不是界面布局。

<a id="s05-07"></a>

### 5.7 Raw 与 Derived 分离

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

<a id="s05-08"></a>

### 5.8 User Control（用户掌控）

用户必须能够：

- 查看和编辑 Memory；
- 撤销自动记忆；
- 处理候选和冲突；
- 查看来源；
- 控制数据是否允许发送给远程 Provider；
- 控制工具权限；
- 导出数据；
- 删除或遗忘内容。

<a id="s05-09"></a>

### 5.9 Explainable Context（上下文可解释）

用户应能够检查本轮模型看到了哪些长期记忆、项目规则、资料片段和工具定义。

可审计不等于所有内容永久留在后续上下文中。

<a id="s05-10"></a>

### 5.10 Native Swift（原生 Swift）

共享 Core、Agent Runtime、Context、Memory、Knowledge、Provider 适配和本地数据层统一使用 Swift；Apple 专属能力由各平台 Host / Adapter 实现。

<a id="s05-11"></a>

### 5.11 Simple by Default（默认简单）

完整产品保留扩展空间，但不为尚未出现的需求提前建设：

- 动态二进制插件系统；
- 通用 DAG（Directed Acyclic Graph，有向无环图）工作流语言；
- 多套可写事实源；
- 企业权限体系；
- 专用图数据库；
- 当前不存在的同步 Runtime；
- 同一概念的多层抽象框架。

---

<a id="s06"></a>

## 6. 产品核心闭环

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

<a id="s25"></a>

## 7. 成功标准与评估闭环

<a id="s25-01"></a>

### 7.1 核心产品成功标准

#### 连续性

在新的 Conversation 中，Mira 能找回真正相关的长期认知。

#### 准确性

不会把 Assistant 建议、外部文档观点或用户假设误记成已确认决定。

#### 低干扰

自动记忆不形成永远清不完的审核收件箱；用户可以快速撤销错误记忆。

#### 可追溯

Memory、结构化记录和重要回答可以回到原始 Message、Source 或 Tool Result。

#### 可纠正

用户能编辑、替代、归档、删除和遗忘。

#### Agent 可控

工具调用、权限、失败、重试和副作用对用户可见。

#### 数据自主

没有 Mira 后端时，数据仍可长期使用、备份和导出。

<a id="s25-02"></a>

### 7.2 必须建立的 Eval

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

<a id="s27"></a>

## 8. 产品假设与待验证问题

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

<a id="s28"></a>

## 9. 当前明确不做

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
