# 历史回复的记忆状态

<!-- Simplified Chinese documentation is explicitly requested by the user. -->

本契约定义历史提示的来源与读取边界。提示只包含 `MemoryID` 和 `MemoryContextNotice.Reason`；不能作为记忆正文、来源授权、模型上下文或工具提交证明。

## 所有权与事实源

`MemoryApplication.contextNotices` 接收一个会话、明确工作区以及最多 128 个执行身份。应用服务拥有作用域任务与库访问租约，关闭、维护或撤权必须等待实际读取返回；撤权后的迟到结果不可发布。执行选择从同一已确认日志前缀验证，其他会话的执行身份直接拒绝。

正常历史只读取有可见回答的 completed 执行。`JournalSessionReader` 验证回答、执行计划和成功尝试的实际请求，核对会话、执行、步骤、工作区与冻结路线，再取得精确来源修订。失败、未完成及已清理可见回答不生成普通状态提示；缺失或损坏正文是读取错误，不能伪装成没有关联记忆。查询不依赖 SQL 会话投影，不增加使用记录或日志事实。

```mermaid
flowchart TB
    Page[macOS 会话页面] --> App[MemoryApplication\n作用域与库租约]
    App --> Journal[JournalSessionReader\n固定日志前缀与原请求]
    App --> Domain[MemoryReadStore\n当前领域生命周期与来源策略]
    Journal --> Privacy[SessionPrivacyHistoryReader\n已完成维护的无正文来源]
    Privacy --> Plans[独立业务 SQLite\n原始持久隐私计划]
    Journal --> Files[会话日志与受管正文]
    Domain --> Memory[独立业务 SQLite\n记忆与原始来源工作区]
    App --> Notice[执行 ID → 记忆 ID 与状态原因]
    Notice --> Page
```

`memoryContextNotices` 在一个领域只读事务内处理至多 8,192 个不重复的精确记忆引用。不存在或越出可见范围的对象返回 unavailable；存储损坏必须向上抛出。生命周期优先于修订差异：forgotten、removed、superseded、candidate、archived、rejected、expired、notYetValid 均有对应原因。仍 active 的对象先检查当前记忆发送限制和证据所属工作区的发送政策，再比较使用时与当前修订；不可用返回 unavailable，修订不同返回 updated，仍有效且修订相同不生成提示。

全局记忆可以来自另一工作区。查询不能因为来源工作区与当前会话不同就判定不可用；必须检查来源工作区实际政策。冻结路线中的连接身份用于这项历史政策检查，不要求当前模型配置或凭据版本仍等于旧路线。提示不证明可以重新发送。

## 清理后的保留历史

遗忘会清除隐藏请求、工具交换和重放正文，但保留已经提交的用户消息、回答及可见思考。历史提示使用已经存在的持久隐私计划，不增加旧格式读取器，也不从已清理正文重建内容。

`SQLiteSessionPrivacyPlanStore` 的只读历史入口只在库 ready 且维护操作已完成时返回结果。它验证原计划摘要、操作身份和授权库身份，逐个读取日志指定的操作 ID；在原计划的实际执行依赖边上展开领域来源，使用 visited 集合处理循环，并限制遍历与返回大小。不相关的维护根不能因为出现在同一计划里就成为来源。

返回值带有原始失效批次和无正文维护请求。日志读取器再次核对该批次确实属于当前会话、位于选定前缀、与权威原批次完全相同，且每个目标执行的来源记录完整、不重复。缺失或损坏计划不能退化为正常历史。

明确保存记忆可能只发送本地保存回执，没有发送新记忆正文。记忆应用服务因此还识别已完成 `memory.forget` 请求中的目标记忆身份：这说明原用户陈述与保存回复为何被保留、排除，不虚构模型读取过该正文。这里的领域解释属于记忆模块，不进入通用驱动器或会话归约器。

清理后不再保留旧模型路线，故当前生命周期查询使用本地读取语义，不能据此判断旧远程发送许可。严格引用与执行来源接口继续拒绝 excluded 执行；保留提示不会恢复正文、重新授权引用或触发模型请求。

```mermaid
sequenceDiagram
    participant UI as 会话页面
    participant M as MemoryApplication
    participant J as 日志读取器
    participant P as 持久隐私计划
    participant D as 记忆领域
    UI->>M: 选定会话、工作区与执行 ID
    M->>J: 固定已确认前缀，核对执行归属
    alt 普通可见 completed 回复
        J->>J: 验证原请求、路线与精确来源修订
    else 清理后仍保留可见回复
        J->>P: 读取已完成操作与来源关系
        P-->>J: 原失效批次、维护请求、无正文来源
        J->>J: 与实际日志批次核对
    end
    J-->>M: 用于历史说明的来源
    M->>D: 当前状态及来源工作区政策
    D-->>M: 记忆 ID 与原因，不返回正文
    M->>M: 完成租约撤权检查
    M-->>UI: 按执行归组的提示
```

## 宿主刷新

`MacLibraryWorkloads` 直接注入同库的隐私历史读取器。会话页面单独拥有提示读取任务、代次与无正文结果；实际消息读取不由业务提交通知重复触发。消息页加载、加载更早消息、重新选择已缓存页面和业务提交会刷新提示，超过 128 个已加载执行时按批次处理。

发布结果前检查工作组身份、页面观察身份和提示代次。维护或页面释放会取消并排空提示任务，清空提示映射；原有草稿、阅读状态与消息正文保持各自所有权。现有 `MemoryHistoryTags` 消费这些结果，查询及标签都不触发模型执行。

状态按读取时刻计算；目前没有独立定时器在页面一直静止时刷新有效期。完整原生外观与交互矩阵、规模性能属于[核心验收](../engineering/AGENT_CORE_VERIFICATION.md)，不能从服务或展示模型测试通过推导。
