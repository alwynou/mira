# 通用领域模型、本地存储与恢复

**文档版本：** v1.2  
**更新日期：** 2026-09-05  
**状态：** 设计基线；当前实现与验收范围见 [实施记录](../engineering/IMPLEMENTATION_STATUS.md)。

定义 ID、时间、修订、Typed JSON、Blob、事务、数据约束、LocalJob、备份与恢复；不定义版本排期。

返回 [ARCHITECTURE.md](../ARCHITECTURE.md) · 版本范围：[MVP](../MVP.md)

---

<a id="s08"></a>

## 1. 通用模型约定

<a id="s08-01"></a>

### 1.1 强类型 ID

Core 使用强类型包装：

```swift
struct ConversationID: Hashable, Codable, Sendable { let rawValue: UUID }
struct MessageID: Hashable, Codable, Sendable { let rawValue: UUID }
struct MemoryID: Hashable, Codable, Sendable { let rawValue: UUID }
```

不在业务 API 中混用裸 `String`。

<a id="s08-02"></a>

### 1.2 UUID 与 SQLite RowID

业务对象使用稳定 UUID，便于导出、引用和未来跨设备身份。

高频表允许同时使用内部整数 RowID：

```text
rowID       SQLite 内部局部性和 Join
id          业务稳定身份
sequence    Conversation / Execution 内明确排序
createdAt   时间展示与过滤
```

不依赖 UUID 字典序排序，也不强制当前切换 UUIDv7。

<a id="s08-03"></a>

### 1.3 时间

- 数据库存储统一使用 UTC；
- UI 按用户本地时区显示；
- 记录原始时区和时间精度；
- 模糊自然语言时间不能伪装为精确时间。

<a id="s08-04"></a>

### 1.4 Revision

规范可变对象维护单调递增 `revision`。

Revision 用于：

- 乐观并发检查；
- 变更历史；
- 派生索引失效；
- 未来同步兼容。

<a id="s08-05"></a>

### 1.5 Typed JSON

禁止 `[String: Any]`。

动态 Payload 使用：

```text
payloadType
payloadVersion
payload: JSONValue
```

解码策略：

1. 根据 `payloadType + payloadVersion` 选择 Decoder；
2. 支持逐版本迁移；
3. 未知新版本保留 Raw Payload；
4. 单条 Payload 解码失败不能阻止整个 Conversation 加载；
5. UI 显示 `Unsupported Payload`；
6. 可重建投影解码失败时可以丢弃并重建；
7. 规范业务数据失败时进入恢复流程，不能静默删除。

---

<a id="s23"></a>

## 2. Artifact 与 Blob Store

<a id="s23-01"></a>

### 2.1 Blob

```text
Blob
├── id
├── contentHash
├── byteSize
├── mimeType
├── storageRelativePath
├── encryptionState
├── createdAt
└── pendingDeletionAt?
```

路径示例：

```text
Blobs/ab/cd/<full-content-hash>
```

相同内容只存一份。

Blob 共享物理内容不共享访问权限。任何读取都从已获授权的 Message / Source / Artifact 引用解析，不能仅凭 contentHash 或 blobId 读取。相同 Blob 被不同 Scope 的对象引用时分别检查各对象策略。

<a id="s23-02"></a>

### 2.2 Attachment

Message 或 Source 对 Blob 的输入引用。

<a id="s23-03"></a>

### 2.3 Artifact

```text
Artifact
├── id
├── workspaceId?
├── title
├── kind
├── blobId?
├── textContent?
├── createdByExecutionId?
├── createdAt
├── updatedAt
├── revision
└── deletedAt?
```

<a id="s23-04"></a>

### 2.4 Large Tool Result Spill

大型 Tool Result：

- 原始内容进入 Blob；
- ToolInvocation 保存 Blob Reference；
- 模型只看到有界 Preview + Metadata；
- 后续可按需读取特定区间。

<a id="s23-05"></a>

### 2.5 Blob GC

`referenceCount` 不能作为删除权威。

流程：

```text
规范对象删除引用
        ↓
Blob 标记 pendingDeletionAt
        ↓
Grace Period
        ↓
扫描所有规范引用表
        ↓
无引用 → 删除文件与元数据
有引用 → 取消待删除
```

缓存型引用计数可以用于诊断，但不能单独触发物理删除。

<a id="s23-06"></a>

### 2.6 Blob 与数据库的一致提交

先在同一存储卷的临时路径写入完整内容，校验字节数与 SHA-256 并完成同步，再原子安装到目标路径；随后在数据库事务中提交 Blob 元数据及规范引用。数据库提交失败只留下可回收孤儿文件，不留下指向半文件的业务引用。

