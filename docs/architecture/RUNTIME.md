# 对话执行、流式与工具运行时

**文档版本：** v1.2  
**更新日期：** 2026-09-05  
**状态：** 设计基线；当前实现与验收范围见 [实施记录](../engineering/IMPLEMENTATION_STATUS.md)。

定义 Conversation 持久化、Turn / Step / Attempt、工具交换、权限管线、状态机、取消、恢复与错误边界。

返回 [ARCHITECTURE.md](../ARCHITECTURE.md) · 版本范围：[MVP](../MVP.md)

---

<a id="s09"></a>

## 1. Conversation Domain Model

<a id="s09-01"></a>

### 1.1 Workspace

```text
Workspace
├── id
├── name
├── description?
├── state              active / archived
├── createdAt
├── updatedAt
├── revision
└── deletedAt?
```

Workspace 当前不嵌套。

<a id="s09-02"></a>

### 1.2 Conversation

```text
Conversation
├── id
├── workspaceId?
├── title
├── state              active / archived
├── createdAt
├── updatedAt
├── revision
├── lastMessageSequence
└── deletedAt?
```

Conversation 不直接保存巨大 Messages 数组。

<a id="s09-03"></a>

### 1.3 Message

```text
Message
├── id
├── conversationId
├── sequence            Int64，Conversation 内单调递增
├── role                user / assistant
├── status              committed / interrupted / failed
├── parts[]
├── executionId?
├── createdAt
├── updatedAt
├── revision
└── deletedAt?
```

System Prompt、Memory Injection 和 Tool Schema 不伪装成普通 Conversation Message；它们属于 Request Snapshot。

<a id="s09-04"></a>

### 1.4 MessagePart

```text
MessagePart
├── text
├── imageReference
├── fileReference
├── audioReference
├── artifactReference
└── structuredReference
```

MessagePart 是有序内容，不使用一个 `content: String` 覆盖全部多模态需求。

<a id="s09-05"></a>

### 1.5 Message 提交边界

用户消息先作为规范 Message 提交，再启动 Execution；两者的创建在同一事务完成，避免只有消息没有可追踪执行的空隙。

Assistant 流式输出先进入 AssistantDraft，完成或中断后原子提交为一个 Message。

<a id="s09-06"></a>

### 1.6 消息连续性与重试

- MVP 的已提交用户消息不提供历史原地编辑；纠正通过新消息表达。
- 每个 Execution 至多提交一条面向用户的 Assistant Message；工具步骤中的模型输出另存为 ModelOutput，不伪装成已完成回复。
- 显式重试创建新的 Execution，并记录 `retryOfExecutionId`，复用原 `triggerMessageId`。仅允许对没有后续用户消息的最后一个失败或中断回合重试；其他情况提示新建回合。
- 重试建立新的 Prefix Series。旧中断回复仍可在 UI / 审计中查看，但不与新回复一起作为成功 Assistant 历史注入。
- 用户选择继续一个中断回复时，新回合可带入明确标记的部分内容；这不是自动续传同一个模型请求。
- Conversation 移动 Workspace 前需终止活动 Execution；移动后刷新基线和隐私策略，既有 Memory 的 Scope 不随 Conversation 自动修改。

---

<a id="s10"></a>

## 2. Agent Runtime Domain Model

<a id="s10-01"></a>

### 2.1 Execution

```text
Execution
├── id
├── conversationId
├── triggerMessageId
├── state
│   ├── created
│   ├── queued
│   ├── running
│   ├── waitingForModel
│   ├── waitingForTool
│   ├── waitingForUser
│   ├── cancelling
│   ├── completed
│   ├── failed
│   ├── cancelled
│   └── interrupted
├── activeStepId?
├── startedAt?
├── completedAt?
├── terminalError?
├── retryOfExecutionId?
├── assistantMessageId?
├── configurationSnapshot
└── revision
```

一个 Execution 只能有一个终态。

<a id="s10-02"></a>

### 2.2 ExecutionStep

```text
ExecutionStep
├── id
├── executionId
├── sequence
├── state
├── latestModelCallId?    一个 Step 可以有多个有序 ModelCall Attempt
├── startedAt
├── completedAt?
└── error?
```

Step 是一次“构建请求 → 模型返回 → 处理 Tool Call 或最终输出”的边界。

创建 Attempt 时先分配 ModelCall ID，用它构建 ContextPlan；在同一事务保存 ModelCall、ContextPlan 与 RequestSnapshot 的对应关系，再发网络请求。发生构建错误时记录 Step 失败，不能保存一个声称已发送但实际上没有请求的成功调用。

