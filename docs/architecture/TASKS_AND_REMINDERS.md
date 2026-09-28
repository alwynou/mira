# 任务与本地提醒

本文拥有任务领域的技术契约，产品含义见 [Records](../product/RECORDS.md)。任务模块直接使用新的 Agent 核心，不再关联旧 SQL 会话表。当前 macOS 宿主已接入任务管理读写用例与资料库归档／恢复路径；本次原生管理验收见验证记录；更广泛发布质量、完整遗忘与整库备份边界仍保留独立验收门槛。

任务模块同时在自己的作用域注册 `tasks` 来源权威，通过 `TaskReadStore` 检查当前工作区与修订。上下文携带真实冻结目的地，工作区／模型配置政策由生产 `SQLiteAgentContextPolicy` 复核；来源版本和调用生命周期遵守[来源授权契约](AGENT_SOURCE_AUTHORIZATION.md)。

## 领域边界

`MiraTask` 保存工作区、标题、备注、可选截止时间、状态、修订号及一次性提醒。Inbox 与每个工作区分别查询；完成和取消保留修订历史，重新打开是显式操作。截止时间本身不会启用通知。

`TaskModule` 在所属运行时作用域注册 `task.list` 与 `task.change`。它只依赖 Foundation 和领域读取端口；不认识 SQLite、通知中心或平台。`TaskApplication` 提供人工保存、提案审核与恢复提醒的用例，不拥有 Agent loop，也不模拟模型工具调用。

`SQLiteTaskStore` 实现领域记录端口，`SQLiteTaskCommandHandler` 在共享业务事务中处理模型变更。工作区由 `SQLiteWorkspaceStore` 拥有，当前模型身份由 `SQLiteAgentModelSettings` 校验。平台只需实现 `LocalNotificationPort`；macOS 使用系统通知服务，iOS 当前不实现。

### 管理读取与编辑

Tasks 管理读取严格区分 Inbox（`workspaceID == nil`）与 Workspace；列表状态支持 `all`、`active`、`open`、`inProgress`、`completed` 和 `cancelled`。标题与备注搜索先做 Unicode 兼容形式、大小写、变音符号和全半角规范化，再进行字面匹配；管理界面每页读取 50 行及一行前瞻（领域端口允许 1–200 行），不把结果静默截断在首 100 或 200 条。任务、历史修订和待审核 Proposal 分别使用有界分页与当前作用域校验；原始消息通过完整证据引用导航。

macOS 管理界面使用 320 pt 任务列表、790 pt 紧凑布局断点和 620 pt 详情内容上限。详情编辑保留修订草稿，提交时以修订号进行 CAS；冲突要求刷新，不覆盖新版本。Proposal 审核位于独立 Needs review 区域：接受会重新读取完整 journal 证据，拒绝不需要重新披露原文，重复审核返回冲突，需澄清的提醒必须确认精确时间。截止日期与提醒时间独立；提醒权限、重试、暂停、恢复和 elapsed 状态分别保持真实。标题或备注编辑若不改变提醒时刻，会保留恢复后的 paused 状态；显式恢复才进入 pending，改变提醒时刻才重新安排。

```mermaid
flowchart TB
  Host[平台组合根与任务界面] --> App[TaskApplication 人工用例]
  Host --> Reminder[ReminderScheduler 提醒协调]
  Kernel[平台无关 Agent 执行内核] --> Module[TaskModule 作用域工具]
  Module --> Read[TaskReadStore 读取端口]
  App --> Store[TaskStore 领域记录端口]
  App --> Reader[JournalSessionReader 原始证据]
  Kernel --> Effects[业务副作用与回执关口]
  Effects --> Handler[SQLiteTaskCommandHandler]
  Handler --> DB[共享业务库：任务／工作区／模型配置／回执]
  Read --> DB
  Store --> DB
  Reader --> Journal[权威 JSONL 与正文]
  Reminder --> Store
  Reminder --> Port[LocalNotificationPort]
  Port --> Mac[macOS 通知适配器]
  Access[库授权与作用域租约] -.-> App
  Access -.-> Kernel
  Access -.-> Reminder
```

[架构图 SVG](diagrams/agent-task-architecture.svg) · [PNG](diagrams/agent-task-architecture.png) · [Mermaid 源码](diagrams/agent-task-architecture.mmd)

## 原始证据与授权

`TaskEvidence` 必须包含完整 `SessionEvidenceReference`：会话、原始执行、用户消息、接纳事件与序列、正文引用；同时保留完整引文、原始时间和 IANA 时区。没有只有 message ID 的构造器、旧格式解码器或 SQL 消息外键。证据由 `JournalSessionReader` 读取已确认日志前缀取得；重试仍引用最初接纳的消息和时钟。

