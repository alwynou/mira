# Mira 开发前文档审阅

**日期：** 2026-09-05  
**审阅起点：** `ba9a441` 中的 PRD / ARCHITECTURE v1.1  
**工作分支：** `dev`  
**职责：** 解释发现的问题、取舍和修正位置；不成为另一份产品或技术规范。

## 1. 判断

原文已经清楚定义了个人优先、本地事实源、原生 Swift、BYOK、原始与派生分离、可纠正记忆和可审计执行，整体方向可保留。但它主要描述完整产品，仍有运行时契约冲突、数据生命周期缺口和版本验收不明确的问题，不宜直接按原顺序全面实现。

本轮完成两类调整：按文件职责拆分既有内容，并补齐进入开发前必须明确的行为与契约。MVP 围绕实际连续性闭环裁剪，并将工具运行时放在依赖它的记忆与知识能力之前。

**当前判断：可以进入 M0 工程开发。** 文档没有需要用户先回答才能开始 M0 的阻塞项；真实 Provider、最低系统、模型质量与发布签名仍需在对应实施 / 发布阶段验证。文档修正不代表这些实现已经通过验证。

## 2. 保留的设计

- 单用户、本地 SQLite / Blob 作为规范事实源，不增加自有业务后端。
- Conversation、Execution、Memory / Knowledge 与 Structured Record 分开。
- 有限记忆预取与 Agent 主动搜索共同存在，临时资料不跨用户回合永久滞留。
- 清晰用户陈述可自动捕获并可撤销，推断 / 敏感 / 冲突进入候选。
- Core 以 Swift 定义领域与 Port，UI / 数据 / Provider / 平台实现置于外层。
- 图谱、向量、复杂知识综合和同步按实际价值推进，不作为 v0.1 前提。

这些选择无需因进入开发而推翻；本轮重点是让其有确定的落地边界。

## 3. 发现的问题与修正

优先级表示问题在原文中的开发风险：P0 为信任 / 数据正确性风险，P1 为会导致实现冲突或显著返工，P2 为维护与范围问题。下表“已修正”均指文档契约，实际代码与测试尚未开始。