<a id="s10-03"></a>

### 2.3 ModelCall

```text
ModelCall
├── id
├── executionId
├── stepId
├── attempt
├── requestSnapshotId
├── resolvedRouteSnapshot
├── state
├── startedAt
├── firstTokenAt?
├── completedAt?
├── finishReason?
├── inputTokens?
├── outputTokens?
├── cacheReadTokens?
├── cacheWriteTokens?
├── providerRequestId?
└── normalizedError?
```

<a id="s10-04"></a>

### 2.4 ToolInvocation

```text
ToolInvocation
├── id
├── executionId
├── stepId
├── modelOrder
├── toolId
├── providerToolCallId    Provider 协议 ID；与 Mira 内部 id 分开保存
├── arguments
├── state
├── sideEffect
├── idempotencyKey?
├── surfaceLifetime
│   ├── turnScoped
│   ├── conversationDurable
│   └── referenceOnly
├── startedAt?
├── completedAt?
├── resultReference?
└── error?
```

`surfaceLifetime` 决定结果如何进入后续模型请求：

- `turnScoped`：搜索、读取片段、临时状态；可用于同一 Turn 的后续 Step，不自动跨 Turn；
- `conversationDurable`：需要保持连续性的外部操作结果；
- `referenceOnly`：原始结果保存在 Blob / Execution，模型只看到摘要或引用。

<a id="s10-05"></a>

### 2.5 RuntimeEvent

```text
RuntimeEvent
├── id
├── executionId
├── sequence
├── type
├── timestamp
├── payloadType
├── payloadVersion
└── payload
```

基础事件：

```text
execution.started
step.started
request.built
model.started
model.delta
model.completed
model.failed
tool.proposed
tool.authorizationRequested
tool.started
tool.completed
tool.failed
assistant.draftUpdated
assistant.committed
execution.completed
execution.failed
execution.cancelled
execution.interrupted
```

RuntimeEvent 是执行审计日志，不取代规范 Message、ModelCall 和 ToolInvocation。`model.delta` 可以在内存事件流中发布，持久化时按内容块与 Draft Checkpoint 合并，不逐 Token 写数据库。

<a id="s10-06"></a>

### 2.6 AssistantDraft

```text
AssistantDraft
├── executionId
├── modelCallId
├── accumulatedParts
├── lastProviderSequence
├── state
├── updatedAt
└── checkpointRevision
```

流式期间定期保存 Draft Checkpoint，避免 App 崩溃后用户已看到的长回复全部丢失。

基线每 250 ms 或累计 4 KiB 文本保存一次，以先达到者为准；切换 Step、取消与正常终止时立即提交。恢复保证到最后一个已提交 Checkpoint，未落盘尾部可能丢失，UI 不声称逐 Token 零丢失。Token Delta 不是可通用于各 Provider 的网络续传游标。

<a id="s10-07"></a>

### 2.7 Agent Loop

```text
User Message committed
        ↓
Create Execution
        ↓
Resolve and Freeze Model Route / Capabilities / Policy
        ↓
Build ContextPlan + RequestSnapshot for this Attempt
        ↓
Stream Model Call
        ↓
Assemble Output
        ├── Final Assistant Output
        │       ↓
        │  Commit Message + Complete Execution
        │
        └── Tool Calls
                ↓
        Policy / Permission / Confirmation
                ↓
        Execute and persist Results
                ↓
        Next Step
```

停止条件：

- 模型返回最终输出；
- 模型要求等待用户；
- 用户取消；
- 不可重试错误；
- 达到 Step / Tool / Token / 费用 / 时间上限；
- Runtime 检测到重复循环或无进展。

<a id="s10-08"></a>

### 2.8 Turn、Step、Attempt 与并发边界

| 术语 | 精确定义 |
|---|---|
| Turn | 一条用户消息触发的一次 Agent 处理；当前由一个 Execution 表达，包含若干 Step |
| Step | 一次逻辑模型决策及其工具处理；工具完成后才开始下一 Step |
| Attempt | Step 中一次实际网络调用，即一个 ModelCall；重试产生新 ID 与新请求快照 |
| Request | Attempt 真正发送的输入；快照与 Provider、能力、预算同属该 Attempt |

同一 Conversation 最多一个非终态 Execution。以数据库部分唯一索引兜底，索引覆盖 created、queued、running、waitingForModel、waitingForTool、waitingForUser、cancelling；UI 禁用重复发送不是唯一防线。提交用户消息、增加 sequence、创建 queued Execution 必须原子完成。

