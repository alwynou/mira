# 模型服务商接口与路由

**文档版本：** v1.2  
**更新日期：** 2026-09-05  
**状态：** 新核心的生产 HTTP 适配器已直接采用下述 Agent 契约；开放设置描述、持久配置和路线选择已有[新配置契约](AGENT_MODEL_CONFIGURATION.md)，发现与原生宿主正在整体切换，阶段证据见[核心验证记录](../engineering/AGENT_CORE_VERIFICATION.md)。原生产品此前的配置验收见[实施记录](../engineering/IMPLEMENTATION_STATUS.md)。

定义 Provider 契约、路线解析、冻结与重试边界、协议兼容性、端点安全、能力和用量。

返回 [ARCHITECTURE.md](../ARCHITECTURE.md) · 版本范围：[MVP](../MVP.md)

---

<a id="s14"></a>

## 1. Model Provider Architecture

<a id="s14-01"></a>

### 1.1 核心对象

#### ProviderAdapter

某类接口协议的 Swift 实现。

#### ProviderConnection

用户配置的一组：

- Adapter 类型；
- Base URL；
- Credential Reference；
- 自定义 Header（敏感值仍通过安全引用）；
- 连接级设置。

#### ModelDescriptor

模型能力描述：

- Model ID；
- Context Window；
- Tool Call；
- Vision；
- Audio；
- Structured Output；
- Reasoning；
- Tokenizer / Estimator；
- 能力来源和观测状态。

#### ModelRoute

某种用途对应的 Connection + Model + 参数。

#### AgentModelRoute

某次 ModelCall 最终冻结的路线，记录：

- Connection ID；
- Connection Revision、规范 Base URL / origin、Credential Reference 与凭据版本（不含凭据值）；
- Model ID；
- Adapter Version；
- 适配器拥有的不透明配置；
- 能力快照；
- 输入窗口和输出预留。

价格目录和用户选择记录由配置／用量领域拥有，不是驱动器选择协议的依据。当前 HTTP 配置格式和厂商规则位于 MiraProviders，具体约束见[HTTP 适配器契约](AGENT_HTTP_ADAPTER.md)。

<a id="s14-02"></a>

### 1.2 Agent Model Adapter

Core 使用统一协议：

```swift
protocol AgentModelAdapter: Sendable {
    var identity: AgentAdapterIdentity { get }
    func prepare(_ input: AgentModelInput, route: AgentModelRoute) throws -> AgentPreparedModelRequest
    func stream(_ request: AgentPreparedModelRequest, route: AgentModelRoute) -> AgentModelOperation
    func replay(_ messages: [AgentModelMessage], from source: AgentModelRoute,
                to target: AgentModelRoute, boundary: AgentReplayBoundary) throws -> AgentReplayDecision
}
```

核心负责身份、预算、来源授权和持久化；适配器私有 JSON 作为不透明值保留，核心不解释厂商字段。准备没有副作用，持久化请求后才能执行。`AgentModelOperation.close()` 必须取消并排空实际生产者，不能只结束事件流。适配器通过模块注册，不需要在核心增加厂商枚举分支。

<a id="s14-03"></a>

### 1.3 Model Discovery

能力优先级：

```text
用户明确覆盖
    ↓
端点实时发现
    ↓
Mira 内置静态目录
    ↓
保守未知能力
```

用户可以手工输入 Model ID。Mira 无法验证时显示警告，不阻止使用。

<a id="s14-04"></a>

### 1.4 Route Resolution

解析顺序：

```text
本次用户显式选择
        ↓
Conversation / Agent Profile 覆盖
        ↓
Workspace 用途级设置
        ↓
全局用途级 ModelRoute
        ↓
用户显式配置的 Fallback Chain
```

在路线解析前应用 Workspace Provider Policy，禁止将不允许的本地数据发送给候选 Provider。

<a id="s14-05"></a>

### 1.5 Turn 内冻结

一次 Agent Turn 的主对话路线固定。Memory Extraction、Compact、Embedding 等独立 Job 可以使用各自用途 Route。