原始证据是来源定位，不是当前权限。库访问租约保护读取和实际工作生命周期；业务事务再次检查库身份、授权代次及待执行维护记录。工具事务同时复核当前工作区出站策略、连接白名单、冻结路线各层身份与版本，以及任务目标修订号。模型参数不能授予权限。

`task.change` 的 quote 必须与完整接纳消息一致。只有明确、来源中可定位标题／备注及时间的受支持命令才直接提交；模糊意图或需要澄清的时间保存独立提案。现有任务必须提供当前工作区内的 ID 和修订号；工具说明要求先通过 `task.list` 查询。过期目标不会覆盖新修订。

Task context sources refer to exact retained immutable revisions. The source authority requires the current task to remain accessible in the requested workspace and resolves the referenced revision directly through `TaskReadStore.taskRevision`; it does not search the latest-100 revision list. This allows `task.list` → `task.change` → final reply to retain the original list evidence after the mutation creates a new revision. Missing revisions and cross-workspace references remain unauthorized. `TaskListTool` still checks freshness before returning its captured list, and mutation preparation/SQL commit still require an exact current target revision. Historical read authority never grants stale write authority.

人工接受提案时，`TaskApplication` 根据提案中保存的完整引用重新读取 journal，领域事务核对完整证据、工作区和当前库授权。失效或已删除的原始证据不能通过复制的 quote 恢复授权。拒绝提案无需再次披露原文。接受／拒绝是一次状态转换，重复审核返回冲突。

## 提交与回执

模型写入由 `SQLiteBusinessEffects` 在同一事务提交任务或提案、修订、业务操作结果、调用回执和待发布记录。处理器不能另起事务、访问会话投影、调用模型或安排系统通知。跨存储发布失败由通用回执结算处理，不再次执行领域写入。

业务键包含完整原始证据引用和规范化命令参数。相同来源的重复创建调用共享原业务结果，每个调用仍有自己的回执；不同会话即使使用同一 message UUID 也不会误去重。已完成调用可查询原持久回执用于结算。现有目标的每次新准备仍要求当前修订；不能以去重为由放宽目标 CAS。

人工保存使用单独的显式 operation ID，并将完整请求、任务修订和结果原子保存。相同 ID／相同请求返回原结果；相同 ID／不同请求冲突。

工具输入与输出都使用内核支持的明确 schema 和大小限制。`task.list` 最多返回 50 个任务，结果在 24,000 字节内截取完整条目，附上真正返回的领域来源；到达条目或字节界限时标记 truncated。摘要备注最多 512 个 Unicode scalar。未设置的 due_at／reminder_at 省略，不能用无界对象声明绕过输出验证。

```mermaid
flowchart TD
  Admit[日志接纳：用户正文／原始时间／时区／执行计划] --> Model[模型提出 task.change]
  Model --> Prepare[模块规范化参数并准备目标]
  Prepare --> Guard[内核权限与持久意图／派发关口]
  Guard --> Recheck[解析原始证据；事务复核库／工作区／路线／目标]
  Recheck --> Direct{明确且完整的受支持命令？}
  Direct -->|是| Save[任务与修订]
  Direct -->|否| Proposal[待审核提案]
  Save --> Receipt[同事务：业务结果／回执／待发布记录]
  Proposal --> Receipt
  Receipt --> JournalResult[日志工具结果与模型续接]
  Proposal --> Review[人工审核重新解析原始证据]
  Review --> Confirm[显式修正时间；CAS 接受或拒绝]
  Confirm -->|接受| Desired[任务的提醒期望状态]
  Confirm -->|拒绝| Rejected[只记录拒绝状态]
  Save --> Desired
  Desired --> Reconcile[独立提醒协调]
  Reconcile --> Install[平台通知调用]
  Install --> Observe[核对系统待发通知与任务修订]
  Observe --> Delivery[记录实际调度状态或重新协调]
```

[执行图 SVG](diagrams/agent-task-flow.svg) · [PNG](diagrams/agent-task-flow.png) · [Mermaid 源码](diagrams/agent-task-flow.mmd)

## 时间解释

相对日期与时区来自 journal 的最初接纳，不取工具运行时间或审核时机器的当前时区。`task.list` 即使列表为空，也返回这个 reference_time 与 time_zone；模型应使用该时钟，不为确定提醒日期调用 Bash 或猜测工作目录。`task.change` 接受本地 HH:mm，以及 YYYY-MM-DD 或相对 day_offset 之一。

