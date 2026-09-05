# Mira 架构总览

**文档版本：** v1.2  
**更新日期：** 2026-09-05  
**状态：** 开发前规范基线；实现与验收尚未执行。

定义系统结构、依赖方向、架构不变量和并发所有权。具体领域模型与算法位于 architecture 目录，工具链与交付规则位于 engineering 目录。

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

- [通用领域模型、本地存储与恢复](architecture/DOMAIN_AND_STORAGE.md)：定义 ID、时间、修订、Typed JSON、Blob、事务、数据约束、LocalJob、备份与恢复；不定义版本排期。
- [对话执行、流式与工具运行时](architecture/RUNTIME.md)：定义 Conversation 持久化、Turn / Step / Attempt、工具交换、权限管线、状态机、取消、恢复与错误边界。
- [模型服务商接口与路由](architecture/PROVIDERS.md)：定义 Provider 契约、路线解析、冻结与重试边界、协议兼容性、端点安全、能力和用量。
- [提示词、上下文、召回与压缩](architecture/CONTEXT.md)：定义 Prompt、Context 生命周期、预算、请求快照、来源引用、Memory 检索和 Compact；不重复记忆写入规则。
- [记忆与知识领域设计](architecture/MEMORY_AND_KNOWLEDGE.md)：定义记忆提取、来源、抑制、演化、工作记忆及资料版本与解析；用户可见行为在产品规范中定义。
- [结构化记录与通知一致性](architecture/STRUCTURED_DATA.md)：定义记录、候选、时间与金额、Revision、Apple 投影及可恢复通知交付；在对应 MVP 里程碑才实施。
- [本地搜索与中文检索](architecture/SEARCH.md)：定义检索管线、FTS 能力探测、短查询回退、规范化、结果与向量扩展；量化验收门槛在质量标准中。
- [平台适配、展示层与安全边界](architecture/PLATFORM_AND_SECURITY.md)：定义未来同步最低兼容性、macOS 能力与展示边界、隐私策略、数据发送和删除约束；分发构建基线在开发文档中。

---

<a id="s01"></a>

## 1. 已知前提与技术基线

<a id="s01-01"></a>

### 1.1 已确认前提

```text
User Model             单个个人用户
Primary Host           macOS
Future Host            iOS
Core Language          Swift
UI                      SwiftUI + 必要的 AppKit / UIKit
Local Database         SQLite via GRDB
Large Content          Local Blob Store
Remote Models          User-managed Provider Access / BYOK
Mira Backend           None
Conversation Sync      默认不全量同步
Apple Calendar/Reminder Mira → Apple 单向发布
```

<a id="s01-02"></a>

### 1.2 当前不做的技术承诺

- 不承诺 Web、Windows 或 Android Host；
- 不建设 Rust / C++ Core；
- 不建设本地 HTTP Server 作为模块通信方式；
- 不建设动态二进制插件内核；
- 不建设 Mira 云端同步服务器；
- 不建设专用图数据库；
- 不建设外部 Markdown Vault 与数据库的双向实时同步；
- 不要求 App 完全退出后 Agent 仍继续运行；
- 不在同步尚未实现时建设通用 Sync Runtime。

<a id="s01-03"></a>

### 1.3 Swift 技术基线

共享核心代码使用 Swift，原因：

- macOS 与 iOS 可直接共享领域、Runtime、Context、Memory、Knowledge 和 Data；
- 与 Swift Concurrency、SwiftUI、AppKit、EventKit、UserNotifications 和 Keychain 自然衔接；
- 避免 FFI（Foreign Function Interface，外部函数接口）和双构建系统；
- 个人开发阶段将复杂度集中在产品机制，而不是语言边界。

Core 不依赖 Apple UI 与平台实现，不等于 Core 必须使用非 Apple 语言。

---

<a id="s02"></a>

## 2. 架构目标