Connection 配置不能仅按 ID 在每个 Step 重新读取为另一套端点或模型参数。运行中的请求使用冻结的非秘密配置；用户撤销、删除连接或轮换凭据时，后续发送检查版本并暂停 / 终止失效执行。Request dispatch reads keys from secure storage and never bypasses a revoked version through an old reference. The settings editor may also read the saved key into its session-scoped secure input, without persisting another copy.

<a id="s14-06"></a>

### 1.6 Fallback

- 同 Provider 同模型重试：按 Retry Policy；
- 同 Provider 换模型：必须预配置；
- 跨 Provider：默认禁止，必须显式授权；
- 后台任务不能弹出阻塞式跨 Provider 确认，未预授权则失败或暂停。

Fallback Chain 只用于开始 Turn 前的路线选择；选定并发起首个请求后，不在当前 Execution 内换模型或 Provider。同一路线的网络重试保持其冻结配置。若确需使用预授权替代路线，先终止原 Execution，再由用户启动新的执行，记录关联并重新构建上下文和发送策略。

<a id="s14-07"></a>

### 1.7 Provider Scheduler

按以下键管理限流：

```text
ProviderConnectionID
+
CredentialReference
+
必要时 ModelID
```

优先级：

```text
前台用户请求
    ↓
用户主动批量任务
    ↓
Memory / Knowledge 后台任务
```

<a id="s14-08"></a>

### 1.8 Usage 与成本

The current implementation contract, cache counter semantics, frozen pricing, and supported estimate range are defined in [Usage and cost](USAGE_AND_COST.md).

规范 Usage：

```text
inputTokens
outputTokens
cacheReadTokens?
cacheWriteTokens?
reasoningTokens?
providerReportedCost?
estimatedCost?
```

估算记录价格版本与生效时间，不当作服务商最终账单。

<a id="s14-09"></a>

### 1.9 首批协议与能力验收

| Adapter | 最低协议范围 | 验收能力 |
|---|---|---|
| OpenAIChatCompletionsCompatible | 用户 Base URL 下的 `/chat/completions`，可选 `/models` | 文本 SSE、function tools、Tool Call ID、取消、错误与可选 Usage |
| AnthropicMessages | `/v1/messages`，明确 `anthropic-version` | 文本 content blocks、tool_use / tool_result、SSE、取消与 Usage |

Chat Completions 兼容不等于 OpenAI Responses 兼容；需要另一协议的模型显示不受支持，不静默转换或换模型。Responses、OAuth、Provider 托管工具及音视频不在当前实现范围。已有 thinking 协议必须完整保留，不能关闭 thinking 来掩盖不完整适配；具体边界见 [Thinking](THINKING.md)。

能力分别记录 `unknown / declared / verified / failed` 与验证时间：普通文本、流式、工具、结构化提取、上下文窗口和 Usage。聊天能力通过不自动启用 Agent 或自动记忆。无法确定窗口时要求用户填写有效上限；手工 Model ID 可保存，但受影响的执行用途在能力满足前不可启动。

The current `ModelDescriptor.toolCapability` is a required state initialized to `unknown`. Capability declarations and probe observations are tagged with the connection revision. Editing the endpoint, protocol, credential, or local-HTTP permission makes prior capabilities unknown for sending until reconfirmed or probed again; cancelled or stale probes do not overwrite current configuration.

首版提取采用有限 JSON Schema 子集和确定性本地校验。支持 strict schema 的端点可使用该能力；其他端点可请求 JSON 文本，最多进行一次修复调用并计费，仍无效则保留失败记录，不写 Memory。模型自报置信度不替代发言归属、范围和来源校验。

端点保存 API 根路径，Adapter 以路径组件拼接，避免重复 `/v1`。默认 HTTPS；仅用户明确配置的 loopback 本地端点允许 HTTP。跨 origin 重定向不携带凭据；禁止自动跟随到未授权主机。凭据不出现在 URL、错误正文或诊断导出中。连接测试只发送固定合成文本，不发送本地业务内容。

<a id="s14-10"></a>

### 1.10 流式和用量失败语义