GC 默认宽限期 7 天。进入实际删除前，由 Data 层的维护互斥边界阻止该 Blob 新增引用并再次检查所有引用；不能只依赖 Actor 跨 await 的表面串行性。备份期间暂停 GC。崩溃后清理临时文件、扫描孤儿与缺失 Blob；缺失内容显示损坏并提供从备份恢复，不删除对应 Source 以掩盖问题。

Blob 引用覆盖附件、Source 各版本、Artifact、仍在保留期的请求 / 模型输出、工具结果和明确保留的 Evidence 内容。用户永久删除可跳过普通宽限期，但仍执行真实引用与保留范围检查。

---

<a id="s24"></a>

## 3. Local Data Architecture

<a id="s24-01"></a>

### 3.1 规范事实源

```text
Mira.sqlite
+
Blob Store
```

SQLite 保存结构化对象、正文文本、关系、Revision 和索引元数据；大型二进制文件保存在 Blob Store。

<a id="s24-02"></a>

### 3.2 GRDB 边界

`MiraData` 独占：

- DatabaseMigrator；
- GRDB Record；
- SQL；
- ValueObservation；
- Repository 实现；
- FTS 表；
- 事务。

Core 不导入 GRDB。

<a id="s24-03"></a>

### 3.3 逻辑表族

```text
Conversation
workspace, conversation, message, message_part

Runtime
execution, execution_step, model_call, tool_invocation, runtime_event, assistant_draft, request_snapshot

Memory
memory, memory_revision, evidence_link, knowledge_relation, memory_current_projection, extraction_decision

Knowledge
knowledge_source, knowledge_source_version, source_chunk, knowledge_note, knowledge_link, entity, entity_alias, entity_mention, tag

Structured Data
event_record, task, reminder, calendar_event, financial_transaction, record_revision, record_proposal, notification_delivery, external_projection_link

Content
blob, artifact, attachment_reference

Configuration
provider_connection, model_route, workspace_policy, file_access_grant, app_setting

Jobs
local_job, job_attempt

Index
fts_*, vector_metadata（未来）
```

<a id="s24-04"></a>

### 3.4 Transaction Boundaries

以下必须在同一事务内：

- User Message + Conversation sequence 更新 + queued Execution；
- Assistant Message 提交 + Draft 终止 + Execution 终态；
- Tool Result + ToolInvocation 状态；
- Memory + Evidence + ExtractionDecision + Current Projection + 必需 LocalJob；
- Confirmed `replaces` Relation + Current Projection + Retrieval 可见状态；
- Structured Record + RecordRevision + Evidence；
- Artifact / Source 与 Blob Reference。

远程网络调用不包在数据库事务中。

<a id="s24-05"></a>

### 3.5 WAL 与连接

基线：

- 使用 WAL 模式；
- 写入通过单一 DatabaseWriter；
- 读查询使用 DatabasePool 能力；
- 对长读取设定分页和取消；
- 定期执行合理 Checkpoint，不在 UI 主线程执行重维护。

<a id="s24-06"></a>

### 3.6 Migration

- 每次 Schema 变化使用命名 Migration；
- Migration 可重复测试从最老支持版本升级；
- 大数据迁移支持阶段化和进度；
- 失败时不删除原数据库；
- 可重建索引与规范数据迁移分开。

<a id="s24-07"></a>

### 3.7 不建设当前 Sync Journal

当前每次 Mutation 不额外写通用 ChangeJournal。

本地后台任务若需要 Outbox，只为具体任务建立最小 `local_job` 记录，不将其包装成未来同步日志。

<a id="s24-08"></a>

### 3.8 Backup 与恢复

- 取得明确的维护窗口：等待必要提交完成，暂停新写入、解析与 GC；使用 GRDB / SQLite 备份 API 生成一致数据库副本，不能只复制正在使用的 `.sqlite` 而忽略 WAL。
- 从数据库副本枚举实际 Blob 引用并复制，生成 manifest（formatVersion、schemaVersion、appVersion、对象计数、文件尺寸和 SHA-256）。全部验证完成后才将临时备份目录标记为可恢复。
- 最小恢复模式为恢复到空资料库或显式替换当前资料库，不做通用双向合并。替换前先成功备份当前数据。
- 在隔离临时目录校验 manifest、路径与尺寸上限、数据库 integrity / foreign_key_check 和 Blob Hash；拒绝路径穿越、符号链接逃逸及高于当前支持版本的 Schema。迁移与索引重建成功后才切换资料库；失败保留旧库。
- 恢复保留稳定 ID、来源版本与 ExtractionDecision。Credential 与操作系统文件授权不进入可移植备份；Provider Connection 恢复为待配置，外部 Bookmark 需重新选择。
- 恢复的未完成 Execution 进入 interrupted，LocalJob 进入 paused；不自动再次调用模型、发布 Apple 项目或安排通知。用户明确恢复所需能力后才继续。
- 已在本机排程的通知与 Apple 副本需先完成核对 / 停用，不能假定恢复数据库会撤销系统状态；不能确定时阻止自动重建外部副作用并显示恢复待处理状态。

