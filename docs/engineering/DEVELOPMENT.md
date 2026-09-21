# 开发环境、工程组织与协作约定

**文档版本：** v1.3
**更新日期：** 2026-09-07
**状态：** 工程已初始化；已实现的增量与验证证据见 [实施记录](IMPLEMENTATION_STATUS.md)。

定义平台、工具链、工程结构、分发和开发协作方式；产品行为和技术契约分别由产品与领域架构文档负责。

返回 [ARCHITECTURE.md](../ARCHITECTURE.md) · 版本范围：[MVP](../MVP.md)

## 开发与分发基线

| 项目 | 开发基线 |
|---|---|
| 最低系统 | macOS 15（2024 年的 Sequoia）及后续版本 |
| 分发 | 用户直接下载安装，不走 Mac App Store |
| 首版功能与协议选择 | 以 [MVP](../MVP.md) 的已确认范围为准 |
| 语言模式 | Swift 6 严格并发检查；跨 Actor 的领域值使用 Sendable |
| 工具链 | 本机 Xcode 26.6 / Swift 6.3.3；CI 包测试使用 macos-15 / Xcode 26.3，应用测试使用 macos-26 / Xcode 26.6；Host 依赖要求 Swift 6.2+，MiraKit Package tools-version 6.1 |
| 依赖 | GRDB 7.11.1，已提交 Package 与 Xcode 的 Package.resolved；工程生成器 XcodeGen 2.46.0 |

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
│       │   ├── Tasks/
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

- Every requirement adjustment follows GitHub issue → fresh `codex/` branch → implementation and focused verification → linked PR → merge after required checks pass. Create or reuse the issue before implementation and record scope and acceptance criteria. Fetch and fast-forward `main` before branching; preserve unrelated local changes.
- The user approved this standing workflow on 2026-09-20, including routine pushes, PR creation, and merging. Follow explicit exceptions for a particular task and never bypass failing checks or branch protections. Link the PR with `Closes #<issue>`, use Conventional Commits, record exact verification and remaining gaps, then synchronize local `main` after merge. Release publication remains a separate action.
- 建工程时提交 Xcode 工程、共享 Scheme、Swift Package 清单和解析依赖；增加适合 Swift / Xcode 的 `.gitignore`，不提交 DerivedData、用户工作区状态、密钥或真实资料库。
- 使用 SwiftUI 原生控件与 Observation，平台桥接仅在所需能力不由 SwiftUI 提供时加入。View 仅发意图，业务执行由长生命周期的明确所有者管理。
- 测试通过 Clock、ID Generator、Fake Provider / Tool 与隔离临时数据目录注入不确定性；不为每个数据类型增加无实际作用的一层 Protocol。
- 构建与测试命令见下文；命令可运行不代表所有产品验收项已经完成。

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

## 4. 当前工程操作

从仓库根目录执行：

```sh
swift test --package-path Packages/MiraKit --disable-automatic-resolution
xcodebuild -project Mira.xcodeproj -scheme Mira -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath .build/xcode \
  -onlyUsePackageVersionsFromResolvedFile CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Mira.xcodeproj -scheme Mira \
  -destination 'platform=macOS' -derivedDataPath .build/xcode \
  -onlyTesting:MiraHostTests test
```

The package command exercises MiraKit. The host command runs the renamed `MiraHostTests` target, which contains localization and isolated Keychain fixtures. Native macOS UI and CI execution are separate evidence and must be recorded independently.

CI adds `--no-parallel` to the package command so unrelated Swift Testing fixtures do not compete for the hosted runner's executor threads. Cancellation and ownership tests retain their internal concurrent tasks and blocking boundaries. The package step is limited to 15 minutes in a 20-minute job; the independent app/host step has 30 minutes in a 35-minute job. See [CI reliability](CI_RELIABILITY.md) for the observed stall and validation scope.

CI now selects checks from the complete PR diff: app-only changes skip package tests while retaining app/host coverage, and lightweight checks run on Linux. Shared configuration changes and detection failures retain full verification. The [CI contract](CI.md) owns path routing, the stable final result, manual full runs and dependency-cache warming. Dependency caches do not replace builds or tests.

`MiraCompositionTests` compiles the production `MacLibrary`, storage owner and workload group directly into an independent test bundle. Run `xcodebuild -project Mira.xcodeproj -scheme MiraCompositionTests -configuration Debug -destination 'platform=macOS' -derivedDataPath .build/xcode -onlyUsePackageVersionsFromResolvedFile CODE_SIGNING_ALLOWED=NO test`. This suite uses synthetic model and notification ports with real journals and business databases. Both the `Mira` and `MiraHostTests` schemes include it; its independent success does not establish app or UI acceptance while legacy presentation callers are being replaced.

Opt-in live memory evaluation uses `MIRA_EVAL_CASE_IDS` (one to four fixture IDs) and a shared `MIRA_EVAL_DISPATCH_CAP`; the default cap is 4 and valid overrides are 1 through 12. The cap includes provider continuations and background extraction, so a run must record the selected IDs and effective cap with its evidence. Live evaluation requires an isolated schema 12 library, configured synthetic corpus, and a new report path; it is never part of the normal package or host test commands.

首次解析可使用 `swift package --package-path Packages/MiraKit resolve`。依赖升级时同时检查两个 `Package.resolved`。工程源配置为根目录 `project.yml`，新增 Host 文件后用 XcodeGen 2.46.0 生成并提交 `.xcodeproj` 与共享 Scheme。Core / Data / Providers 是 Swift Package 的三个库；测试只使用合成数据。