SSE Parser 按字节增量解码 UTF-8，支持跨网络块拆分、多行 data、心跳与未知可忽略事件；对单事件、工具参数和总响应设置上限。只有完整参数通过 Schema 校验且模型给出可解释终止状态后才调度工具。连接 EOF 不等于正常完成。

区分正常完成、工具调用、输出上限、拒绝、协议错误和传输中断。达到输出上限的部分 JSON 不执行工具；文本可以作为 interrupted Message 展示。重复终态不能重复结算 Usage 或提交 Message。

缺少 Usage 或缓存 Token 时保存 unknown / null，不能填 0。累计 Usage 事件按该 Adapter 定义归一化，不逐事件相加；价格缺失时仅展示 Token 与估算未知。后台预算按实际 ModelCall ID 结算，跨午夜重试仍归入各自实际调用时间。

> **参考设计标注｜DeepSeek Harness LLM Layer**  
> 借鉴 Provider-neutral Message / Stream Contract 与 Adapter 负责 Wire Protocol 的边界。Mira 不要求采用其包结构，也不允许 Adapter 隐藏 Retry。

## 2. 当前能力探测与工具编码

### Current Responses tool contract

The Responses adapter sends function tools with explicit `strict: false`, preserving the domain schemas' distinction between an omitted optional field and a supplied value. Mira validates arguments locally before dispatch. Omitting `strict` allows Responses to normalize schemas into strict mode, whose required-field/null conventions differ from Mira's bounded schema subset. See the [official function calling guide](https://developers.openai.com/api/docs/guides/function-calling#strict-mode).

Terminal response items may omit `status` after their matching `response.output_item.done` boundary. Any supplied terminal or cached item status must remain valid for the response's completion state; missing done boundaries, non-string statuses, and contradictory incomplete/failed statuses are rejected. An SSE `error` or `response.failed` becomes the existing privacy-safe provider rejection, without retaining raw provider error content. Reasoning, tool identities, and continuation items remain intact. Focused evidence is in [tool verification](../engineering/TOOL_VERIFICATION.md).

设置只在用户主动点击后发起合成探测。文本探测要求非空文本、stop 与完整流终止；工具探测要求单个 `probe.echo` 调用和固定参数对象，接受 Provider 生成的非空调用 ID 与等价 JSON 排版，不运行工具副作用。成功与失败只改变被测能力；取消不改能力。结果回写核对冻结配置与修订，配置变更后旧结果不得覆盖。真实模型 / 窗口、用量、计费和其他能力不从一次探测推断。

内部工具名如 `memory.search` 编码为兼容的 wire 名 `memory_search`，在注册时拒绝映射冲突。OpenAI 使用 function tools / tool_calls / tool messages；Anthropic 使用 tool_use 与连续同批 tool_result blocks。完整调用参数经过 JSON 对象语法验证才交给 Runtime；Runtime 再进行 Schema 与权限检查。

取消使用每次调用独立的 `HTTPTransportOperation` 关闭句柄，绑定实际 URLSession task；步骤 ID Header 只用于关联，不能用于查找待取消任务。Capability 缺失时不携带工具；Adapter 在读取凭据前检查工具历史配对与能力。thinking 和 signed continuation 作为不透明数据保留，格式与重放判断属于适配器。


## 切换前配置领域与宿主

以下描述仍待直接替换的配置／宿主调用方。它们尚未接入新 Agent 核心；`HTTPModelProvider` 已删除，不提供旧 `ModelProviderPort` 包装器，中间阶段宿主不能作为可运行产品验收。整体切换将删除旧的快照和执行权威路径。

`ProviderConnection` owns a shared protocol, endpoint, and immutable Keychain reference/version. `ModelDescriptor` owns the model ID, window, capabilities, and the connection revision those observations describe. `ModelRoute` is a named preset selecting a descriptor plus output and usage parameters. `RouteBinding` selects a preset for a purpose at Global, Workspace, or Conversation scope.

The current purposes are conversation and memory extraction. Other purposes are introduced only with their features. Resolution is explicit selection, Conversation override, Workspace default, then Global default. A missing or forbidden selected route fails; resolution does not silently select a lower-priority route. Workspace sending policy and optional connection allowlist apply to every candidate, including explicit selections.

The execution stores a self-contained `ResolvedModelRouteSnapshot`, including connection/model/route revisions, credential reference/version, capability snapshot, protocol adapter version, and selection source. Later edits never rewrite historical snapshots. Configuration edits or revocation stop affected live executions; each dispatch also revalidates the frozen configuration and current workspace policy. Binding edits affect subsequent executions, not a running turn.

Connection deletion removes its live models, presets, and bindings. Execution snapshots remain readable. Credential cleanup retains references from live connections, so a shared connection is not removed merely because one route preset is deleted. Probe results commit through the application actor and compare frozen revisions before writing.

## 3. Provider activation and the model pool

`ProviderConnection.isEnabled` and `ModelDescriptor.isEnabled` are independent, required stored fields with checked SQLite mirrors. Schema v9 directly replaces the development schema; earlier libraries and backup formats are rejected intact. Host-created connections saved with Save start inactive. Enabling a provider persists the enabled state after local validation and a nonempty entered or stored credential is available; it does not probe the network or require a selected test model. A bad credential is discovered by an explicit Test action or the first model request. Enabling a provider never enables its model descriptors. Under the current model configuration contract, it may initialize an absent conversation binding from models already enabled in its canonical pool; it never assigns a memory-extraction binding.

`ModelDescriptor.poolRouteID` uses the descriptor UUID in the route ID domain. `savePoolModel` saves the descriptor and its canonical `ModelRoute` in one transaction with revision checks for both records. A conflicting route update rolls back the descriptor update. Model IDs are unique within a connection. Model pool queries require an enabled descriptor, enabled parent, and an actually persisted matching canonical route; they never invent missing routes. Other internal route APIs retain explicit snapshot and binding semantics.

The application cancels affected foreground work and invalidates background extraction after configuration mutations. Resolution rejects disabled components, including explicit or inherited stale selections, without trying another candidate. Saved bindings remain until explicitly changed or removed. No-op saves and display-name/activation-only provider edits advance matching model attestations transactionally without upgrading already-stale observations; endpoint/protocol/credential changes still require reconfirmation. Old frozen snapshots cannot acquire new authority through the activation update.

`ProviderModelDiscoveryPort` returns transient model IDs and optional display names; `HTTPModelDiscovery` implements explicit GET requests for the configured OpenAI-compatible or Anthropic model endpoint. Discovery reads no conversation or memory and does not persist results, infer verified capabilities, or make a generation request. The host verifies the connection again after the request and discards results when selection/configuration changes. Cancellation is owned by the presentation model and propagated to the transport.

Limits are 2 MiB per page, 8 MiB total, 2,000 distinct models, 10 Anthropic pages, and a 30-second operation deadline. Exceeding a bound fails the operation without presenting a partial list. Endpoints retain their configured base prefix; Anthropic pagination stays on the same model endpoint. Transport redirects are rejected, credentials remain headers, and remote error bodies never become user-visible diagnostics. Failed discovery leaves manual entry and existing models available.

The interaction reference is LobeHub's [provider enable switch](https://github.com/lobehub/lobehub/blob/main/src/features/Settings/provider/features/ProviderConfig/EnableSwitch.tsx), [per-provider model list](https://github.com/lobehub/lobehub/blob/main/src/features/Settings/provider/features/ModelList/index.tsx), and [model selector](https://github.com/lobehub/lobehub/blob/main/src/features/ModelSelect/index.tsx). Mira implements its own native flow and preserves its explicit background authorization and fail-closed route semantics.


## 4. Model metadata and selection requirements

The [model catalog contract](MODEL_CATALOG.md) defines bundled models.dev references, exact endpoint/model matching, thinking controls and continuation and purpose eligibility. `ModelDescriptor` and frozen snapshots now carry independent extraction capability, protocol mode and an optional applied catalog reference. Schema v10 adds route thinking settings and durable assistant traces; v9 and earlier libraries are rejected intact. See [thinking and provider continuation](THINKING.md).

`ModelConfiguration.modelPool` remains the management query. `models(for:)` returns ready candidates for conversation, Agent tools or memory extraction; route resolution and provider dispatch enforce the same send gates. JSON extraction uses a bounded synthetic JSON-text probe and updates only its own capability through the existing frozen-revision commit check. Text/tool tests cannot certify extraction or restore stale unrelated capabilities.

## 5. Explicit connection checks and activation

The macOS configuration presentation model owns a cancellable operation and the draft key, endpoint, and selected test model. It selects the first eligible saved or bundled text model by default and allows another model to be selected. Keychain remains the only persistent credential store. The settings session reads the saved key into its native secure input and keeps the saved value and replacement draft in presentation memory until the window closes. The untitled provider form exposes only key, base/proxy URL, and test controls; protocol and loopback authorization remain the selected template or existing connection values. Arbitrary HTTP endpoints do not become authorized by entering an address. An unmatched custom endpoint can use manually configured text models, including while its connection is inactive.

Saved keys and replacement drafts use the same populated secure field, never a fake placeholder. The model compares the draft against its saved value and passes an empty replacement to the save/test boundary when unchanged, preventing unnecessary credential-version rotation. An empty draft also reuses the saved key. Provider editors, selected models and drafts remain scoped to the open settings session across category/provider navigation; closing settings cancels transient requests and releases all key values from the editors. Provider cards select local detail state without starting requests. Discovery success updates the transient model list without a success banner; empty results and failures remain visible inline.

The provider page reads `MiraApplication.modelConfiguration()` without enumerating workspaces or conversations. The Models purpose-routing page requests those scopes separately. A selected connection editor owns its draft above the lazy model rows; row disappearance must not trigger cancellation or credential cleanup. Unchanged connection/configuration snapshots reuse their prepared test candidates, while changed snapshots rebuild and fully validate eligibility. Actual testing, activation, saving and sending retain their existing revision and validation checks.

`AppContainer.saveConnection` performs local validation and persists a connection's requested enabled state without a network test or test-model selection. An empty-key enable attempt remains interactive but performs no save: it exposes required-field feedback and focuses the secure input. Enabling requires a nonempty entered or stored credential; a bad credential is reported by the standalone Test action or by model use. Saving checks the saved connection revision and cancellation before writing, and retains the existing optimistic connection commit. The standalone Test action checks saved connection/model/preset revisions before and after its request. Failure or cancellation before commit neither changes the enabled state nor replaces a saved key. Deactivation remains immediate and saves only the disabled state, preserving unsaved editor input. Immutable Keychain installation and rollback/cleanup remain part of credential persistence, without probing the provider.

The standalone Test action does not save the connection, model, credential, conversation, or capability observation. The request uses the production adapter with its endpoint, redirect, error-redaction, output, timeout and cancellation guards, and preserves the selected model's thinking mode and output reservation. It sends only the fixed synthetic probe content. Demo mode rejects all connection tests and activation writes. A successful connection test says only that this selected model completed the synthetic text exchange; it never verifies tools, vision, pricing, maximum context, extraction, or account access to other models.

Provider model switches reuse saved model enablement, or atomically add a bundled model and its canonical preset using declared catalog capabilities and the existing thinking defaults. Unknown or incomplete remote entries open the model editor. Provider activation and pool membership remain independent; no purpose binding is assigned automatically.

Provider activation presentation keeps the requested switch value separate from the persisted baseline while validation/save is pending. A failure or cancellation restores the current persisted state; repeated requests for that state perform no write. Configuration notifications received before a save returns are reconciled after the operation rather than invalidating its own result. A newer external revision still wins and reports a conflict, preserving unsaved input.

Connection validation and credential cleanup read `modelConfiguration()` directly. Unchanged credential references/versions reuse the secure value already loaded for the open settings session. Provider configuration observers ignore draft/thinking stream events and coalesce pending reads; a save callback does not reload a revision already installed by its notification. Configuration-only notifications do not enumerate routing scopes or reload conversation histories. Existing transactional attestation updates and execution/extraction cancellation ordering remain unchanged.
