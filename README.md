# Mira

Mira 是一个面向个人的本地优先 AI 助理、Agent 工作空间与个人记忆知识系统。通过用户自带的模型访问能力（BYOK），它连接多个模型服务商，将对话、工具执行与长期知识组织为可追溯、可纠正的个人工作空间。

项目采用原生 Swift，面向 macOS 15 及后续版本，直接下载安装；未来考虑 iOS。

> 工作分支为 `dev`。工程基础与首批可恢复文本对话已实现，完整 v0.1 MVP 仍在开发。当前支持连接设置与合成能力探测、Workspace / Inbox、流式 Markdown 对话、取消 / 重试、草稿恢复、逐次请求审计与基础备份。最小工具循环已有实现及合成测试；记忆与文件检索工具将在 M3 / M4 开放。实际验证范围见 [实施与验收记录](docs/engineering/IMPLEMENTATION_STATUS.md)。

## 构建与运行

使用 Xcode 26.3 或更高版本（Host 的 Markdown 依赖要求 Swift 6.2+），启用 Swift 6 语言模式，目标 macOS 15+。本机已验证 Xcode 26.6 / Apple Silicon；CI 固定 Xcode 26.3。

```sh
swift test --package-path Packages/MiraKit
xcodebuild -project Mira.xcodeproj -scheme Mira -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath .build/xcode \
  -onlyUsePackageVersionsFromResolvedFile -skipMacroValidation CODE_SIGNING_ALLOWED=NO build
open .build/xcode/Build/Products/Debug/Mira.app
```

也可打开 `Mira.xcodeproj`，选择共享 Scheme `Mira` 运行。工程已提交；修改 `project.yml` 或文件组织后，使用 XcodeGen 2.46.0 执行 `xcodegen generate`。

首次启动在设置中添加 OpenAI Chat Completions 兼容连接或 Anthropic Messages 连接，填写 Model ID、API Key、上下文窗口与输出上限。未知窗口可以保存，但发送前须补齐；保存配置不会自动调用模型。API Key 仅保存在本机 Keychain。设置中的能力检测由用户主动触发，只发送固定合成提示，可能产生少量 API 费用。

无密钥演示仅在 Debug 构建中显式启用，使用隔离目录，不发送网络请求：

```sh
open .build/xcode/Build/Products/Debug/Mira.app --args \
  --demo --data-directory /tmp/mira-demo
```

切换运行模式或资料库前先退出当前 Mira。快捷键：`⌘ N` 新对话、`⌘ Return` 发送、`⌘ .` 停止、`⌘ ,` 设置。数据路径、恢复步骤和已知限制见 [开发约定](docs/engineering/DEVELOPMENT.md)。

## 核心方向

Mira 首先验证一条完整路径：用户形成值得记住的认知 → 保存来源与范围 → 在新对话中恰当召回 → 查看来源 → 编辑、撤销或遗忘。

本地数据库与文件保存规范数据，用户配置自己的 Provider 和凭据。Conversation 保存原始交流，Execution 记录如何执行，Memory 与 Knowledge 保存可复用的认知和资料；检索、摘要与索引具有明确的派生关系。

首个 MVP 包含对话、可纠正记忆、Markdown 文件检索与最小 Agent 工具循环，首批支持 OpenAI Chat Completions 兼容接口与 Anthropic Messages。任务和提醒紧随其后；具体版本边界以 MVP 文档为准。

## 阅读顺序

| 入口 | 职责 |
|---|---|
| [产品总纲](docs/PRD.md) | 定位、目标用户、产品不变量与成功标准 |
| [架构总览](docs/ARCHITECTURE.md) | 系统结构、模块依赖、架构不变量与并发所有权 |
| [MVP 拆分](docs/MVP.md) | 首版范围、M0–M6 依赖、交付内容与退出条件 |
| [开发约定](docs/engineering/DEVELOPMENT.md) | 平台、工具链、工程结构、直接分发与协作方式 |
| [质量标准](docs/engineering/QUALITY.md) | Fixture、记忆评估、性能与发布门槛 |
| [开发前评审](docs/reviews/2026-09-05-DOCUMENT_REVIEW.md) | 发现的问题、修正位置、已确认决策与待验证证据 |
| [实施与验收记录](docs/engineering/IMPLEMENTATION_STATUS.md) | 已实现的增量、实际检查、剩余验收项 |
| [参考资料](docs/REFERENCES.md) | 外部借鉴边界与官方依据 |

详细规则按职责维护，同一状态机、字段表或验收阈值只在一个文件中完整定义。

## 领域文档

| 领域 | 产品行为 | 技术设计 |
|---|---|---|
| 工作空间与对话 | [用户场景与交互](docs/product/WORKSPACE_AND_CONVERSATION.md) | [Runtime](docs/architecture/RUNTIME.md) |
| 记忆与知识 | [记忆、知识与纠正体验](docs/product/MEMORY_AND_KNOWLEDGE.md) | [领域模型与处理管线](docs/architecture/MEMORY_AND_KNOWLEDGE.md) |
| Agent、Provider 与 Context | [用户可见行为](docs/product/AGENT_AND_CONTEXT.md) | [Provider](docs/architecture/PROVIDERS.md)、[Context](docs/architecture/CONTEXT.md) |
| 任务、提醒与其他记录 | [记录语义](docs/product/RECORDS.md) | [结构化数据与通知](docs/architecture/STRUCTURED_DATA.md) |
| 数据与隐私 | [生命周期与隐私承诺](docs/product/DATA_AND_PRIVACY.md) | [存储与恢复](docs/architecture/DOMAIN_AND_STORAGE.md)、[平台与安全](docs/architecture/PLATFORM_AND_SECURITY.md) |
| 本地检索 | 见记忆与知识规范 | [Search](docs/architecture/SEARCH.md) |

## 技术基线

`MiraMac` 负责 SwiftUI / AppKit 界面与平台适配；`MiraCore` 负责领域、用例与对话运行时；`MiraData` 实现 GRDB / SQLite 存储；`MiraProviders` 适配两类模型协议。知识逻辑、检索与 Blob 存储按后续里程碑加入。

助手消息使用微软 SwiftStreamingMarkdown v0.7.0 渲染；宿主按对应提交锁定依赖，禁用远程图片与未验证引用。构建时仅对已审阅的固定依赖使用 `-skipMacroValidation`；依赖与许可证见 [第三方说明](docs/engineering/THIRD_PARTY.md)。

Core 定义接口，外层实现适配。UI 不直接访问数据库或调用 Provider，Core 不依赖 Apple UI 或 GRDB 实现。Mira 不建设自有业务后端。

## 仓库结构

```text
mira/
├── AGENTS.md
├── README.md
├── project.yml
├── Mira.xcodeproj/
├── Apps/MiraMac/
├── Packages/MiraKit/
│   ├── Package.swift
│   ├── Package.resolved
│   ├── Sources/{MiraCore,MiraData,MiraProviders}/
│   └── Tests/
├── .github/workflows/ci.yml
└── docs/
    ├── PRD.md
    ├── ARCHITECTURE.md
    ├── MVP.md
    ├── REFERENCES.md
    ├── product/
    ├── architecture/
    ├── engineering/
    └── reviews/
```

架构文档包含后续目标，具体完成情况以实施记录为准。当前构建用于本机开发验证，尚未制作签名、公证的下载发行包。
