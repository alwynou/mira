# 记忆与知识领域设计

**文档版本：** v1.2  
**更新日期：** 2026-09-05  
**状态：** 设计基线；当前实现与验收范围见 [实施记录](../engineering/IMPLEMENTATION_STATUS.md)。

定义记忆提取、来源、抑制、演化、工作记忆及资料版本与解析；用户可见行为在产品规范中定义。

The current manual increment contract is detailed in [Memory implementation](MEMORY_IMPLEMENTATION.md); this document remains the broader domain contract.

返回 [ARCHITECTURE.md](../ARCHITECTURE.md) · 版本范围：[MVP](../MVP.md)

---

<a id="s19"></a>

## 1. Memory Domain 与 Pipeline

<a id="s19-01"></a>

### 1.1 Memory

```text
Memory
├── id
├── scope                 global / workspace
├── workspaceId?
├── subjectReference      user / workspace / 已确认主体引用
├── kind                  fact / preference / decision / goal / constraint / procedure / learning / context
├── content
├── state                 active / candidate / archived / rejected / removed
├── origin
│   ├── explicitUser
│   ├── observedUserStatement
│   ├── agentInference
│   ├── sourceExtraction
│   └── generatedSynthesis
├── authority
│   ├── explicitUser
│   ├── observedUser
│   ├── externalSource
│   └── inferred
├── sensitivity
├── eventTime?
├── validFrom?
├── validUntil?
├── timePrecision?
├── lastConfirmedAt?
├── importance?
├── extractionConfidence?
├── createdAt
├── updatedAt
├── revision
└── deletedAt?
```

`freshness` 更适合根据类型、时间和最后确认时间动态计算，不作为永远不变的单一字段。

`scope = workspace` 必须存在有效 workspaceId；`scope = global` 时 workspaceId 必须为空。MVP 主体优先支持用户与当前项目，不能仅凭人名相同创建或合并实体。自动捕获、手动创建与候选批准统一走 Memory Use Case。

<a id="s19-02"></a>

### 1.2 EvidenceLink

统一来源关系：

```text
EvidenceLink
├── id
├── targetKind            memory / note / relation / structuredRecord
├── targetId
├── sourceKind            message / sourceChunk / toolResult / execution / artifact
├── sourceId
├── sourceRevision
├── sourceLocator?
├── excerpt?
├── sourceHash?
├── speakerRole?
├── relation              supports / derivesFrom / contradicts
├── createdAt
└── revision
```

跨设备源不可用时，Excerpt 提供最低解释；原始来源仍是更高权威证据。

<a id="s19-03"></a>

### 1.3 Speaker Attribution

Extractor 输出必须区分：

```text
userStatement
assistantSuggestion
toolObservation
externalAuthorStatement
agentInference
```

任何 `assistantSuggestion` 不得自动生成 `origin = observedUserStatement`。

<a id="s19-04"></a>

### 1.4 Triage Pipeline

```text
Committed Message / Source
        ↓
Triage Gate
是否值得长期保留？
        ↓
Structured Extraction
主体、Scope、时间、类型、内容、敏感度
        ↓
Speaker Attribution Validation
        ↓
Duplicate / Existing Memory Match
        ↓
Policy Decision
        ├── Active: explicit user
        ├── Active: clear stable user statement + Undo
        └── Candidate: inferred / sensitive / conflict / low confidence
        ↓
Persist Memory + Evidence
        ↓
Update Search Index / Current Projection
```

<a id="s19-05"></a>

### 1.5 清晰用户陈述自动 Active 的条件

必须同时满足：

- 来源是用户 Message；
- 不是引用或转述他人观点；
- 不是问句；
- 不是“可能、也许、假如”等未定表达；
- 不是短期情绪；
- Scope 可确定；
- 不属于敏感自动捕获禁区；
- 不替代已确认高权威 Memory；
- 通过重复检测。

未满足时进入 Candidate 或不创建。

<a id="s19-06"></a>

### 1.6 Idempotency

将任务重试身份与业务去重身份分开：

```text
Extraction Attempt Key
source ID + source revision + extractor version + policy version

Memory Candidate Key
source ID + subject + scope + normalized assertion fingerprint
```

提取器版本只属于任务身份，不能靠升级版本绕过 Memory 去重。候选输出在提交前同时匹配当前 Memory、来源决策和已拒绝 / 抑制记录；不确定的同义项进入候选，不能为了追求召回率复制成多个 Active。