CI keeps package runtime coverage on `macos-15` / Xcode 26.3. App and host checks use `macos-26` / Xcode 26.6, matching the verified Icon Composer toolchain; the previous asset compiler crashed while compiling the layered icon. The [macOS 15 image](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-arm64-Readme.md) and [macOS 26 image](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md) document the installed Xcode paths. MarkdownView, ListViewKit and Litext remain pinned. The deployment target remains macOS 15; macOS 26 app tests do not establish native macOS 15 runtime acceptance. CI results and local results are recorded separately.

### 资料库与演示

- 正常资料库：`~/Library/Application Support/Mira/Mira.sqlite`，WAL / SHM 由 SQLite 管理。
- 本地凭据：Keychain 服务 `com.alwynou.mira.provider-credentials`；资料库仅含引用与版本。`credential-cleanup.json` 仅记录待清理引用，不含密钥，在启动及连接变更后重试处理。
- 仅 Debug 支持 `--demo`，使用 Fake Provider 并显示“本机演示”；未提供目录时创建独立临时目录。真实 Provider 失败不会自动转入演示。
- `--data-directory /absolute/path` 显式打开独立资料库。测试、演示与正常目录必须分离；切换前退出应用。

### 基础备份恢复

Settings → Data → Export Library Backup creates a new `.mirabackup` directory containing `Mira.sqlite`, `manifest.json`, and the exact referenced `Blobs`. The database snapshot uses SQLite Backup API; the exporter does not copy a live WAL main file or overwrite an existing destination. Keep the entire directory together.

Settings → Data → Restore to New Directory selects a backup bundle and a parent directory. Restore verifies bounded file reads and hashes before opening an owned staged database, then checks exact schema/constraints, integrity, foreign keys, typed values, and immutable chunk/blob relationships. It installs a new directory only after validation and leaves both the original backup and current library intact. Only schema v12 libraries and current-format bundles are supported; restored future task reminders are paused until the user resumes them. The Task / Reminder contract is in [Tasks and local reminders](../architecture/TASKS_AND_REMINDERS.md).

During development refactors, runtime data is disposable under the user's standing authorization. Stop affected Mira instances, remove obsolete development/test libraries and generated artifacts without making backups, and reuse the current development path. Do not accumulate schema-versioned directories or add migration/compatibility code. The app's explicit export/restore feature is a separate product behavior; it is not a required step in the development workflow.

The current M6 increment includes scoped tasks and optional one-time local reminders. The Core contract is implemented under `MiraCore/Records`, persistence uses the schema 12 task tables, the macOS adapter uses `UserNotifications`, and notification permission is requested only from the Tasks UI. Recurring reminders, Apple Calendar / Reminders projection, and a background helper are outside this increment. Deterministic package evidence and remaining native acceptance belong in [Task / Reminder verification](FUNCTIONAL_MILESTONES_VERIFICATION.md).

验证恢复后的目录可以先在隔离环境打开：

```sh
open .build/xcode/Build/Products/Debug/Mira.app --args \
  --data-directory /absolute/path/to/Mira-Restored-directory
```

Opening a restored directory does not send requests, reauthorize external files, or replay executions. Automatic memory capture is disabled in the restored copy, and uncertain extraction work is paused. Credentials are not included and must be reconfigured when unavailable. One-click switching between libraries remains deferred. The cleanup action removes only unreferenced managed files after at least seven days; retained historical source versions remain referenced, and previous backup copies are not rewritten.

## 流式 Markdown 依赖

MiraMac uses MarkdownView's `MarkdownView` and `MarkdownParser` products with ListViewKit's virtualized AppKit list and Litext's text rendering API. ListViewKit is a local macOS fork under `Vendor/ListViewKit`, with the upstream revision and native scroll-backend changes recorded in `README.mira.md`. Other direct package revisions are pinned in `project.yml` and the generated Xcode lock file; MiraKit does not import these UI dependencies. Their transitive packages include Highlightr, SwiftMath, LRUCache, swift-cmark, swift-collections, and MSDisplayLink. Attribution and bundled font / highlight.js notices are in [第三方说明](THIRD_PARTY.md) and the app resource.

Conversation presentation coalesces runtime text and thinking snapshots at 100 ms before publishing observable state. Authoritative reloads, terminal messages, selection changes, and privacy clears replace pending presentation state immediately. Stable transcript rows retain their renderer. Appended paragraph text uses a display-only 500 ms fade with up to 100 ms of word staggering; animation ticks neither mutate attributed text nor invalidate intrinsic size, and completion removes fade markers from the current document without restoring stale attachment reservations. Initial and completed snapshots render immediately, and Reduce Motion disables fades. The composer observes its own input independently from transcript content. Streaming growth now preserves reading position without auto-follow. Current surface, typography, and navigation verification are documented in [floating composer](FLOATING_COMPOSER.md); the original renderer measurements remain in [renderer replacement](RENDERER_REPLACEMENT.md).


The current native-app rendering health check is `python3 scripts/run_rendering_benchmark.py --output /absolute/new-report.json --expand-thinking` after a Debug build. It runs a disposable app/library and removes them on exit. Its main-actor queue samples are not displayed frame-rate measurements; current evidence is in [Renderer replacement](RENDERER_REPLACEMENT.md).
