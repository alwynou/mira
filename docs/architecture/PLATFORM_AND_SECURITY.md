# 平台适配、展示层与安全边界

**文档版本：** v1.2  
**更新日期：** 2026-09-05  
**状态：** 设计基线；当前实现与验收范围见 [实施记录](../engineering/IMPLEMENTATION_STATUS.md)。

定义未来同步最低兼容性、macOS 能力与展示边界、隐私策略、数据发送和删除约束；分发构建基线在开发文档中。

返回 [ARCHITECTURE.md](../ARCHITECTURE.md) · 版本范围：[MVP](../MVP.md)

---

<a id="s26"></a>

## 1. Sync-ready Architecture

<a id="s26-01"></a>

### 1.1 当前最低字段

未来可能同步的规范对象至少保留：

```text
id
revision
createdAt
updatedAt
deletedAt?
originDeviceId?（确有来源意义时）
```

<a id="s26-02"></a>

### 1.2 类型级语义

文档层定义：

```text
localOnly
Conversation / Execution / Credential / Apple External ID

futureShareable
Workspace / Memory / Note / Structured Data

conditional
Source Blob / Artifact
```

当前不要求每一行保存 `syncPolicy`。

<a id="s26-03"></a>

### 1.3 当前不实现

- SyncEnvelope；
- 通用 SyncTransport；
- 每次写入 ChangeJournal；
- 独立 Tombstone 表；
- Cloud Conflict Resolver；
- 多设备游标；
- Blob Chunk Sync。

真实开始同步时通过 Migration 增加。

<a id="s26-04"></a>

### 1.4 删除兼容

`deletedAt` 为未来表达删除提供最低语义。当前本地永久清理仍遵守保留期、引用和用户确认。

<a id="s26-05"></a>

### 1.5 未来候选

Apple 生态同步可评估 CloudKit / CKSyncEngine，但 Conflict 规则仍属于 Mira Domain，不由 Transport 自动决定。

---

<a id="s27"></a>

## 2. Platform Capability 与 macOS Host

<a id="s27-01"></a>

### 2.1 Capability Ports

```text
FileAccessCapability
ClipboardCapability
NotificationCapability
CalendarPublishCapability
ReminderPublishCapability
SecureCredentialCapability
VoiceInputCapability
CameraCapability
PhotoLibraryCapability
LocationCapability
ShellCapability
AutomationCapability
```

Core 不判断 `if macOS`，只查询 Capability Status。

<a id="s27-02"></a>

### 2.2 Capability Status

```text
unavailable
availableNotAuthorized
authorized
denied
restricted
temporarilyUnavailable
```

<a id="s27-03"></a>

### 2.3 macOS Adapter

```text
Clipboard            NSPasteboard
File Picker          NSOpenPanel
File Authorization   Bookmark + App Scope Policy（沙箱构建使用 Security-scoped Bookmark）
Notification         UserNotifications
Calendar / Reminder  EventKit
Credential           Keychain
Shell                Process（受严格 Policy 约束）
Automation           Apple Events / AppleScript（受严格权限约束）
```

<a id="s27-04"></a>

### 2.4 File Authorization

流程：

```text
UI Request pickFile / pickDirectory
        ↓
Host 显示 NSOpenPanel
        ↓
按当前 Host 构建模式创建 Bookmark
        ↓
数据库保存 Bookmark Reference / Scope
        ↓
使用时恢复 URL 并开始访问
        ↓
Core Tool 在授权路径内读取
        ↓
结束访问
```

Core 只接收授权后的资源句柄 / 语义路径，不操作 Bookmark API。非沙箱 Host 以应用内 FileAccessGrant 校验用户选定资源；沙箱 Host 额外负责 Security-scoped 访问的开始 / 结束与失效 Bookmark 更新。当前构建方式由 [开发约定](../engineering/DEVELOPMENT.md) 决定，不能把沙箱 API 当作所有 Host 都存在的权限来源。

`FileAccessGrant` 保存资源标识、Bookmark、允许模式（read / write）、授权来源、创建时间、撤销时间与 Revision。路径解析在真正打开资源时再次验证；权限由有效 Grant 决定，不由模型传入的目录字符串决定。

<a id="s27-05"></a>