1. macOS 和未来 iOS 使用各自原生 UI。
2. 共享 Domain、Application、Agent Runtime、Context、Memory、Knowledge、Provider Contract 和数据模型。
3. 本地数据库是规范事实源，远程服务不是主存储。
4. Conversation、Execution、Memory、Knowledge Source 和 Structured Record 具有清晰边界。
5. 所有影响模型行为的重要输入可以重建或审计。
6. 自动记忆不会把 Assistant 建议误当成用户决定。
7. 临时检索不会永久污染后续 Context。
8. Agent 工具调用具有明确权限、身份、取消和重试边界。
9. 多 Provider 由统一契约适配，不在 Core 中传播厂商 Wire 类型。
10. Context 正确性优先，同时尽量保持可复用的稳定前缀。
11. Compact 不删除原始历史，并允许根据用途路线选择成本策略。
12. Memory 能表达 Scope、来源、时间、修订、演化和当前有效版本。
13. Knowledge Base 支持 Source、Markdown Note、Wiki Link、Entity 和 Relation，但不提前建设重型图平台。
14. 对话中的 Task、Reminder、CalendarEvent、EventRecord 和 FinancialTransaction 可独立保存、变更和溯源。
15. 中文、英文、代码和混合文本从第一版搜索架构开始就可用。
16. 未来同步不被当前模型堵死，但未实现同步不转化为持续基础设施成本。
17. 架构可通过 Fake Provider、Fake Tool 和 Fixture 在无 UI 环境下测试。

---

<a id="s03"></a>

## 3. 核心架构不变量

### INV-001：Local Store Is Canonical

核心业务对象先写入本地数据库或 Blob Store。远程模型、Apple Calendar、Apple Reminders 和未来同步端都不是 Mira 规范事实源。

### INV-002：No Secret in Normal Data

API Key、OAuth Token 等凭据只保存在系统安全存储中。普通数据库、Runtime Event、日志、Request Snapshot 和导出文件不得包含明文密钥。

### INV-003：UI Never Owns Persistence or Provider Calls

SwiftUI View 不直接操作 GRDB、不直接调用 Provider、不持有 Agent Runtime 内部可变状态。

```text
View
  ↓
Presentation / ViewModel
  ↓
Use Case / Query
  ↓
Core Port
  ↓
Data / Provider Adapter
```

### INV-004：Core Has No Apple Implementation Dependency

`MiraCore` 不导入 AppKit、UIKit、SwiftUI View、EventKit、UserNotifications、CloudKit 或 Keychain 实现。

平台能力通过 Protocol / Port 注入。

### INV-005：Conversation、Execution 与 Knowledge 分层

```text
Conversation
用户与 Mira 最终交流了什么

Execution
Agent 如何得到结果

Memory / Knowledge
未来值得再次使用的认知和资料
```

三者不能用同一张万能事件表代替。

### INV-006：Raw Is Never Silently Rewritten by Derived Data

Compact、Memory、Working Memory、Search Index、Graph Projection 和生成 Note 不得静默删除或修改其原始 Message、Execution 或 Source。

### INV-007：Streaming Delta Is Not a Message

流式 Delta 是传输 / Runtime Event。完成或中断后形成一个规范 Assistant Message；不能把每个 Token 当作 Conversation Message 永久保存。

### INV-008：Runtime Events Are Append-only Within an Execution

Execution 内已提交事件不可原地改写。修复通过后续事件和规范对象状态完成。正文通过受保护内容引用保存；用户主动删除或到期清理可以使引用不可读，事件仅保留无正文的状态与清理标记，审计规则不能阻止用户删除。

### INV-009：Tool Call and Result Preserve Identity

每个 Tool Result 必须引用唯一 ToolInvocation ID。取消、超时和未调度调用也必须产生可解释的终止结果。

### INV-010：Retry Occurs at Durable Boundary

只有当系统能判断副作用是否发生、是否幂等、是否已有提交结果时才允许自动重试。Provider Adapter 和 Tool 实现不能隐藏不可见的多次重试。

### INV-011：No Silent Provider Switch

一次 Agent Turn 的主模型路线冻结。跨 Provider Fallback 只能执行用户显式配置的路线。

### INV-012：Model-visible Means Auditable

本轮真正发送给模型的 Header、Durable History、Turn Context、Tool Schema 和调用配置必须保存在 Request Snapshot 中。在正文保留期内且未被用户删除时可重建；清理后明确显示不可重建状态。

审计不要求把所有本轮 Context 永久喂给后续模型。

### INV-013：Durable and Turn-scoped Context Are Different