AgentRuntime actor 管理多个 Execution 的状态，以 `executionId` 路由；不能将一个全局 `currentExecution` 用于全部 Conversation。不同 Conversation 受全局并发与 ProviderScheduler 限额，等待者显示 queued。

| 当前状态 | 允许的主要后继 |
|---|---|
| created | queued、cancelled、failed |
| queued | running、cancelled、failed |
| running | waitingForModel、waitingForTool、waitingForUser、completed、cancelling、failed |
| waitingForModel | running、cancelling、failed |
| waitingForTool | running、waitingForUser、cancelling、failed |
| waitingForUser | running、cancelling、failed |
| cancelling | cancelled；副作用不确定时为 interrupted |
| completed / failed / cancelled / interrupted | 无；显式重试创建新的 Execution |

进程恢复可将任一遗留非终态转为 interrupted。终态写入采用条件更新与事务，取消、模型完成和超时竞态只能有一个胜出者；迟到事件仅作为已脱敏观察，不重新开启执行。

<a id="s10-09"></a>

### 2.9 ModelOutput 与 Turn 内工具交换

保存每个 ModelCall 的有序 ModelOutput：文本块、工具调用块、停止原因及 Adapter 所需的继续处理引用。Provider 专属签名或不透明续接数据存入由 Adapter 解释的受保护 Blob，Core 只持有带 Adapter ID / Version 的引用，不解析厂商 JSON。

一个完整工具交换包含：发起调用的模型输出 + 其中每个调用的终止结果，结果引用原 Provider Tool Call ID。同一批存在未完成工具时不能发送下一次模型请求。不存在工具、参数非法、被拒绝和未调度取消也返回对应的结构化结果。

同一 Turn 内按模型顺序累积交换，保留协议要求的完整配对。大型结果从首次返回起就使用有界 Preview / Reference；不能单独删除调用或结果来节约预算。无法容纳当前必需交换时，结束为可解释的预算错误，不发送不完整协议。

下一 Turn 只保留明确 `conversationDurable` 的语义操作回执，标记工具观察和来源；第一版将其渲染为带来源的普通观察内容，不遗留孤立的 `tool` / `tool_result` 消息。当前用户消息在请求中恰好出现一次，Durable History 查询截止于它之前。

> **参考设计标注｜DeepSeek Harness Agent Loop**  
> 借鉴其 Turn / Step 生命周期、模型输出与工具结果先持久化后进入下一 Step、并行安全工具与独占屏障。Mira 使用 Swift Actor 和明确组件，不采用动态 Cordis 插件生命周期。

---

<a id="s11"></a>

## 3. Canonical Streaming Protocol（规范流式协议）

Provider Adapter 将不同厂商事件转换为统一事件：

```text
stream.started
contentBlock.started
text.delta
reasoning.delta          可选，仅内部或用户允许时
image.reference          可选
toolCall.started
toolCall.argumentsDelta
toolCall.completed
usage.updated
stream.completed
stream.failed
```

<a id="s11-01"></a>

### 3.1 Block Assembler

Assembler 负责：

- 按 Provider 顺序组装文本；
- 组装 Tool Call 参数；
- 验证 Tool Call ID 唯一；
- 处理重复或乱序 Delta；
- 生成 AssistantDraft；
- 确保每次 Attempt 只有一个 Terminal Finish。

<a id="s11-02"></a>

### 3.2 Adapter 不能隐藏 Retry

Adapter 只负责：

- 请求转换；
- 流事件转换；
- 错误规范化；
- 解析 `retryAfter`；
- 能力差异处理。

Retry 决策由 Runtime Retry Policy 完成并记录 Attempt。

<a id="s11-03"></a>

### 3.3 取消

取消时：

- 停止网络请求；
- 保留用户已经看到的 Assistant 前缀；
- 将 Draft 提交为 `interrupted` Message，或明确丢弃；
- 尚未调度的 Tool Call 生成 `cancelledBeforeDispatch` 结果；
- Execution 进入唯一终态。

---

<a id="s12"></a>

## 4. Tool System

<a id="s12-01"></a>

### 4.1 Capability、Permission 与 Policy

```text
Capability
宿主是否具备能力

OS Permission
系统是否授权当前 App 使用

Tool Policy
当前用户是否允许 Agent 在此范围执行
```

三者不可合并。

<a id="s12-02"></a>

### 4.2 ToolDescriptor

```text
ToolDescriptor
├── id
├── schemaVersion
├── displayName
├── description
├── inputSchema
├── outputSchema?
├── sideEffect           none / read / write / destructive
├── executionMode        parallelSafe / exclusive / ordered
├── confirmationPolicy
├── permissionScope
├── supportsCancellation
├── idempotencyMode
├── timeoutPolicy
└── resultLifetimeDefault
```