保存最小 `ExtractionDecision`：source ID / revision、可定位片段、candidate key、decision（accepted / rejected / suppressed）、targetMemoryId?、policyVersion 和 changedAt。它是用户处置事实，不是可随索引重建删除的缓存。

撤销、拒绝或遗忘时同步写入 suppressed / rejected 决策。无法可靠定位单个断言时，保守阻止该来源继续自动提取；显式重新记住可解除相关抑制。去重与抑制在数据库提交时再次检查，避免两个后台任务同时通过预检查。

<a id="s19-07"></a>

### 1.7 Revision

同一 Memory 的文字和元数据修订进入 `MemoryRevision`：

```text
MemoryRevision
├── memoryId
├── revision
├── snapshot / changedFields
├── actor
├── sourceReference?
├── reason?
└── changedAt
```

<a id="s19-08"></a>

### 1.8 Evolution Relation

```text
KnowledgeRelation
├── id
├── fromKind             memory / note / entity / source
├── fromId
├── toKind
├── toId
├── kind                 replaces / enriches / confirms / challenges / relatedTo / dependsOn
├── state                proposed / confirmed / rejected / removed
├── origin               deterministic / user / agent
├── reason?
├── confidence?
├── createdAt
├── updatedAt
└── revision
```

方向统一为：

```text
新知识 ──relation──→ 被作用的旧知识
```

<a id="s19-09"></a>

### 1.9 Current Projection

关系是知识演化事实源，同时维护可重建投影：

```text
MemoryCurrentProjection
├── memoryId
├── isCurrent
├── supersededByMemoryId?
├── conflictState?
└── projectionRevision
```

确认 `replaces` 时，在同一数据库事务中：

1. 保存 Relation；
2. 更新 Current Projection；
3. 更新 FTS / Retrieval 可见性。

同一旧记忆收到第二条不相容替代时，新关系保留为 proposed，当前有效版本不变；用户解决前不提交成两个当前事实。确认替代要求同一主体、Scope 与兼容时间范围，禁止自引用和循环；跨范围演化必须由显式用例处理。

确认替代与用户手动语义修改共用同一事务。新 Memory 被移除后，已确认替代决定仍有效，不自动恢复旧版本。无正文的删除占位和替代决定可保留，Current Projection 根据这些规范事实重建。

<a id="s19-10"></a>

### 1.10 删除

- Archive：退出普通召回，保留来源；
- Remove：逻辑删除，保留恢复窗口；
- Forget：清理 Memory 正文、Evidence 摘录与派生副本，保存无正文的抑制与既有替代决定，不必删除原始 Conversation；
- Permanent Delete：按用户选择物理清理规范对象与无引用 Blob。

同一删除事务使 Memory 立即不可检索，并标记受影响 Snapshot / Compact / Working Memory / 搜索投影失效，取消以其为输入的未发送任务。后续清理 MemoryRevision、候选输出、Evidence 摘录、请求 / 模型输出正文和无引用 Blob；中断后 LocalJob 可继续，UI 显示清理状态。部分内容共处一个请求正文且无法可靠局部移除时，清理该请求的整段审计正文。

ExtractionDecision 的抑制元数据不保存被遗忘正文；保留必要来源 ID、定位和处置状态。保留原始消息 / Source 时，明确告知用户原文仍可通过显式历史查看访问，不能把“停止自动使用记忆”表述为原始文本也已删除。

<a id="s19-11"></a>

### 1.11 提取输入与提交条件

只在已提交来源上提取。输入包含有限的用户消息窗口和必要对话上下文，明确每段 speakerRole、消息 ID、版本和时间；Assistant 文字只帮助理解指代，不能作为用户已决定的证据。

候选必须引用输入中真实存在的用户摘录或 Source 片段。提交前检查原文版本、Scope、Sensitivity、当前设置、重复项和已确认 Memory；来源已变更、已删除、被抑制或策略不再允许时，丢弃结果或转为需复核，不能提交过期 Job 输出。

明确“记住”通过受保护的 `memory.remember` 工具或手动保存用例完成；参数没有可靠绑定当前用户明确意图时发出确认请求，不以模型声称“用户授权”作为依据。自动提取使用同一提交用例并执行自动记忆策略。相同来源的两个路径只能得到一条业务结果。