### 2.5 EventKit 单向发布

Core：

- 创建内部 CalendarEvent / Reminder；
- 产生 Publish Command；
- 保存 ExternalProjectionLink 状态。

Host Adapter：

- 请求 EventKit 权限；
- 写入或更新 Apple 项目；
- 返回 External Identifier；
- 检查副本存在性；
- 不把 Apple 业务字段合并回 Core。

<a id="s27-06"></a>

### 2.6 UserNotifications

只有 `deliveryOwner = mira` 时安排通知。

授权状态随时可能变化，Adapter 每次安排前验证权限并返回可解释错误。

---

<a id="s28"></a>

## 3. Security、Privacy 与 Prompt Injection

<a id="s28-01"></a>

### 3.1 数据分类

敏感度与发送策略是两个维度：`sensitivity = public / private / sensitive`；`outboundPolicy = neverRemote / providerAllowList / askEachTime`。不能把“敏感”与“允许发送”做成互斥枚举，或用某个 Provider 的允许覆盖 neverRemote。

有效策略取全局、Workspace、对象和来源继承限制的交集。一次批准仅针对所选 Provider、用途、对象版本与有效期；改变原有 neverRemote 必须由用户明确修改该对象设置。生成 Memory / Note / 摘要继承其来源的限制；摘要不构成降低隐私等级的理由。

Scope 首先决定能否读取；outboundPolicy 再决定能否发送。Inbox 只拥有 Global 与用户显式附加来源，Workspace 内的 memory.search / source.open 不默认访问其他项目。Credential、授权元数据和 Bundle 外任意文件永不作为普通 Context 来源。

<a id="s28-02"></a>

### 3.2 Provider Disclosure

RequestSnapshot 记录内容类别和来源；UI 可显示：

- Provider / Model；
- 发送的 Memory 数量；
- 是否包含 Source、文件、图片；
- 被隐私规则排除的内容。

<a id="s28-03"></a>

### 3.3 Credential

- Keychain 存储；
- 数据库只保存不可逆引用 ID；
- 日志输出自动脱敏；
- Provider 自定义 Header 中的 Secret 也通过 Credential Reference；
- 导出和诊断包默认不包含 Secret。

<a id="s28-04"></a>

### 3.4 Tool Sandbox

- 文件工具限制在授权 Scope；
- Shell 默认逐次确认；
- 删除操作显示具体目标；
- 自动化不能继承比用户授权更大的权限；
- Tool Result 中的指令不改变 Tool Policy。

<a id="s28-05"></a>

### 3.5 Prompt Injection

- 外部 Source 标记为 Untrusted；
- 系统指令与内容使用稳定边界；
- 文档中的工具调用建议不能直接执行；
- Agent 需要把外部内容视为数据，而不是权限来源；
- Source 中发现敏感数据时遵守 Workspace Provider Policy；
- Tool Schema 不接受运行时文档动态注入的新权限。

<a id="s28-06"></a>

### 3.6 日志

日志允许记录：

- ID；
- 类型；
- 状态；
- 时延；
- Token；
- 错误码；
- 内容 Hash。

默认不记录：

- 完整 Prompt 正文；
- 密钥；
- 敏感 Memory；
- 私密文件内容。

完整 RequestSnapshot 作为受保护本地业务数据，而不是普通 Debug Log。

<a id="s28-07"></a>

### 3.7 本地保护与删除边界

通过系统 Application Support 定位应用数据目录，使用仅当前用户可读写的文件权限。非沙箱 Host 也不把资料库保存在代码仓库或用户 Documents 的默认共享位置。MVP 不声称具有应用级数据库 / Blob 加密、安全擦除或对已取得同用户进程权限的攻击者提供隔离。

用户主动清理按引用依赖关闭未来使用，再异步清理正文；清理范围包括 Evidence 摘录、版本快照、Draft、ModelOutput 和请求内容。正文不可恢复后，历史记录显示清理原因，不能从另一个缓存偷偷恢复。SQLite WAL、操作系统备份和外部导出属于单独清理边界，UI 的“永久删除”不等同于物理介质零残留保证。

调试包只导出明确允许的元数据，默认不包括 Prompt、用户文件、完整错误报文、Provider 自定义 Header 或密钥引用的值。使用公开 Fixture 的测试日志不得混入真实用户资料。