<a id="s12-03"></a>

### 4.3 Tool Registry

Tool 由 Composition Root 按当前 Host 能力注册。

Registry 使用稳定 Tool ID 和确定性排序。一次 Agent Turn 内可见 Tool Set 冻结，避免 Step 之间随机重排 Schema 破坏缓存和可重建性。

<a id="s12-04"></a>

### 4.4 Guarded Tool Pipeline

```text
Model Tool Proposal
        ↓
Tool Exists / Visible
        ↓
Argument Decode / Schema / Concrete Target Validation
        ↓
Capability Available
        ↓
OS Permission
        ↓
Mira Tool Policy
        ↓
User Confirmation（需要时）
        ↓
Revalidate Policy / Target Revision Immediately Before Dispatch
        ↓
Idempotency / Retry Check
        ↓
Execute
        ↓
Result Validation
        ↓
Persist Result / Blob Spill
        ↓
Create Model Observation
```

每个拒绝或失败都产生结构化结果，不能只抛 `Unknown Error`。

确认必须绑定 executionId、invocationId、参数 Hash、具体目标、目标 Revision、权限范围与有效期；参数或目标变化后重新确认。操作从只读转为写入时，旧授权不可复用。模型输出的 `approved: true`、Tool Result 或外部文档不能创建授权。

搜索工具在 Repository 查询阶段应用 Scope 与可发送性过滤，在结果渲染阶段再次验证；不先把所有 Workspace 正文交给模型再要求它自觉筛选。所有对象 get / open 与 Blob 读取同样检查调用上下文，不能通过猜测 ID 绕过搜索过滤。

<a id="s12-05"></a>

### 4.5 并行与屏障

```text
parallelSafe
只读、互不依赖、可重叠执行

exclusive
写入、Shell、自动化、共享资源副作用；单独执行

ordered
依赖前一调用结果；严格按模型顺序
```

模型一次返回多个 Tool Call 不等于自动全部并行。

结果传回模型时保持 `modelOrder`，即使真实完成顺序不同。

<a id="s12-06"></a>

### 4.6 UI Request

需要用户参与的交互通过 UI Request：

```text
pickFile
pickDirectory
requestPermission
confirmTool
signInProvider
chooseCalendar
shareArtifact
```

Core 发出语义请求，Host 决定如何展示。

> **参考设计标注｜DeepSeek Harness Tools**  
> 借鉴固定 Guarded Pipeline、allow / deny / ask、并行安全与独占工具的思想。Mira 额外区分 Tool Result 的上下文寿命，避免检索结果永久污染个人助理 Conversation。

---

<a id="s13"></a>

## 5. Retry、Cancellation 与 Crash Recovery

<a id="s13-01"></a>

### 5.1 Model Retry

可自动重试：

- 明确的临时网络错误；
- Provider 返回可重试限流；
- 尚未收到任何可见输出且请求幂等；
- 用户配置允许。

不可静默重试：

- 已产生可能计费但状态不明的请求，且 Provider 无幂等语义；
- 已经展示大量输出；
- 需要切换 Provider；
- 可能重复执行 Tool 副作用。

<a id="s13-02"></a>

### 5.2 Tool Retry

ToolDescriptor 声明：

```text
notRetryable
idempotent
idempotentWithKey
requiresUserDecision
```

写入和 destructive Tool 默认不自动重试。

<a id="s13-03"></a>

### 5.3 Cancellation Token

Execution、ModelCall、ToolInvocation 和 LocalJob 使用明确 Cancellation Token。

UI Task 取消不自动等于业务 Execution 取消；用户必须通过 Use Case 发出取消命令。

<a id="s13-04"></a>

### 5.4 Crash Recovery

App 启动后扫描非终态 Execution：

```text
安全恢复
→ 恢复等待中的确定性本地步骤

状态不确定
→ Execution 标记 interrupted，要求用户决定重试

外部副作用可能已发生
→ 禁止自动重放，先检查或提示用户
```

任何 Execution 都不能永久停留在 `running`。

恢复前先处理活动 Draft 与可能的外部副作用。MVP 不恢复网络流或自动重放整轮 Agent；确定性的索引、已授权资料解析等可由独立 LocalJob 重试。删除 / 禁用 Provider 或撤销文件权限后，等待中的操作重新验证，不继承失效授权。

---

<a id="s30"></a>

## 6. Error Boundary

基础错误域：

```text
DomainError
ValidationError
PersistenceError
MigrationError
ProviderError
ModelCapabilityError
ToolError
PermissionError
UIRequestError
ContextBuildError
CompactError
MemoryExtractionError
SearchError
AppleProjectionError
CancellationError
```

