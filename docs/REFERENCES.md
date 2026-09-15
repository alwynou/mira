# 外部参考与官方验证来源

**更新日期：** 2026-09-05  
**职责：** 记录借鉴边界与外部依据；不代替 Mira 的产品规范、接口契约或实际验收。

## 1. 参考设计

| 来源 | 借鉴内容 | Mira 的边界 |
|---|---|---|
| [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) | Turn / Step、追加执行日志、工具管线、Provider 契约、压缩投影 | 使用 Swift 与静态组装；不复制动态插件生命周期，不永久保留临时检索，不强制 Compact 使用主模型 |
| [Nowledge Mem](https://mem.nowledge.co/zh/docs/memories) | 原始交流与 Atomic Memory 分离、Working Memory、Evidence 与知识演化 | 清晰用户陈述可自动生效并可撤销；推断 / 敏感 / 冲突进入候选；不照搬服务端或所有内容排队审核 |
| [Obsidian](https://obsidian.md/help/links) | Markdown、Wiki Link、Backlink 与本地知识组织 | SQLite / Blob 是规范存储；外部 Vault 只导入导出，不形成实时双向事实源 |

原始文档提供的设计参考链接保留如下；本轮重点核验实现边界，未将这些外部项目的全部内容重新审计为当前规范依赖：

- DeepSeek：[Agent Loop](https://github.com/deepseek-ai/deepseek-harness/blob/master/packages/core/agent-loop/README.md)、[Session](https://github.com/deepseek-ai/deepseek-harness/blob/master/packages/core/session/README.md)、[Tools](https://github.com/deepseek-ai/deepseek-harness/blob/master/packages/core/tools/README.md)、[Compaction](https://github.com/deepseek-ai/deepseek-harness/blob/master/packages/compaction/compaction/README.md)、[Compaction Basic](https://github.com/deepseek-ai/deepseek-harness/blob/master/packages/compaction/compaction-basic/README.md)。
- Nowledge Mem：[AI Context](https://mem.nowledge.co/zh/docs/ai-context)、[Knowledge Graph](https://mem.nowledge.co/zh/docs/knowledge-graph)、[Search Architecture](https://mem.nowledge.co/zh/docs/concepts/search-architecture)、[Background Intelligence](https://mem.nowledge.co/zh/docs/concepts/background-intelligence)。
- Obsidian：[Graph View](https://obsidian.md/help/plugins/graph)。

## 2. 本轮核验的官方依据

以下“依据”来自官方资料；其后的 Mira 决策是针对本项目的设计判断，不宣称由外部文档自动决定。

| 依据 | 核验内容 | Mira 决策与归属 |
|---|---|---|
| [Apple：macOS Sequoia 发布](https://www.apple.com/newsroom/2024/09/macos-sequoia-is-available-today/) | macOS Sequoia 在 2024 年发布 | 用户要求“2024 年及之后的 macOS”映射为最低 macOS 15；见开发约定 |
| [Apple：App Sandbox](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox) | App Store 分发要求沙箱；沙箱限制多种平台行为 | 当前采用直接分发的非沙箱 Host，应用自身仍逐项校验授权；不能把“非沙箱”当作用户授权 |
| [Apple：文件访问与 Bookmark](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox) | 沙箱内持久访问使用 Security-scoped Bookmark，恢复后管理访问生命周期 | 将沙箱 / 非沙箱 Bookmark 行为放在平台 Adapter，处理失效和权限撤销 |
| [Apple：本地通知](https://developer.apple.com/library/archive/documentation/NetworkingInternet/Conceptual/RemoteNotificationsPG/SchedulingandHandlingLocalNotifications.html) | 已调度通知由系统处理，应用不运行时仍可交付 | 将 Agent 后台运行与已提交系统通知分开描述；实际展示受系统条件影响并须真机验收 |
| [OpenAI：Function calling](https://developers.openai.com/api/docs/guides/function-calling) | 应用执行工具，并用对应调用标识回传结果；Chat Completions 与 Responses 有不同协议 | 保存完整工具交换；首版明确 Chat Completions 兼容范围，Responses 另建 Adapter |
| [Anthropic：Handle tool calls](https://platform.claude.com/docs/en/agents-and-tools/tool-use/handle-tool-calls) | tool_result 需与 tool_use 正确配对并满足消息顺序 | 不为节省上下文单独移除一侧，也不跨回合留下孤立 tool_result |
| [SQLite：FTS5](https://www.sqlite.org/fts5.html) | trigram 全文查询不匹配少于三个 Unicode 字符的子串，部分模式会扫描 | 两字中文有显式回退与扫描 / 时间上限，启动时探测实际 SQLite 能力 |
| [GRDB 官方 README](https://github.com/groue/GRDB.swift/blob/master/README.md) | 当前文档列出 7.11.1；提供事务、观察、迁移及数据库备份能力 | 以已核对版本为候选，建工程时锁定依赖；数据库备份采用 API，与 Blob 在受控窗口一致保存 |

## 3. 平台与存储的进一步实现参考

- [EventKit](https://developer.apple.com/documentation/eventkit)、[创建日程和提醒](https://developer.apple.com/documentation/eventkit/creating-events-and-reminders)：只作为外部副本适配，不反向覆盖 Mira 业务事实。
- [UserNotifications](https://developer.apple.com/documentation/usernotifications)：本地通知实现和权限；不把调度成功等同于用户已经看到。
- [Keychain Services](https://developer.apple.com/documentation/security/keychain-services)：凭据保存，普通数据库只持引用。
- [macOS 软件公证](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)：直接分发的软件签名与公证流程，具体产物在发布时验证。
- [CKSyncEngine](https://developer.apple.com/documentation/cloudkit/cksyncengine)：未来同步候选，尚未选择为当前依赖。
- [SQLite WAL](https://www.sqlite.org/wal.html)、[SQLite Application File Format](https://www.sqlite.org/appfileformat.html)：原始设计的本地存储参考。

## 4. 本机探测证据的范围

2026-09-05 读取到：macOS 26.6.2、arm64、Xcode 26.6、Swift 6.3.3。系统 sqlite3 CLI 报告 SQLite 3.51.0；内存 FTS5 trigram 表中，“长期记”匹配合成文本，“记忆”不匹配。

随后在本机创建并运行 Mira，应用“设置 → 数据”的独立内存探测同样报告 SQLite 3.51.0，FTS5 与 Trigram 均可用。这证明当前 App 在这台机器上的链接行为；不能据此宣称 macOS 15 UI、Intel 或真实 Provider 已验证。证据和后续范围见 [实施记录](engineering/IMPLEMENTATION_STATUS.md)。

## 5. 接口实现依据

- [OpenAI Chat Completions API](https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create)：文本流、finish_reason、可选 include_usage 与末尾用量事件；当前兼容 Adapter 保留未提供用量的未知状态。
- [Anthropic Streaming Messages](https://platform.claude.com/docs/en/build-with-claude/streaming)：message / content block 事件、累计用量与 message_stop；当前 Adapter 将不完整流与正常结束区别处理。
- [GitHub macOS 15 镜像](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-arm64-Readme.md)：CI 固定 Xcode 16.4 路径；运行证据单独记录。