`TaskTimeResolver` 使用严格 Gregorian 匹配，比较夏令时重叠的两种可能值。无效日期、DST 空隙或重叠要求审核，不静默选择一次发生。直接提交还要将原文时间表达式与模型参数核对。现有英文／中文规则覆盖常见今天、明天、数字时刻和整点上下午；其他表述保留待审核提案。循环与条件提醒明确不支持，不降级为一次性通知。

仅省略日期、但时刻和事项明确的普通提醒命令（例如“提醒我下午6点取快递”或“remind me at 6pm to review notes”），按原始消息所在时区的当天解释，`day_offset` 为 0；省略该参数也使用同一规则。这个时刻必须晚于原始消息时间和实际提交时间。已过期的时刻进入审核，不自动顺延到明天；跨午夜重试仍锚定原始消息日期。识别先排除日期／相对日期限定，再核对移除字面标题、备注和时间引文后的普通命令框架；未支持的限定语、相互冲突的日期、否定、引用和假设仍进入审核。

待审核工具结果包含有界 `review_reason` 和可操作的英文消息，区分意图、目标、详情、缺失／歧义时间、时间来源不匹配和时间已过期。消息明确没有提交任务或通知，工具说明要求模型据此说明下一步，不误报为通用系统故障。提醒的时间类失败同步设置 `requires_time_clarification`，接受时要求显式修正；仅截止日期的提案不因此自动启用提醒。原因是当前工具结果，不增加第二份持久提案或改变存储格式。

未确定提醒时间的提案，必须由用户选择确切未来时间后才可接受。编辑过去的提醒也需要新的未来时间。`TaskIntentPatterns.json` 中的中文是有意保留的用户语言识别数据，不是本地化提示词；代码标识、工具说明和诊断保持英文。

## 系统调度与工作所有权

`ReminderScheduler` 接收必需的库访问关口和运行时作用域，合并并发 reconcile，请求重跑后继续串行收敛。系统授权只经显式 requestPermission 操作申请，调用本身也由调度器拥有。测试仅注入合成通知端口。

每个实际操作都在租约的 resource factory 内创建任务。取消和撤权会发出取消信号，资源清理等待真正的通知调用返回；不会用外层 Task 已取消假装平台工作已经退出。close 拒绝新增工作并排空已接纳操作。维护协调器必须先关闭所属工作组再清理通知；普通 close 不删除已经存在的通知。

通知标识由精确库 namespace 与稳定 task ID 组成。孤儿清理必须匹配整个 namespace 前缀并单独确认任务不存在；没有出现在有限工作页不等于已删除。任务修订更新使旧系统观察失效；安装后核对 pending 列表，再以修订 CAS 写入观察结果。竞争修改时移除旧请求并重跑。取消／撤权不是伪造的系统调度失败。

记录状态与系统观察分离：

| 状态 | 含义 |
|---|---|
| pending | 已保存，尚未确认系统调度 |
| scheduled | 系统接受了这一任务修订 |
| permissionRequired | 已保存，但通知权限不可用 |
| failed | 调度失败，可重试 |
| elapsed | 触发时刻已过，不能证明用户看到通知 |
| paused | 恢复的提醒，等待显式启用 |
| cancelled / none | 不应继续保留已安排提醒 |

最多接纳 60 个未来活动提醒。无后台 helper、循环引擎、EventKit、同步或日历发布。原生退出后送达、专注模式及系统权限提示仍需平台验收；mock 成功不证明这些行为。

## 存储与宿主集成

任务使用独立 task_schema 版本 1，拥有 mira_tasks、task_revisions、task_proposals、task_operations；工作区使用独立 workspace_schema 和 business_workspaces。数据库必须启用外键与 FULL 或 EXTRA 同步，结构不符明确拒绝。任务数据没有 messages、conversations、executions、message_time_context 表依赖。

领域端口的已接纳 SQL 由适配器持有，close 排空实际队列而不关闭共享数据库。`MacLibraryStorage` 拥有任务存储，`MacLibraryWorkloads` 拥有可替换的任务用例与提醒协调器；界面不直接读取数据库。

`SQLiteTaskArchive` 已接入资料库归档、恢复和跨领域来源校验，任务维护路径处理来源清理与通知退役。恢复后的活动提醒改为 paused，不自动重新排程。当前实现不使用旧 SQL 资料库、双写或兼容回退。Tasks 管理增量的证据与未验证范围见 [Task management verification](../engineering/TASK_MANAGEMENT_VERIFICATION.md)；历史归档与恢复证据见 [核心验证记录](../engineering/AGENT_CORE_VERIFICATION.md)。