---

<a id="s29"></a>

## 4. Presentation、Read Model 与 Inspector

<a id="s29-01"></a>

### 4.1 数据流

```text
SwiftUI View
    ↓ Intent
@MainActor PresentationModel
    ↓
Use Case / Query Port
    ↓
MiraCore
    ↓
Repository / Provider / Capability Port
```

数据库变化通过 Read Model Observation 更新 UI。

<a id="s29-02"></a>

### 4.2 Read Model

复杂页面使用专用 Read Model：

```text
ConversationScreenModel
MemoryListItem
ContextInspectorModel
ExecutionTimelineItem
CalendarDayModel
KnowledgeSearchResult
```

不把数据库 Record 直接暴露到 UI。

<a id="s29-03"></a>

### 4.3 Execution Inspector

显示：

- Step；
- ModelCall；
- ToolInvocation；
- 权限决策；
- Retry；
- Token / Cost；
- 失败点；
- 可重试与否。

<a id="s29-04"></a>

### 4.4 Context Inspector

显示：

- Stable Header 版本；
- Durable Surface 范围；
- Turn-scoped Items；
- Memory 选择原因；
- 省略原因；
- Token Budget；
- Prompt / Renderer 版本；
- Prefix Series；
- Provider Cache Usage（若有）。

<a id="s29-05"></a>

### 4.5 Memory Inspector

显示：

- Scope；
- State；
- Origin / Authority；
- 来源与 Excerpt；
- Revision；
- Evolution；
- Current / Superseded；
- 本次为何召回；
- 编辑、撤销、归档和遗忘。

### Conversation presentation updates

`ConversationStreamBuffer` owns only transient presentation snapshots on the main actor. Cumulative runtime text and thinking events are coalesced at 100 ms before Observation publication; persistence and provider execution continue independently. An authoritative conversation load, terminal result, selection change, or privacy clear cancels pending presentation emissions and replaces them immediately. Late timers cannot revive discarded content.

Composer input is observed in a separate view from transcript snapshots. Assistant rows use execution identity across draft and terminal states, retain their Markdown renderer, and render thinking only when expanded. Scroll intent is independent of content growth; measured size changes may follow only when the user is following the latest output, and already-visible content never causes a redundant scroll. Renderer patch details and native evidence are in [streaming performance](../engineering/STREAMING_PERFORMANCE.md).

The transcript receives a finite viewport through `GeometryReader`; its growing ideal height must not feed the hosting window's minimum/ideal/maximum sizing negotiation. An immutable equatable row boundary prevents draft updates from rebuilding completed row headers, menus, and citation containers. Equality includes message content/status/trace, conversation identity, and model identity; SwiftUI environment changes still propagate to native renderer views.

`TranscriptFollowScheduler` coalesces geometry-driven scroll requests outside the current layout transaction with a 16 ms delay. Manual scrolling, source navigation, jumping to latest, and disappearance cancel pending follows. Eligibility is checked again when a delayed follow executes. Offset-only callbacks do not schedule another scroll. Automatic following uses an explicit bottom offset instead of a permanently pinned edge, with a 220 ms non-bouncing SwiftUI spring during live generation. Retargeting keeps the current motion continuous. Initial/history placement, explicit jumps, and Reduce Motion use immediate transactions; manual scrolling cancels queued follows and lets the native scroll view interrupt active motion.

Streaming text animation is independent of content publication and layout. `MarkdownView.animatesTextUpdates` enables macOS paragraph fades only after the initial parsed snapshot; the host disables it for terminal messages and Reduce Motion. `StreamingFadeLayoutManager` resolves appended UTF-16 ranges to glyphs on content updates, excludes attachments, and changes drawing alpha without editing text storage on frames. Each paragraph retains at most eight batches within its last 2,048 UTF-16 units for at most 600 ms. Timing matches upstream: a 500 ms fade with a 100 ms word-stagger window. Drawing is capped at 128 spans per paragraph; large packets group adjacent words. A view-owned display link uses a weak target proxy; terminal updates, selection, dismantling, and window removal finish fades. Measurement caches and automatic scrolling never depend on animation progress.