Memory 预取、知识片段、临时工具搜索结果、当前时间等默认不跨用户 Turn 进入 Durable Conversation Surface。同一 Turn 的后续 Step 可以保留所需的工具交换，每次实际请求重新进行权限、来源有效性与预算检查。

### INV-014：Candidate Is Not a Normal Fact

Candidate Memory 和 Proposed Relation 默认不参与普通回答的事实注入。只有 Active / Confirmed 内容可进入正常召回。

### INV-015：User Authority Is Preserved

用户明确陈述、Assistant 建议、Tool Result、外部文档和模型推断必须保留不同来源与权威等级。

### INV-016：Revision Is Not Evolution

文字修订不创建虚假的知识变化；语义发生变化时必须创建新 Memory 并建立演化关系。

### INV-017：Projection Is Rebuildable

Search Index、Graph View、Working Memory Snapshot、Memory Current Projection、统计和缓存都不是第二事实源，损坏后可由规范数据重建。

### INV-018：Apple Projection Does Not Mutate Mira Backwards

当前基线只允许 Mira 将 CalendarEvent / Reminder 发布到 Apple。Apple 端业务字段变化不静默覆盖 Mira 内部记录。

### INV-019：Prefix Stability Applies to Durable Content

系统尽量保持 Stable Header、Tool Schema 和 Durable Conversation Prefix 稳定；不得为了缓存长期保留无关 Turn-scoped Context。

### INV-020：Sync-ready Does Not Mean Sync Runtime

当前只保留稳定 ID、Revision、时间和删除语义。未实现同步时不要求 ChangeJournal、SyncEnvelope、通用 Transport 或复杂冲突引擎。

---

<a id="s04"></a>

## 4. 基线默认与架构假设

<a id="s04-01"></a>

### 4.1 基线默认

| 主题 | 默认方案 |
|---|---|
| Memory 自动写入 | 明确“记住”直接 Active；清晰稳定用户陈述可自动 Active 并可撤销；推断、敏感、冲突进入 Candidate |
| Memory 召回 | 有限预取 + Agent 主动深度检索 |
| Context | Stable Header + Durable Surface + Turn-scoped Context |
| Working Memory | 用户 Pinned + 确定性快照；LLM 摘要可选 |
| Compact | 独立 `compact` Route；同路线时可进行前缀重放优化 |
| Knowledge Synthesis | 先作为带 Evidence 的生成 Draft Note |
| Graph | SQLite 关系的可重建投影，不使用图数据库 |
| Search | FTS5 双路径覆盖中文与拉丁 / 代码；向量检索可选 |
| ID | 业务 UUID + 高频表内部 SQLite RowID / Sequence |
| Blob GC | Grace Period + Mark-and-Sweep 引用扫描 |
| Sync | 不实现 Runtime，仅保留最低字段 |
| Apple 通知 | 每条记录只有一个 Delivery Owner |

<a id="s04-02"></a>

### 4.2 架构假设

以下内容只在产品使用证明价值后建设：

- 独立 Knowledge Synthesis 状态机；
- Topic 社区检测；
- Graph Selection Snapshot 与复杂图分析；
- 通用 ContextContributor 插件协议；
- 第三方动态 Tool 插件生命周期；
- LLM 自动生成 Working Memory；
- 完整 Apple Reminder 完成状态回读；
- 通用同步引擎；
- App 完全退出后的 Helper Runtime。

---

<a id="s05"></a>

## 5. 总体架构

```text
┌──────────────────────────────────────────────────────────────────┐
│                           MiraMac Host                           │
│                                                                  │
│ SwiftUI / AppKit                                                 │
│ Navigation / Window / Commands                                   │
│ Presentation Models                                              │
│ Apple Platform Adapters                                          │
│ Composition Root                                                 │
└───────────────┬──────────────────────────────────────────────────┘
                │
                ▼
┌──────────────────────────────────────────────────────────────────┐
│                           MiraCore                               │
│                                                                  │
│ Domain                                                           │
│ Application Use Cases                                            │
│ Conversation                                                     │
│ Agent Runtime                                                    │
│ Tool Policy                                                      │
│ Context / Prompt / Compact                                       │
│ Memory / Knowledge                                               │
│ Structured Data                                                  │
│ Query & Repository Ports                                         │
└───────────────┬────────────────────────────┬─────────────────────┘
                │                            │
                ▼                            ▼
┌────────────────────────────┐  ┌──────────────────────────────────┐
│          MiraData          │  │          MiraProviders           │
│                            │  │                                  │
│ GRDB / SQLite              │  │ Provider Adapters                │
│ Migrations                 │  │ Canonical Stream Conversion      │
│ Repository Implementations │  │ Model Discovery                  │
│ Search Index               │  │ Usage Normalization              │
│ Blob Store                 │  │ URLSession Transport             │
└────────────────────────────┘  └──────────────────────────────────┘
```

