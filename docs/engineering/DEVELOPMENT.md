# 开发环境、工程组织与协作约定

**文档版本：** v1.2  
**更新日期：** 2026-09-05  
**状态：** 开发前规范基线；实现与验收尚未执行。

定义平台、工具链、工程结构、分发和开发协作方式；产品行为和技术契约分别由产品与领域架构文档负责。

返回 [ARCHITECTURE.md](../ARCHITECTURE.md) · 版本范围：[MVP](../MVP.md)

## 开发与分发基线

| 项目 | 开发基线 |
|---|---|
| 最低系统 | macOS 15（2024 年的 Sequoia）及后续版本 |
| 分发 | 用户直接下载安装，不走 Mac App Store |
| 首版功能与协议选择 | 以 [MVP](../MVP.md) 的已确认范围为准 |
| 语言模式 | Swift 6 严格并发检查；跨 Actor 的领域值使用 Sendable |
| 工具链 | 开发起点为本机 Xcode 26.6 / Swift 6.3.3；工程创建时固定并记录 CI 版本 |
| 依赖 | GRDB 7.11.1 作为已核对的初始候选；建工程时解析并提交 Package.resolved，升级须重新验证 |

macOS 版本范围和直接分发方式由用户确认；具体工具链与依赖固定是工程默认。本机为 Apple Silicon，只能作为该架构的验证证据；不能据此宣称 Intel 已验证或不再支持。每个发布产物明确列出已测试 CPU 架构和最低系统。

初期直接分发采用非 App Sandbox Host，继续使用应用内文件授权范围、TCC（透明度、同意与控制）和 Keychain。`FileAccessCapability` 在非沙箱环境使用普通 Bookmark 与应用策略管理授权；若未来增加沙箱构建，由 Adapter 改用 Security-scoped Bookmark。分发方式不等于工具权限，首个 MVP 不提供 Shell、AppleScript 或任意路径读写。

对外下载版使用 Developer ID 签名、Hardened Runtime（强化运行时）和公证；证书与签名凭据属于发布前条件，不阻塞本机工程开发。首次发布采用手工下载更新，保持 Bundle ID 与数据目录稳定，升级前备份并执行迁移；自动更新不作为 MVP 前置条件。

系统版本和依赖的核验来源见 [参考资料](../REFERENCES.md)。这些是当前基线，工具链更新时同步 CI 并重跑受影响测试；不使用未记录的“最新版”作为可重现构建约束。

---

<a id="s33"></a>

## 1. 推荐代码结构

```text
Mira/
├── Apps/
│   └── MiraMac/
│       ├── App/
│       ├── Composition/
│       ├── Features/
│       │   ├── Conversation/
│       │   ├── Workspace/
│       │   ├── Memories/
│       │   ├── Knowledge/
│       │   ├── Schedule/
│       │   ├── Search/
│       │   └── Settings/
│       ├── Platform/
│       │   ├── Files/
│       │   ├── Clipboard/
│       │   ├── Notifications/
│       │   ├── EventKit/
│       │   ├── Keychain/
│       │   └── UIRequests/
│       └── Presentation/
│
├── Packages/MiraKit/
│   ├── Sources/
│   │   ├── MiraCore/
│   │   │   ├── Domain/
│   │   │   ├── Application/
│   │   │   ├── Conversation/
│   │   │   ├── Runtime/
│   │   │   ├── Tools/
│   │   │   ├── Providers/
│   │   │   ├── Prompt/
│   │   │   ├── Context/
│   │   │   ├── Compact/
│   │   │   ├── Memory/
│   │   │   ├── Knowledge/
│   │   │   ├── StructuredData/
│   │   │   └── Ports/
│   │   ├── MiraData/
│   │   │   ├── Database/
│   │   │   ├── Migrations/
│   │   │   ├── Records/
│   │   │   ├── Repositories/
│   │   │   ├── Search/
│   │   │   └── BlobStore/
│   │   └── MiraProviders/
│   │       ├── Canonical/
│   │       ├── Adapters/
│   │       ├── Discovery/
│   │       └── Transport/
│   └── Tests/
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

文件夹是职责组织，不要求每个文件夹拥有一层 Protocol。

## 2. 开发协作与工程边界

- 当前开发分支为 `dev`，`main` 保留已发布或稳定基线；新的临时实现分支默认以 `codex/` 开头，从所需基线创建。
- 按 MVP 里程碑提交可审阅的纵向变更，提交信息采用 Conventional Commits。是否合并或推送遵循当前任务授权；分支约定不自动授权发布。
- 建工程时提交 Xcode 工程、共享 Scheme、Swift Package 清单和解析依赖；增加适合 Swift / Xcode 的 `.gitignore`，不提交 DerivedData、用户工作区状态、密钥或真实资料库。
- 使用 SwiftUI 原生控件与 Observation，平台桥接仅在所需能力不由 SwiftUI 提供时加入。View 仅发意图，业务执行由长生命周期的明确所有者管理。
- 测试通过 Clock、ID Generator、Fake Provider / Tool 与隔离临时数据目录注入不确定性；不为每个数据类型增加无实际作用的一层 Protocol。
- M0 工程创建后补充准确的构建 / 测试命令；当前尚无 `Package.swift`，不把尚不可运行的命令写成已验证说明。

## 3. 文档变更规则

| 变更内容 | 应更新的文件 |
|---|---|
| 产品身份或目标用户 | PRD.md |
| 用户如何操作、看到什么、失败时如何处理 | product/ 对应规范 |
| 领域字段、状态机、事务、算法与 API 契约 | architecture/ 对应设计 |
| 模块依赖或架构不变量 | ARCHITECTURE.md |
| 工具链、平台、分发、工程结构 | 本文件 |
| Fixture、指标、性能与发布门槛 | QUALITY.md |
| 首版范围、里程碑、进度与依赖 | MVP.md |
| 发现的问题、取舍理由与验证状态 | reviews/ 下的审阅记录 |

每条规范只有一个完整定义位置；其他文件给出必要摘要并链接，不复制整个字段表或阈值。重大取舍在 ADR 中记录 Context、Decision、Alternatives、Consequences 和验证计划；按实际变化建立文件，不预先创建一批空 ADR。