后台提取成功前，前台只可显示待处理状态。手动保存与 `memory.remember` 成功回执在事务后产生，模型只能依据该回执声称“已记住”。首版不允许工具直接写 SQL 或绕过 Evidence / Triage。

> **参考设计标注｜Nowledge Mem**  
> 借鉴 Atomic Memory、来源、Working Memory 和 `replaces / enriches / confirms / challenges` 类知识演化。Mira 使用分级自动 Active / Candidate 策略，并增加可重建 Current Projection，避免每次召回递归计算完整演化链。

---

<a id="s20"></a>

## 2. Project Context 与 Working Memory Architecture

<a id="s20-01"></a>

### 2.1 ProjectContextItem

```text
ProjectContextItem
├── id
├── workspaceId
├── kind                  instruction / goal / constraint / definition / architectureRule / reference
├── content?
├── targetReference?
├── inclusionMode         always / relevant / referenceOnly
├── state
├── createdBy             user / acceptedSuggestion
├── createdAt
├── updatedAt
├── revision
└── deletedAt?
```

规则：

- 用户直接修改；
- Mira 只能创建 Proposal；
- `referenceOnly` 大型资料不完整加入 Header；
- Project Context 当前快照变化时启动新 Prefix Series；
- 历史快照保存在 RequestSnapshot，不需要把旧版本永久追加到 Surface。

<a id="s20-02"></a>

### 2.2 WorkingMemoryPinnedItem

```text
WorkingMemoryPinnedItem
├── id
├── scope
├── workspaceId?
├── content / targetReference
├── createdBy
├── createdAt
├── updatedAt
└── revision
```

系统不能覆盖。

<a id="s20-03"></a>

### 2.3 WorkingMemorySnapshot

第一版为确定性投影：

```text
WorkingMemorySnapshot
├── scope
├── workspaceId?
├── sourceRevisionSet
├── activeDecisions[]
├── openTasks[]
├── upcomingSchedule[]
├── waitingExecutions[]
├── openQuestions[]
├── generatedAt
└── staleAt?
```

可在运行时生成或短期缓存，不作为长期知识事实。

LLM 摘要版本只有在确定性快照不足时再增加，并保留生成模型与来源版本。

---

<a id="s21"></a>

## 3. Knowledge Architecture

<a id="s21-01"></a>

### 3.1 规范对象

第一版规范对象保持有限：

```text
KnowledgeSource
SourceChunk
KnowledgeNote
KnowledgeLink
Entity
EntityMention
KnowledgeRelation
Tag
```

不把 Topic Community 和独立 Synthesis 状态机设为基础前提。

<a id="s21-02"></a>

### 3.2 KnowledgeSource

```text
KnowledgeSource
├── id
├── workspaceId?
├── kind                  markdown / pdf / webCapture / code / image / audio / video / conversationExport
├── title
├── canonicalURL?
├── currentVersionId?
├── importState           pending / ready / failed
├── createdAt
├── updatedAt
├── revision
└── deletedAt?
```

<a id="s21-03"></a>

### 3.3 SourceChunk

```text
SourceChunk
├── id
├── sourceId
├── sourceVersionId
├── sequence
├── locator               page / heading / line range / timestamp
├── text
├── contentHash
├── tokenEstimate
├── parserVersion
└── createdAt
```

Chunk 是检索单位，原 Source 是证据单位。Chunk 关联 `sourceVersionId`；一次解析产出的不可变版本绑定原 Blob、parserVersion 与 contentHash。重解析产生新版本和新 Chunk ID，在事务中切换 currentVersionId / 当前搜索可见性，旧引用不静默指向新内容。

定义最小 `KnowledgeSourceVersion`：id、sourceId、originalBlobId、contentHash、parserVersion?、parseState、createdAt。尚无有效解析版本时 currentVersionId 可空；解析失败保留原 Blob 和错误，不能把半成品 Chunk 标为当前成功版本。

Blob Hash、解析器与解析状态只在版本对象中定义，Source 不另维护可独立修改的同名事实。失败的新导入版本不覆盖已有成功的 currentVersionId；Source 列表可从版本派生展示摘要。

<a id="s21-04"></a>

### 3.4 Import Pipeline