| ID | 级别 | 原问题及影响 | 文档修正 / 唯一实现契约位置 |
|---|---|---|---|
| R01 | P1 | 产品、详细设计、实现顺序和质量要求集中在两份长文中，开发时难以找到规则所有者 | 总纲 + product / architecture / engineering / MVP / reviews；[文档维护规则](../engineering/DEVELOPMENT.md) |
| R02 | P0 | Agent Loop 先构建 Context 再解析 Route，预算和允许发送的 Provider 无法预先确定 | 先冻结路线 / 能力，再构建并验证每 Attempt 请求；[Runtime](../architecture/RUNTIME.md#s10-07)、[Context](../architecture/CONTEXT.md#s16-05) |
| R03 | P0 | Step、Turn、Attempt 混用，request-scoped 描述可能导致工具结果在下一 Step 消失 | 定义术语、请求次数、回合寿命与完整工具交换；[Runtime](../architecture/RUNTIME.md#s10-08) |
| R04 | P0 | 移除临时工具结果或只保留 durable 结果可能留下不配对的协议消息；用户输入也可能在两层重复 | 同一 Turn 保留配对组，下一 Turn 只留有来源的语义回执，当前输入只出现一次；[Runtime](../architecture/RUNTIME.md#s10-09) |
| R05 | P1 | Crash Recovery 使用 interrupted，但 Execution 枚举没有该终态；多窗口重复执行未定义 | 增加终态、状态转移、事务条件更新和活动执行唯一约束；[Runtime](../architecture/RUNTIME.md#s10-08) |
| R06 | P1 | ExecutionStep 只指一个 ModelCall，无法表达可审计重试；失败回复如何进入历史不明 | Step / Attempt 一对多、每 Attempt Snapshot、显式重试新 Execution、失败历史投影；[Runtime](../architecture/RUNTIME.md#s09-06) |
| R07 | P0 | 确认发生在具体参数校验之前，无法确保用户审批的正是最终写入目标 | 先校验并呈现参数 / 目标，再授权；执行前复查 Hash、Revision 与权限；[工具管线](../architecture/RUNTIME.md#s12-04) |
| R08 | P0 | 记忆去重键包含 extractorVersion，升级可能重新建同一条；撤销 / 遗忘没有抑制事实 | 分离任务身份与业务候选身份，持久化 ExtractionDecision 并在提交时复查；[记忆幂等](../architecture/MEMORY_AND_KNOWLEDGE.md#s19-06) |
| R09 | P0 | Forget 仅删除 Memory / 索引，Snapshot、Evidence 摘录和后台结果可能保留或复活内容 | 先关闭未来使用、使依赖失效，再清理正文；来源保留范围和抑制边界明确；[记忆删除](../architecture/MEMORY_AND_KNOWLEDGE.md#s19-10) |
| R10 | P1 | 替代关系分叉、循环和删除替代者后的旧版本复活缺乏规则 | 检查主体 / Scope / 时间与环，冲突保持 proposed，已确认替代不自动撤回；[Current Projection](../architecture/MEMORY_AND_KNOWLEDGE.md#s19-09) |
| R11 | P0 | Snapshot 既要“脱敏”又要“完整重建”，可变 ID 引用也无法恢复历史版本；永久审计与删除矛盾 | 区分认证秘密与业务正文、绑定不可变版本、定义保留期与 purged 状态；[请求快照](../architecture/CONTEXT.md#s16-08)、[保留](../architecture/CONTEXT.md#s16-12) |
| R12 | P0 | 只有检索阶段的隐私规则，不足以阻止工具按 ID 打开、摘要继承或策略变更后的越界 | Scope 与发送策略分开、限制取交集、摘要继承、实际发送前复核；[平台与安全](../architecture/PLATFORM_AND_SECURITY.md#s28-01) |
| R13 | P1 | Model / Provider 能力缺少最小可交付范围，兼容接口可能被误解为支持所有模型 | 首版两类明确协议、独立能力验证、Responses 后置、受控 JSON 提取；[Provider 设计](../architecture/PROVIDERS.md#s14-09) |
| R14 | P1 | Turn 路线冻结与中途跨模型 Fallback 同时出现，缺少边界 | 回合前选择路线；回合内仅同路线可观测重试，替代路线创建新执行；[Fallback](../architecture/PROVIDERS.md#s14-06) |
| R15 | P1 | 流式 EOF、非法参数、Usage 缺失、输出截断等容易被当作成功 | 明确协议终止、部分输出、参数上限、Usage unknown 和一次结算；[Provider 流式](../architecture/PROVIDERS.md#s14-10) |
| R16 | P1 | Source 重解析没有版本身份，旧 Chunk / Evidence 可能悄悄引用新正文 | SourceVersion 和不可变 Chunk、原子切换当前版本、失败保留旧成功版本；[Knowledge](../architecture/MEMORY_AND_KNOWLEDGE.md#s21-03) |
| R17 | P1 | SQL LIMIT 并不能防止短词查询大量扫描，开发机 SQLite 也不能证明最低系统能力 | 扫描与时间双边界、App 实际链接能力探测、中文回退与结果不完整披露；[Search](../architecture/SEARCH.md#s25-02) |
| R18 | P0 | 数据库与 Blob 跨资源提交、GC 并发和 WAL 备份不完整可能丢数据 | 完整文件先安装后提交引用、删除前互斥复查、维护窗口一致备份、隔离恢复；[Blob](../architecture/DOMAIN_AND_STORAGE.md#s23-06)、[恢复](../architecture/DOMAIN_AND_STORAGE.md#s24-08) |
| R19 | P1 | 有后台智能需求但无可靠领取、来源失效、预算预占和重启语义 | 最小 LocalJob / lease / 源版本复查 / 同事务入队；未知费用不按零处理；[LocalJob](../architecture/DOMAIN_AND_STORAGE.md#s24-10) |
| R20 | P1 | Record Candidate 无独立模型，模糊时间 / 金额会反复解释；通知 owner 无交付状态 | Proposal、原消息时间 / 时区、Decimal 与币种；期望所有者和实际交付分开；[结构化记录](../architecture/STRUCTURED_DATA.md#s22-11) |
| R21 | P0 | Apple 发布与数据库被描述得像一个事务，失败切换可能双通知或误报成功 | 可恢复工作流、稳定身份、uncertain 状态与逐步核对；[通知交付](../architecture/STRUCTURED_DATA.md#s22-10) |
| R22 | P1 | App 退出后不运行 Agent 的边界，可能被误读为系统通知也失效 | 产品区分后台处理与已交给系统的通知，真机验证实际交付；[Agent 产品规范](../product/AGENT_AND_CONTEXT.md#s12-04) |
| R23 | P1 | 最低系统、直接分发与 Bookmark 使用方式未定，会影响 Host 和测试矩阵 | 用户确认 macOS 15+ / 直接分发；平台模式与权限分开，具体工具链置于工程文档；[开发约定](../engineering/DEVELOPMENT.md) |
| R24 | P1 | 只有质量指标名称，没有数据集、门槛、版本划分或退出条件 | 独立 Q01–Q09 质量门槛，F01–F09 功能范围与 M0–M6 依赖；[质量](../engineering/QUALITY.md#quality-gates)、[MVP](../MVP.md) |

## 4. 用户确认与工程默认

**用户明确确认的事项：** 首版聚焦对话 / 记忆 / Markdown / 工具循环，任务提醒紧随其后；OpenAI 兼容与 Anthropic Messages；macOS 2024 年及以后（对应 macOS 15+）；直接下载安装；按职责拆文档。

**本轮确定的工程默认：** Chat Completions 为首版兼容协议，Responses 独立后置；直接分发初期采用非 App Sandbox Host；Snapshot 正文有保留期；自动记忆需用户启用；执行 / 文件 / 搜索有资源上限；实际模型与分发架构以验证证据为准。这些是可调整的基线，没有伪装为用户逐项批准或已完成实验。

具体默认数值只在负责它的技术 / 质量文档中维护。若真实使用需要改变默认，先补理由和回归，不自动扩张首版功能。

## 5. 内容迁移与职责

| 原始内容 | 新归属 |
|---|---|
| PRD 定位、用户、问题、愿景、不变量、核心闭环、成功标准与不做范围 | PRD.md |
| PRD 信息架构、对话 / Workspace、macOS 形态、场景与冷启动 | product/WORKSPACE_AND_CONVERSATION.md |
| PRD Memory、Project Context、Knowledge、Artifact | product/MEMORY_AND_KNOWLEDGE.md |
| PRD Agent、Provider、Context | product/AGENT_AND_CONTEXT.md |
| PRD 结构化记录 | product/RECORDS.md |
| PRD 隐私、同步、后台处理、数据删除与非功能要求 | product/DATA_AND_PRIVACY.md |
| 架构目标、不变量、模块、依赖和并发所有权 | ARCHITECTURE.md |
| 详细模型、运行时、Provider、Context、知识、记录、检索和平台 | architecture/ 对应文档 |
| 工具链、代码目录、开发协作与维护 | engineering/DEVELOPMENT.md |
| 测试、评估、性能、质量门槛 | engineering/QUALITY.md |
| 原实现顺序与 MVP 原则 | MVP.md，按用户确认范围重排 |
| 重复的外部参考映射 | REFERENCES.md 合并维护 |
| 延后决策 | MVP 后置能力表与对应规范保留边界；不再把已经确认的平台 / 协议写为未知 |

拆分保持既有产品不变量。为消除矛盾而修改的规则均在本记录指出；重复总结与默认汇总由规范入口和引用替代，不保留平行版本。稳定锚点用于跨文档定位，章节显示编号在每个文件内重新排列。

## 6. 验证与剩余事项

本轮检查文档的本地链接与锚点、代码围栏、标题层次、旧路径 / 旧版本残留、跨文档规则一致性，以及只包含文档的 Git 差异。对原始章节进行迁移映射核对，MVP 的每个功能与退出条件可以定位到产品 / 技术 / 质量文件。

检查结果：21 份 Markdown 文件、141 个本地链接、334 个显式锚点；本地文件与锚点均可解析，无重复锚点、未闭合代码围栏或标题层次跳跃。旧 v1.1 只在本审阅起点说明中保留。

已读取本机工具链并用内存数据库探测系统 CLI 的 trigram 行为；官方依据集中在 [参考资料](../REFERENCES.md)。没有创建应用代码，没有执行 Swift 构建、真实模型评估、最低系统验证或分发签名。

后续需在开发时填入真实 Provider / Model ID 和能力报告；在发布前完成最低系统与 CPU 验证、备份恢复演练、真实使用和签名公证。以上有明确完成阶段，不影响当前从 M0 开始。
