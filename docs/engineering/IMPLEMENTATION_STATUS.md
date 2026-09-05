# 实施与验收记录

日期：2026-09-05。分支：`dev`。本文件记录已经写入代码的增量、验证证据与剩余工作；产品和架构规范仍由各自文档负责。

## 1. 本次交付

| 范围 | 实现 |
|---|---|
| M0 工程 | AGENTS.md、XcodeGen 源配置、Xcode 工程 / 共享 Scheme、MiraCore / MiraData / MiraProviders 三个库、精确 GRDB 依赖锁、Git ignore、GitHub Actions |
| M0 存储 | 命名迁移、WAL、外键、单对话活动执行与消息序号约束、修订冲突、临时资料库与 SQLite / FTS5 探测 |
| M1 对话 | Workspace / Inbox、项目背景与发送开关、对话创建 / 归档、SwiftStreamingMarkdown 流式渲染、取消、最后失败回合重试、本地历史与草稿恢复 |
| M1 Provider | OpenAI Chat Completions 兼容接口与 Anthropic Messages、手工 Model ID / 窗口 / 输出上限、文本 / 工具独立合成检测、Keychain 引用与版本 |
| M1 异常边界 | UserMessage + queued Execution 原子提交、网络前落盘请求、每 250 ms 或 4 KiB 草稿检查点、唯一终态、保留部分回复、保存失败重试、退出期间禁止新请求 |
| M1 数据 | SQLite Backup API 导出、原备份只读使用（校验操作在暂存副本）、拒绝错误结构 / 约束、恢复到新目录、未知用量显示“服务未提供” |
| M2 工具基础 | 不可变注册表、受限 Schema、默认写入拒绝、多步模型调用、完整交换、并行安全 / 独占屏障、拒绝 / 超时 / 取消回执、Step / Attempt 审计 |
| M2 限额与恢复 | 每回合 20 Step / 32 Tool / 4 并行工具、Token 输出预留与完整上下文预算、活动期限、无进展检测、v1 → v2 迁移和包含审计的备份恢复 |

当前生产工具注册表为空。记忆保存与 Markdown 资料导入检索按 M3 / M4 开放；M2 的工具调用通过独立合成 Fixture 验收，不在真实对话中假装执行尚未实现的业务工具。

## 2. 实际验证

最新增量的父代理验收见 [M2 验证记录](M2_VERIFICATION.md)。下表保留 M0 / M1 首次基线证据，避免将历史 CI 误当本次实现验证。

本机环境：macOS 26.6.2、Apple Silicon、Xcode 26.6、Swift 6.3.3。目标系统为 macOS 15。

| 检查 | 结果 / 证据 |
|---|---|
| Swift Package 全套测试 | 父代理独立执行，39 个测试 / 3 个 Suite 全部通过；包含参数化 HTTP 状态场景 |
| macOS Debug / Release 构建 | 两个配置均通过 `xcodebuild ... -onlyUsePackageVersionsFromResolvedFile CODE_SIGNING_ALLOWED=NO build`；版本 0.1.0，最低系统 15.0 |
| 实际 App 链接的 SQLite | 设置 → 数据显示 SQLite 3.51.0，FTS5 与 Trigram 均可用 |
| 本机 UI 演示 | 隔离目录运行；已验证真实增量显示、停止 / 部分回复、重试入口、退出重开后的列表、工作空间创建与发送阻断、请求详情、设置与诊断；未调用付费接口 |
| GitHub Actions | 实现提交 `60ed016` 在 macos-15 / Xcode 16.4 上测试与应用构建均通过：[运行 33955793659](https://github.com/alwynou/mira/actions/runs/33955793659)，耗时 1 分 34 秒 |

测试重点包括：拆分 UTF-8 / SSE、半途断流、终止标记与 EOF 区别、输出上限、累计 / 缺失用量、安全错误、重定向拒绝、单个请求取消不影响相同输入的另一个请求、队列溢出明确失败；原子回滚、两连接竞争、最后失败回合重试、唯一终态、恢复幂等、迁移失败保护、备份结构和原文件保护；当前输入只出现一次、仅成功替代回复进入历史、Workspace 内容隔离、保存失败保留内存结果并可重试。

子代理使用用户指定的 GPT-5.6 Luna，按存储、Provider 和只读复核划定文件边界。父代理审查并要求修复了整段缓存流、旧执行可重复重试、备份源写入、约束校验缺失、并发请求取消串扰等问题，并独立重跑检查。工具没有独立 fast 参数，未将其记录为已单独启用。

## 3. M1 的后续验收

1. 合成文本 / 工具探测与状态持久化已实现；继续验证真实端点，不把合成 Fixture 通过当真实兼容性记录。未知窗口与不足预算在请求前阻止检测。
2. 将当前对话用的扁平 `ModelRoute` 拆为 Connection / ModelDescriptor / 用途路线；补全 Workspace / Conversation 覆盖与端点政策，再开放其他用途。当前不自动跨 Provider 回退。
3. Keychain 已实现写前引用清理登记、提交后或启动时重试清理；仍需覆盖 Keychain 锁定 / 拒绝 / 清理失败的独立平台测试与真实凭据演练。
4. 完成多窗口与键盘 / 可访问性流程验收、恢复目录切换体验、实际端点兼容性记录。当前费用尚未估算。

这些条目使 M1 保持“进行中”。M2 不依赖真实密钥的工具管线与审计基础已并行实现；生产注册表继续为空，实际业务工具按后续领域验收再开放。

## 4. 实现范围与设计目标的关系

- 当前一个 Execution 代表一个用户回合，可包含多个 Step。每个 Attempt 在发送前保存独立 ID 与完整请求；旧版 request 查询兼容返回最新请求。每个工具提案和回执持久化，终态保持唯一。
- 当前输入预算采用 UTF-8 字节数、协议开销与安全余量的保守估算，超预算提示新建对话，不静默截断或伪造精确 Tokenizer。
- v2 Schema 增加 Step / Attempt / ToolInvocation。Message 仍使用受约束的纯文本列；Typed Parts、Blob、Memory、Source 等按实际里程碑迁移加入。
- Provider 请求默认 HTTPS，HTTP 仅在明确配置的 loopback 范围开放；每个请求都有不含内容的唯一标识用于取消。原生输送层拒绝重定向，凭据不进入请求快照或备份。
- 保存失败时保留当前回复并提供“重试保存”；仍有未保存回复时普通退出会被取消。进程强制终止只能恢复最后一个已落盘检查点。

## 5. 尚未获得的发布证据

未完成真实 Provider / Keychain 演练、macOS 15 本机 UI、Intel、7 天使用、完整记忆质量评估、Blob 恢复、签名、公证或下载包安装升级测试。CI 在 macOS 15 上执行包测试和应用编译也不等同于这些 UI 与发布验收。当前版本仅作为本机开发增量。M2 尚有独立构建失败 Step、自动 Attempt 重试与人工确认 UI 等完整设计项，当前未注册依赖这些能力的生产工具。