```text
User-selected File / Capture
        ↓
Compute Content Hash
        ↓
Store or Reuse Blob
        ↓
Create KnowledgeSource
        ↓
Parse Text / Metadata
        ↓
Create SourceChunks
        ↓
FTS Index
        ↓
Optional Entity Mention / Memory Candidate
```

解析失败不丢失原文件。

MVP 采用显式选择单个或多个 Markdown 文件并导入快照，不做目录监听或外部 Vault 双向同步。同一 Workspace 内重复导入相同文件内容可复用现有 Source；用户明确替换已有 Source 才创建其新版本，不仅凭文件名相同覆盖。

初始边界为每个文件 10 MiB、每批最多 100 个文件、UTF-8（含 BOM），可配置调整；超限、二进制、无效编码与不支持格式给出明确结果。Markdown 的远程图片、HTML、Wiki Link 和 URL 默认不触发网络抓取或脚本执行。

解析和读取必须在授权资源内；跨范围符号链接、失效 Bookmark、文件读取中变化和路径替换必须检测并失败或重新授权。导入后的 Blob 属于 Mira 托管副本，原路径授权撤销不会假装已经删除托管副本；UI 分别提供撤销访问与删除导入资料。

The initial snapshot implementation retains no bookmark or continuing original-file access: access ends after import, so there is no retained grant to revoke. The UI explains this distinction and provides deletion of the managed source. Exact parser, search, tool, citation, and file-lifecycle contracts are in [Markdown knowledge implementation](KNOWLEDGE_IMPLEMENTATION.md).

<a id="s21-05"></a>

### 3.5 KnowledgeNote

```text
KnowledgeNote
├── id
├── workspaceId?
├── title
├── markdown
├── origin                user / generated
├── state                 draft / active / archived
├── createdAt
├── updatedAt
├── revision
└── deletedAt?
```

生成的多来源综合先保存为 Draft Note，并通过 EvidenceLink 关联来源。

<a id="s21-06"></a>

### 3.6 Wiki Link 与 Backlink

Markdown 中的 `[[Title]]` 解析为：

```text
KnowledgeLink
├── sourceNoteId
├── targetKind
├── targetId?
├── rawLabel
├── resolutionState
└── createdAt
```

Backlink 由 Link 反向查询，不复制到 Note 正文。

<a id="s21-07"></a>

### 3.7 Entity 与 Mention

```text
Entity
├── id
├── kind                  person / project / organization / product / technology / place / concept / event
├── canonicalName
├── aliases[]
├── state
├── createdAt
├── updatedAt
└── revision
```

Mention 可以自动创建；正式 Entity 提升条件：

- 用户创建；
- 稳定外部 ID；
- 多来源重复出现且低歧义；
- 已与多条 Memory / Note 建立关系；
- 用户确认高歧义候选。

只凭名称相同不得静默合并。

<a id="s21-08"></a>

### 3.8 Relation Trust

```text
deterministic + confirmed
来源于、属于、生成于、Wiki Link

user + confirmed
用户手动关系

agent + proposed
supports、dependsOn、relatedTo 等语义推断

high-impact + proposed
replaces、sourceOfTruth 等改变当前状态的关系
```

Proposed Relation 可以低权重参与探索，不参与事实裁决。

<a id="s21-09"></a>

### 3.9 Topic 与 Graph

- Topic 第一版使用 Tag、Entity、Saved Search 和可重建聚类；
- Graph View 从规范 Node / Relation 投影；
- 图布局、坐标、颜色和社区都可丢弃重建；
- 普通检索不依赖 Graph；
- Graph Selection Snapshot 只在对应交互真正实现时增加。

<a id="s21-10"></a>

### 3.10 Obsidian Interoperability

```text
SQLite / GRDB + Blob Store
规范事实源

Markdown Folder
导入、导出、备份和互操作投影
```

导出包含：

- Markdown；
- Wiki Link；
- YAML Frontmatter；
- 可读的 Memory / Source 引用；
- 原始附件目录。

不建立外部文件变更与 SQLite 的持续双向合并。

> **参考设计标注｜Obsidian / Nowledge Mem**  
> Obsidian 提供 Markdown、Wiki Link 和 Backlink 的用户心智；Nowledge Mem 提供 Source、Memory、Entity、演化和混合检索的参考。Mira 的简化是：关系使用 SQLite 普通表，Synthesis 先作为 Draft Note，Topic / Graph 高级分析是可选投影。