未来 `MiraIOS` 使用同一 `MiraCore`、`MiraData` 和 `MiraProviders`，但实现自己的 UI 与 Apple Adapter。

---

<a id="s06"></a>

## 6. 物理 Target 与依赖方向

<a id="s06-01"></a>

### 6.1 目标 Target

以下为规划中的工程结构，当前尚未创建应用代码；完整目录与工具链由 [开发约定](engineering/DEVELOPMENT.md) 维护。

```text
Mira/
├── Apps/
│   └── MiraMac/
│
├── Packages/MiraKit/
│   ├── Sources/
│   │   ├── MiraCore/
│   │   ├── MiraData/
│   │   └── MiraProviders/
│   └── Tests/
│       ├── MiraCoreTests/
│       ├── MiraDataTests/
│       └── MiraProvidersTests/
│
└── docs/
    ├── PRD.md
    ├── ARCHITECTURE.md
    ├── MVP.md
    ├── product/
    ├── architecture/
    ├── engineering/
    └── reviews/
```

逻辑职责不要求每个概念一个 Package。

<a id="s06-02"></a>

### 6.2 依赖方向

```text
MiraMac ───────────────┐
                       ├──→ MiraCore
MiraData ──────────────┤
MiraProviders ─────────┘

MiraCore
  └── Foundation / 标准 Swift

MiraData
  ├── MiraCore
  └── GRDB / SQLite

MiraProviders
  ├── MiraCore
  └── Foundation / URLSession
```

`MiraCore` 定义 Port；外层 Target 实现 Adapter。

<a id="s06-03"></a>

### 6.3 不建立的 Target

当前不建立：

- `MiraShared`；
- `MiraPluginKernel`；
- `MiraSync`；
- `MiraGraphDatabase`；
- `MiraRuntimeServer`；
- 每个领域对象单独 Package。

只有出现明确编译、所有权或跨项目复用需求时再拆分。

---

<a id="s07"></a>

## 7. Composition Root 与 Swift 并发

<a id="s07-01"></a>

### 7.1 Composition Root

依赖只在 Host 的 Composition Root 组装。

```text
MiraMacApp
  └── AppContainer
      ├── DatabaseWriter
      ├── Repository Implementations
      ├── Provider Registry
      ├── Credential Store
      ├── Tool Registry
      ├── Platform Capabilities
      ├── AgentRuntime
      ├── ContextBuilder
      └── Use Cases
```

禁止将一个包含所有服务的全局 `RuntimeEnvironment` 传入每个 Use Case，避免 Service Locator（服务定位器）隐藏依赖。

Use Case 只接收真正需要的 Port。

<a id="s07-02"></a>

### 7.2 并发所有权

建议所有权：

```text
@MainActor
Presentation Model / UI State

actor AgentRuntime
Execution 生命周期、Step 调度、取消状态

actor ProviderScheduler
连接级限速、优先级和并发

actor LocalJobScheduler
后台任务状态和资源预算

GRDB DatabaseWriter
数据库写入串行化与事务
```

不要为每个 Repository 建立独立 Actor；数据库并发由 GRDB 的 Writer / Reader 模型管理。

<a id="s07-03"></a>

### 7.3 可取消数据库写入

GRDB 异步访问会响应 Swift Task 取消。关键提交不能错误地绑定在 SwiftUI `task` 生命周期上。

规则：

- 用户取消可以取消尚未提交的业务操作；
- 已经进入必须完成的规范写入时，由明确拥有者等待事务结束；
- UI View 消失不能自动回滚本应提交的 Message 或 Execution Terminal State。

> **参考设计标注｜GRDB**  
> 采用 GRDB 的事务、DatabaseWriter 和 ValueObservation（值观察）能力；并显式处理 Swift Concurrency 取消对异步数据库访问的影响。