规范错误：

```text
ErrorRecord
├── domain
├── stableCode
├── userMessage
├── debugMessage?
├── retryable
├── suggestedAction?
├── underlyingCode?
├── occurredAt
└── redactedMetadata
```

UI 不直接展示厂商原始错误栈；Inspector 可以显示已脱敏技术详情。

---

<a id="execution-limits"></a>

## 7. 初始执行限额

以下是可配置的初始工程默认，不是产品不变量；质量验证采用 Fake Clock 测超时，避免测试真实等待。

| 限额 | 初始默认 |
|---|---|
| 同时活跃的前台 Execution | 全局最多 2；同一 Conversation 仍最多 1 |
| 单 Turn 模型决策 Step | 20 |
| 单 Turn 工具调用总数 | 32 |
| 并行安全工具数 | 4；写入、独占与有序调用仍按屏障运行 |
| 单 Attempt 首响应超时 | 60 秒 |
| 流式事件空闲超时 | 90 秒；连接心跳不等同于模型进展 |
| 单 Turn 活动执行时长 | 20 分钟；等待用户确认不计入活动时长 |
| 同一路线无可见输出的自动网络重试 | 最多 2 次，遵守 retryAfter 与总预算 |
| 单工具参数正文 | 64 KiB；超过上限返回可解释验证错误 |

工具 Preview、搜索数量和来源读取上限由各 Tool Schema 进一步限定；不能只限制工具次数而允许一次读入无限内容。达到限额终止为明确错误，保留已提交内容；无进展检测结合重复调用参数与结果 Hash，不把合法重复读取一律当作循环。

Mira Runtime 负责全局并发，ProviderScheduler 可以按连接限速进一步降低并发。等待用户的确认绑定目标版本与执行身份；应用重启后不自动批准旧确认。

## 8. 当前 M2 实现契约

- Host 注入不可变 `ToolRegistry`，定义按工具 ID 排序。生产注册表目前为空；测试专用工具通过构造参数注入，不自动进入真实对话。默认写入工具拒绝授权。
- `CanonicalStreamEvent.toolCalls` 只携带完整的一批调用，且与 `finished(toolCalls)` 配对。Adapter 在原始 JSON 语法损坏时终止流；参数 Schema 不符合、未知工具、权限拒绝等由运行时保存结构化 ToolResult。
- 工具输入采用受限 JSON Schema 子集（object / string / number / integer / boolean / 有界 array），不支持的 Schema 在注册时失败。对象必须禁止额外字段。参数最多 64 KiB，单个工具结果默认 32 KiB、最多 64 KiB。
- 相邻 parallelSafe 调用最多 4 个并发；exclusive / ordered 在前批全部完成后单独执行。真实完成顺序不改变写回模型的 modelOrder。授权与执行均须协作取消；工具写入 Use Case 还需在自身提交事务中重新核对目标版本并按 invocation ID 去重。
- 一个 Execution 代表一个 Turn。每次网络调用具有独立 Step / Attempt / dispatch ID，请求、输出与全部工具提案 / 回执先落盘，后续请求再使用完整交换。当前不自动重试网络请求；显式失败回合重试创建新 Execution。
- 除表中 Step / Tool / 时间限额外，当前每 Turn 累计预留输出最多 32,768 Token；未知 Usage 保持未知，不用实际返回量代替发送前预留。连续三批工具名称、规范化参数与结果完全相同会停止为无进展错误。
- 输入预算使用 UTF-8 与协议开销的保守估算。新请求无法容纳完整工具交换时，在 dispatch 前失败。当前仅活跃回合保留工具协议，下一用户回合只读取已提交普通消息。
- 聚合 Execution 状态目前沿用 queued / waitingForModel 与终态；工具的排队、执行、拒绝状态由审计记录展示。Context 构建失败记录在 Execution；独立的构建失败 Step、自动 Attempt 重试、人工确认 UI 和更完整 ModelOutput Typed Parts 后续逐项补齐，未注册依赖这些能力的生产工具。

本节是当前实现与前文完整设计的对应，不代替 [实际验收记录](../engineering/IMPLEMENTATION_STATUS.md)。


## First-class thinking

The [thinking contract](THINKING.md) adds separate stream snapshots, ordered assistant/tool traces and provider-specific replay data to the existing runtime. Thinking-only drafts participate in checkpoint, cancellation, recovery and terminal uniqueness. The current tool-use turn freezes its base request so signed provider state can be replayed without prefix changes. Authorization continues to run before every dispatch.
