# 核心扩展挑战验收

<!-- Simplified Chinese documentation is explicitly requested by the user on 2026-09-12. -->

本记录对应[核心方案第 11 节](../architecture/AGENT_CORE_PROPOSAL.md#11-可扩展性验收与范围)的六类扩展挑战。基线为 `789811a`，分支为 `codex/agent-core`。这里只关闭这组扩展案例，不代表整个 P6、规模性能或原生产品验收完成。

## 扩展实现与证据

新增三个测试文件。每个文件仅普通导入 `MiraCore`、`MiraData`，没有使用 `@testable`、私有内核初始化器或内部状态写入。工具和提供方测试复用已有 `TaskWorkflowFixture` 创建隔离资料库、真实权限和配置存储；随后关闭其原运行时，以新模块、新调度器和新审批服务重新组装 `AgentApplicationRuntime`。既有夹具自己的测试导入没有被用来绕过新扩展的公开接口。

| 挑战 | 独立实现与实际验证 |
|---|---|
| 输入／输出契约、审批和业务回执 | [AgentToolContextChallengeTests.swift](../../Packages/MiraKit/Tests/MiraDataTests/AgentToolContextChallengeTests.swift) 注册 `challenge.counter.increment`，独立领域表和事务处理器递增计数。批准前计数为零；批准后计数为三且结果关联实际 invocation 回执。业务提交后注入确认丢失，核对既有回执并清空待发布项；重复命令和两次查询投影重建均不再执行写入或模型。输入越界以 `invalidArguments` 结算且不请求审批；输出不符合 schema 时计数与回执一起回滚。 |
| 自有来源策略和生命周期的上下文模块 | 同文件注册独立来源权威与贡献器。正文作为 `.context` 数据传给模型，可信 instructions 保持原文；持久请求保留来源及贡献证据。撤销可选来源后记录 `unauthorized` 省略原因，正文不再进入请求。模块要求的审批不能被宿主 allow 绕过；用户拒绝和等待审批时撤权均不能写入。作用域释放后注册表为空且来源资源已关闭。 |
| 独立配置和续接策略的提供方家族 | [AgentProviderDriverChallengeTests.swift](../../Packages/MiraKit/Tests/MiraDataTests/AgentProviderDriverChallengeTests.swift) 注册 `challenge.provider` 与自己的配置描述/schema，保存真实连接、模型和预设，由公开目录生成冻结路线。无效配置被拒绝。同轮工具续接保留结构化 opaque payload，并从日志引用的模型输出与后续请求重新解码核对；下一轮由该提供方移除旧 thinking，保留文字和工具交换，新轮续接仍有效。提供方自己拒绝错误 opaque 格式；Core 无须解释此格式。实际生产者通过 `AgentModelOperation` 取消／排空。 |
| 从游标重连的持久只读观察者 | [AgentExtensionLifecycleChallengeTests.swift](../../Packages/MiraKit/Tests/MiraDataTests/AgentExtensionLifecycleChallengeTests.swift) 使用真实 `FileSessionLibrary`、`SQLiteSessionConsumer` 和独立观察者表。消费前三批后关闭并重新打开存储，再追加第四批，只有后缀触发处理；检查点与记录同事务提交。事务使用严格 INSERT，重复处理不能被忽略冲突掩盖。删除查询数据库并两次真实重建后再推进消费者，处理批次数为零，准备调用次数和记录保持不变。观察者只记录提交序号，不执行模型或业务工具。 |
| 经相同内核操作改变迭代行为 | 提供方文件用真实内核创建的 `AgentRunContext` 运行替代驱动器：一次模型步骤后停止，未执行工具且以 interrupted 结算。另一个驱动器执行工具后请求第二步，内核的一步预算以 `outputLimit` 拒绝；只有一个模型尝试和一次工具执行。默认驱动器则通过相同提供方完成工具往返及两轮对话。 |
| 激活失败、释放和重新激活 | 生命周期文件让依赖模块先完成注册并启动作用域任务，再使后续模块在登记清理后激活失败。失败回滚后注册表为空、任务启动／排空／清理均一次；同一宿主随后两次重新激活，每次创建新任务，重复 dispose 不重复清理。慢观察者持有目录租约时，释放已开始且模块任务已取消排空，但资源释放仍待决；放行消费者后释放才完成。 |

## 修改边界

实现差异只有上述三个测试文件及中文进度／证据文档。没有修改 `SessionState`、`DefaultAgentDriver`、`AgentExecutionKernel`、Core 厂商类型、生产模块目录、平台代码、数据库生产 schema 或 `Package.swift`。没有加入兼容接口、旧格式迁移、生产测试提供方或动态二进制插件。

扩展自身仍须满足既有契约：提供方必须声明其实际 thinking 能力，提交已保存的配置路线；工具的领域权威必须验证该工具，并允许已由日志来源授权器核验的同会话继承来源。作用域任务可能在真正开始前被取消，因此测试通过启动屏障证明其已经运行，再触发释放。新增夹具在首次编译和运行中发现的这些使用错误均在测试自身修正，没有为使案例通过而放松核心约束。

核心架构图和执行流程图沿用[方案](../architecture/AGENT_CORE_PROPOSAL.md)、[执行内核](../architecture/AGENT_EXECUTION_KERNEL.md)及[工具执行](../architecture/AGENT_TOOL_EXECUTION.md)的现行图；这组扩展不改变依赖方向或执行阶段。

## 验证与限制

聚焦命令为 `swift test --package-path Packages/MiraKit --filter Challenge`；通过 13 个测试／3 个套件，驱动器测试包含两个参数场景。完整包回归与 App 构建结果汇总在[核心验证记录](AGENT_CORE_VERIFICATION.md)。

全部数据均为隔离目录中的合成内容，没有真实模型端点或凭据。上述故障注入不是真实进程崩溃或断电实验。案例证明选定公开扩展面的可用性，不能推导任意未来能力都无需调整核心；执行语义、事实源或隐私保证发生变化时仍需审查契约。P6 的完整失败矩阵、生产规模测量、历史记忆状态提示、独立后台费用查询和剩余原生行为验收继续保留在[承接清单](AGENT_CORE_ACCEPTANCE_TRANSFER.md)。iOS 仍不实现。
