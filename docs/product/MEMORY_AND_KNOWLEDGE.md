# 记忆与知识产品规范

**文档版本：** v1.2  
**更新日期：** 2026-09-05  
**状态：** 设计基线；当前实现与验收范围见 [实施记录](../engineering/IMPLEMENTATION_STATUS.md)。

定义 Memory、Project Context、Working Memory、Knowledge 与 Artifact 的用户语义、反馈和纠正体验；技术模型由对应 architecture 文档负责。

返回 [PRD.md](../PRD.md) · 版本范围：[MVP](../MVP.md)

---

<a id="s09"></a>

## 1. Memory System（记忆系统）

<a id="s09-01"></a>

### 1.1 Memory 的定义

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

<a id="s09-02"></a>

### 1.2 Global Memory 与 Project Memory

二者使用同一个 Memory 系统，仅通过 Scope（适用范围）区分。

#### Global Memory

描述用户本人跨项目可复用的长期信息，例如：

- 沟通偏好；
- 稳定习惯；
- 长期目标；
- 用户明确要求全局记住的规则。

#### Project Memory

描述某个 Workspace 内的长期认知，例如：

- 已确认架构决定；
- 项目约束；
- 关键经验；
- 重要开放问题；
- 当前有效方案。

其他 Workspace 的 Project Memory 默认不进入当前对话。Inbox 对话默认只召回 Global Memory；创建于 Inbox 的内容如果无法确认适用范围，不自动升级为全局记忆。

Workspace 是检索与数据发送边界，标签和实体链接不会自动授予跨 Workspace 读取权限。移动 Conversation 到另一个 Workspace 时必须提示新的上下文范围；已有 Memory 不随之自动改 Scope，也不自动成为新 Workspace 的项目事实。

<a id="s09-03"></a>

### 1.3 Memory 的分级产生策略

这是**基线默认**，需要通过真实使用和 Eval 持续调整。普通用户输入会进入自动关联评估，即按当前请求自动预取相关 Memory；这不会开启自动捕获或改变后台提取设置。是否提交后台提取、使用远程用途模型或直接生效，仍受用户设置、用途授权和以下规则约束。

#### A. 用户明确要求记住

例如：

> 记住，Mira 不建设自有后端。

处理：

- 内容、主体与范围清楚并通过校验后直接生效；
- 标记为用户明确意图；
- 提供编辑、来源和删除入口；
- 不再要求用户重复审核。

明确要求记住敏感信息表示同意保存该条内容，不自动表示允许后续向任意远程 Provider 发送。范围不明确时先询问范围；普通文字修正可直接保存，涉及替代旧认知时展示明确替代对象。仅在用户已明确指明替代意图和对象时，才无需重复确认。

#### B. 用户清晰表达稳定事实、偏好或决定

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

#### C. 推断、敏感、冲突或低置信内容

以下内容进入 Candidate（候选），不参与普通召回：

- Mira 根据多次行为推测的偏好；
- 外部资料中推断出的用户立场；
- 会替代一条已确认 Memory 的新内容；
- 涉及敏感个人信息；
- 主体、时间或范围不明确；
- 提取置信度较低；
- 可能只是当前情绪或短期状态。

Candidate 集中进入审核入口，不应每次打断 Conversation。

<a id="s09-04"></a>

### 1.4 Memory 生命周期

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

界面还会根据关系、时间和遗忘记录显示生命周期状态：`superseded`（被替代）、`expired`（已过期）、`notYetValid`（尚未生效）和 `forgotten`（已遗忘）。这些记录不会显示为 Active，也不参与普通召回；生命周期标签保留历史可理解性，不改变持久化的工作流状态。

<a id="s09-05"></a>

### 1.5 Revision 与 Evolution

#### Revision（修订）

同一认知的非语义性调整：

- 修正文字；
- 改标题；
- 补标签；
- 增加来源；
- 改善表达但核心含义不变。

#### Evolution（演化）

认知本身发生变化：

```text
replaces   新认知替代旧认知
enriches   新认知补充旧认知
confirms   独立信息支持旧认知
challenges 新信息质疑旧认知
```

高影响的 `replaces` 在用户确认前不能让旧 Memory 退出正常召回。

<a id="s09-06"></a>

### 1.6 来源与发言归属

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

<a id="s09-07"></a>

### 1.7 时间语义

Memory 需要区分：

- 事情发生的时间；
- Mira 记录的时间；
- 有效开始和结束时间；
- 最后确认时间；
- 时间精度与模糊程度。

“用户目前在新加坡”属于可能过期的状态，不应被当作永久事实。

<a id="s09-08"></a>

### 1.8 Memory 的召回体验

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

Opening a memory from its processing result shows that specific memory, including an older item beyond the initial management list. Existing search text is cleared for this direct navigation; workspace access boundaries still apply.

<a id="s09-09"></a>