<a id="s24-09"></a>

### 3.9 数据约束与索引最低要求

启用外键校验；所有业务写入在 Data 层落实 Domain 校验与必要 CHECK / UNIQUE 约束，不只依赖 ViewModel。最低包括：

- `message(conversationId, sequence)`、`runtime_event(executionId, sequence)` 唯一。
- 每个 Execution 的 Assistant Message 唯一；每个 Step 的 Attempt 序号唯一；每个 ModelCall 对应一个 RequestSnapshot。
- 同一 Conversation 活动 Execution 部分唯一索引；Memory Scope 与 workspaceId 的一致性。
- Memory / Source 引用带版本；Memory Candidate Key 和任务幂等键采用唯一约束或等价事务保护。
- `source_chunk(sourceVersionId, sequence)` 唯一；对象列表按 Scope / state / 更新时间索引，分页使用稳定 `(timestamp, id)` 游标。
- 变更使用 `expectedRevision`，冲突返回可恢复的 Conflict，不后写覆盖先写。
- 多态 EvidenceLink 无法只靠单一外键约束时，在同一事务验证目标 / 来源类型、存在性与版本，清理和完整性扫描也覆盖这些链接。

首批 Migration 与 MVP 支持的对象一同增加；实体图谱、财务和 Apple 表不提前建入 v0.1 Schema。FTS 失效时先根据规范对象 state / revision 过滤以防泄露，再后台重建，不能把陈旧索引当作授权事实。

<a id="s24-10"></a>

### 3.10 LocalJob：可靠处理的最小机制

`LocalJob` 保存 id、kind、sourceReference / revision、idempotencyKey、state（queued / running / retryWaiting / paused / completed / failed / cancelled）、attempt、availableAt、leaseOwner?、leaseExpiresAt?、policyVersion、lastError 和时间。JobAttempt 保存实际处理结果与 ModelCall 引用，不隐藏网络调用次数。

需要后台处理的业务变更与 queued Job 在同一事务写入。Worker 使用条件更新领取有期限的 lease，进程重启后处理过期 lease；完成前重新验证来源版本、删除 / 抑制决策与授权。MVP 同时最多一个后台远程处理 Job，前台优先。

确定性解析 / 索引可以幂等重试；远程调用按 Runtime 的可观测重试与计费规则。未知副作用或已收到部分响应不靠重新领取 lease 自动重放。暂停 / 关闭自动记忆立即阻止新调用，正在完成的输出提交前重新检查设置。

后台远程预算启用时必须有显式用途路线和每日 Token 上限；设置提供默认值但由用户保存启用。调度前预占输入估算、输出上限及重试额度，完成后按实际 Usage 对账；未知 Usage 保守消耗预占额，不能按零放行。价格缺失时不启动依赖金额硬上限的 Job，改用已配置 Token 限额或提示配置。应用预算不能保证 Provider 最终账单绝不超额。

> **参考设计标注｜SQLite / GRDB**  
> 采用 SQLite 作为应用文件格式、事务与 WAL；采用 GRDB 管理 Swift 数据访问、迁移与观察。规范数据和可重建索引分开，大型文件不塞入数据库正文列。

## 当前 v2 迁移

`m0_core` 保持已发布 SQL 不变；新增 `m2_execution_audit` 创建 execution_steps、model_attempts、tool_invocations。Step 序号从 1 开始，Attempt 请求身份与执行 / Step 外键一致，工具调用按模型顺序且原 Provider ID 唯一。ModelOutput 与整批提案原子提交；每个 ToolResult 通过 CAS 只终止一次。未知、拒绝、参数错误等可以在未 dispatch 时终止，不能伪造已成功执行。

恢复将遗留 Attempt 和工具终止；未调度调用标为 cancelledBeforeDispatch，已调度而结果未知的调用标为 interrupted。不会自动重新发送模型请求或工具写入。

备份恢复支持 v1 / v2。先复制到私有 staging，再按对应版本的精确 Schema、约束、迁移清单和 typed rows 验证；v1 仅在 staging 中迁移到 v2，成功后安装到未使用目录。v2 额外检查 ModelOutput 与每个工具提案的 ID、顺序、名称及参数一致。原备份不打开写连接，源 sidecar 不参与不可靠的主文件拼接；规范导出仍使用 SQLite Backup API。