### 1.9 自动记忆设置与处理反馈

首次启用自动记忆时说明：哪些用户消息会被处理、使用哪个用途模型、是否产生额外远程费用，以及如何关闭。用户未启用时，不在后台发送消息做自动提取；手动新增与明确“记住”的操作仍可使用。

用户可以切换“自动捕获并可撤销”“只生成候选”“仅手动”三种模式。启用自动模式后的分类规则仍遵守[相关规范 §1.3](MEMORY_AND_KNOWLEDGE.md#s09-03)。自动操作展示处理中、已记住、需审核或失败状态；没有已提交记录时，Assistant 不能声称“已记住”。

自动提取不阻塞正常回复。用户紧接着开启新 Conversation 时，可以看到尚未完成的提取，并选择等待或继续；Mira 不伪装已经拥有尚未落库的记忆。

<a id="s09-10"></a>

### 1.10 纠正、撤销与避免再次记住

- 编辑一条 Memory 的文字与编辑其含义是两种操作：含义变化保留旧认知与替代关系，用户能看到本次影响。
- 撤销自动捕获或拒绝候选后，同一来源的自动重试、索引重建与提取器升级不应重新创建同一条内容。
- “忘记这条”立即阻止这条 Memory 继续召回和后台再提取，并清理 Memory 正文、修订版本、Evidence 正文、工具 / 请求 / 审计缓存和活跃草稿。已提交的历史用户消息、Assistant 回复与可显示的 Trace（Assistant 正文和可显示思考）仍保留在本地可见，并带有不含正文的状态标签；Trace 中隐藏的工具消息、参数、结果和 Tool Call 标识会被清理。它们以及由其历史传递影响的后续记录不再进入未来 Provider Context，也不会被模型重放。
- 原始 Conversation 或 Source 可以保留。若用户要求连原文都删除，明确展示连带清理的来源和影响。仅删除 Memory 不承诺使原始文本在显式历史搜索中不可见。
- 新来源再次陈述相同事实不等于同一来源重试。当前只保证对已排除来源与已识别内容的抑制；跨所有语义改写的永久屏蔽不冒充已实现能力。用户可以明确重新要求记住。
- 已确认替代的新记忆被归档或删除时，旧认知不自动恢复为当前事实；恢复需要用户明确操作。

<a id="s09-11"></a>

### 1.11 知识更新与来源失效

更新 Source 或删除来源时，已人工确认的 Memory 不静默消失或重新解释为新版本资料的结论。显示其依据的原始版本或“来源已不可用”状态。若 Evidence 存在归属错误或不能再支撑该记忆，退出自动事实注入并等待纠正。Memory 因此失效时，已提交的历史消息、回复和可显示 Trace 可以继续在本地查看并显示状态标签，但相关内容（包括历史依赖的传递后代）不得再次进入 Provider Context。

> **参考设计标注｜Nowledge Mem**  
> 借鉴其将原始对话与可独立复用的 Memory 分开、保留来源、Working Memory 与知识演化的思路。Mira 不照搬固定审核队列：对清晰的用户陈述采用“自动生效 + 易撤销”，把推断、敏感和冲突内容保留为 Candidate。

---

<a id="s10"></a>

## 2. Project Context 与 Working Memory

<a id="s10-01"></a>

### 2.1 Project Context（项目上下文）

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

<a id="s10-02"></a>

### 2.2 Working Memory（工作记忆）

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

<a id="s11"></a>

## 3. Knowledge Base（知识库）

<a id="s11-01"></a>

### 3.1 Knowledge Source（知识来源）

表示需要整体保留的原始资料，例如：

- Markdown；
- PDF；
- 网页快照；
- 代码文件；
- 图片、音频和视频；
- 导入的 Obsidian 笔记；
- Conversation 或 Tool Result 的可引用内容。

Source 可以被解析成可检索片段，但原文件和来源身份仍被保留。

In v0.1, selecting a Markdown search result opens the matching source fragment with its original text and line range. Reply citations open the version used by that reply. If the source is deleted or its model-use permission is revoked, reopening a citation shows that it is unavailable, and an already open citation clears the unavailable content.

<a id="s11-02"></a>

### 3.2 Knowledge Note（知识笔记）

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

<a id="s11-03"></a>

### 3.3 Wiki Link 与 Backlink

Knowledge Note 支持：

- `[[Wiki Link]]`；
- Backlink（反向链接）；
- 标签；
- 引用 Memory；
- 引用 Source；
- 引用其他 Note。

链接应解析为稳定对象引用，避免仅靠标题字符串维持关系。

<a id="s11-04"></a>

### 3.4 Entity 与 Relation

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

<a id="s11-05"></a>

### 3.5 Topic 与 Graph View 的定位

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

<a id="s11-06"></a>

### 3.6 Obsidian 互操作

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

<a id="s16"></a>

## 4. Artifact

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
