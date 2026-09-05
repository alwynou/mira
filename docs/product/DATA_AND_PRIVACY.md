# 数据生命周期、隐私与可靠性产品规范

**文档版本：** v1.2  
**更新日期：** 2026-09-05  
**状态：** 设计基线；当前实现与验收范围见 [实施记录](../engineering/IMPLEMENTATION_STATUS.md)。

定义本地使用、远程发送、后台处理、同步边界、删除与恢复的产品承诺；实现契约在 architecture 目录。

返回 [PRD.md](../PRD.md) · 版本范围：[MVP](../MVP.md)

---

<a id="s17"></a>

## 1. Local-first、隐私与数据发送边界

<a id="s17-01"></a>

### 1.1 本地能力

没有网络或没有 Provider 时，用户仍应能够：

- 打开和浏览本地数据；
- 编辑 Note、Memory、Task、CalendarEvent 和 FinancialTransaction；
- 使用本地搜索；
- 查看历史 Conversation；
- 导入和导出资料；
- 使用不依赖远程模型的本地工具。

<a id="s17-02"></a>

### 1.2 数据发送披露

每次远程模型调用应能够解释：

- 发送给哪个 Provider；
- 使用哪个模型；
- 包含哪些类型的本地内容；
- 是否包含文件或图片；
- 是否包含长期 Memory；
- 哪些内容因 Workspace 隐私策略未发送。

<a id="s17-03"></a>

### 1.3 敏感内容

敏感 Memory 或 Source 可以设置为：

- 仅本地保存；
- 可本地搜索但不可发送到远程模型；
- 仅允许指定 Provider 使用；
- 需要逐次确认。

<a id="s17-04"></a>

### 1.4 本地保存、授权读取与远程发送分别管理

用户选择文件表示允许 Mira 读取或导入该文件，不自动表示允许远程模型处理其全部内容。首次将 Source、长期 Memory 或历史 Conversation 发送到所选 Provider 前，需要已存在适用范围明确的发送设置或本次授权。

隐私策略同时约束预取、Agent 搜索、工具参数、生成摘要、Embedding、自动提取和导出分享。把禁止发送的数据概括成摘要，不会取消其发送限制。用户收紧策略后，从下一次网络发送开始立即生效；已经发送的历史数据无法从 Provider 撤回。

当前版本的“本地优先”不等于应用级数据库加密。密钥通过 Keychain 保存；本地业务内容由系统文件访问保护，额外数据库与 Blob 加密须单独实现和验证后才能宣称支持。

---

<a id="s18"></a>

## 2. 跨设备与未来同步边界

当前首先实现 macOS，本节只定义产品语义，不要求当前建设同步 Runtime。

<a id="s18-01"></a>

### 2.1 默认数据边界

```text
设备本地
Conversation
Message
Execution
Tool Result
Compact
Provider Credential
Apple 外部副本标识

未来可共享
Workspace
Global Memory
Project Memory
Knowledge Note
部分 Knowledge Source
Task
Reminder
CalendarEvent
EventRecord
FinancialTransaction
```

<a id="s18-02"></a>

### 2.2 Conversation 默认不全量同步

不同设备可以拥有不同本地 Conversation，但共享长期 Memory 与结构化状态。

未来可以提供显式 Handoff（接续快照），而不是默认同步完整历史。

<a id="s18-03"></a>

### 2.3 不建设 Mira 同步服务器

未来同步候选可以包括 CloudKit / CKSyncEngine 等 Apple 能力，但 Mira 不建设自己的用户数据同步后端。

当前只保留稳定身份、修订和删除语义等最低兼容性，不提前建设 Change Journal、Sync Envelope 或复杂冲突引擎。

---

<a id="s22"></a>

## 3. Background Intelligence（本地后台智能）与成本

<a id="s22-01"></a>

### 3.1 可执行的后台工作

在用户允许时，Mira 可以执行：

- Memory 提取；
- Source 解析与分块；
- 全文索引；
- 重复 Memory 检查；
- Entity Mention 提取；
- 搜索索引重建；
- 可选 Embedding（向量嵌入）；
- 用户主动触发的知识整理。

<a id="s22-02"></a>

### 3.2 默认保护

- 前台 Conversation 优先于后台任务；
- 后台远程模型调用有每日 Token / 费用预算；
- 达到预算后暂停，不静默超额；
- 可以选择只在充电、空闲或手动触发时执行；
- 非核心的关系发现、综合和图聚类默认按需运行；
- App 完全退出后不承诺继续执行。

<a id="s22-03"></a>

### 3.3 成本可见性

Settings 与 Activity 中应区分：

- Conversation 成本；
- Agent 工具循环成本；
- Memory Extraction 成本；
- Compact 成本；
- Knowledge Processing 成本；
- Embedding 成本。

用户可以关闭某类后台远程处理，或为其选择更便宜 / 本地的模型路线。

---

<a id="s23"></a>

## 4. 数据所有权、导入、导出与删除

用户应能够导出：

- Conversation；
- Memory；
- Knowledge Note；
- Source 元数据和可导出原文件；
- Task、CalendarEvent、Reminder 和 EventRecord；
- FinancialTransaction CSV；
- Artifact；
- Execution 摘要和来源关系。

支持的主要格式可以包括：

- Markdown；
- JSON；
- CSV；
- 原始文件目录；
- Obsidian-compatible Folder。

删除语义需要区分：

```text
Archive
退出默认使用但保留

Remove
从当前视图或范围移除

Forget
删除长期 Memory 及其派生使用关系

Permanent Delete
在允许范围内物理清理规范数据和 Blob
```

删除不能只移除索引而留下不可见的规范内容。

<a id="s23-01"></a>

### 4.1 删除范围与审计保留

用户主动删除优先于历史审计完整性。删除操作应展示受影响的原文、Evidence 摘录、Memory、请求快照、压缩摘要、索引与 Blob；保留不含正文的必要终态和删除原因。内容已清理的历史请求显示“不可重建”，不能继续展示被删除正文。

普通清理历史审计正文与删除规范 Conversation 是不同操作。完整模型输入有明确保留期和手动清理入口，清理不删除用户仍需保留的原始资料。

Mira 能清理自身管理的数据，不承诺抹除 Provider 已收到的数据、用户此前导出的文件、操作系统备份或存储介质中的所有物理残留。导出和备份包含私密内容时，在用户选择目标位置前清楚展示内容范围。

<a id="s23-02"></a>

### 4.2 最低恢复能力

首个接收真实长期数据的版本必须支持可用的本地导出与恢复路径，而非只导出不可重新导入的文本。恢复保留稳定对象 ID、来源版本与关联，不包含模型凭据，不自动执行历史任务、重新发布到 Apple 或再次启用被用户关闭的后台操作。

---

<a id="s24"></a>

## 5. 非功能产品要求

<a id="s24-01"></a>

### 5.1 离线可用

本地浏览、编辑、搜索和数据管理不依赖网络。

<a id="s24-02"></a>

### 5.2 数据可靠性

- 关键写入具备原子性；
- 崩溃后不会出现永久 Running 的幽灵任务；
- Assistant 流式内容可以恢复至已持久化检查点，未落盘尾部的边界须明确说明；
- 索引损坏时可重建；
- Blob 删除前验证真实引用。

<a id="s24-03"></a>

### 5.3 可恢复性

用户可以：

- 重试失败模型调用；
- 重试 Apple 发布；
- 恢复被归档内容；
- 查看中断的 Agent 执行；
- 重新生成派生索引。

<a id="s24-04"></a>

### 5.4 可访问性与可理解性

- 支持键盘导航；
- 支持 VoiceOver；
- 不只依赖颜色表达状态；
- 自动操作有明确状态词；
- 错误提供可行动建议；
- Memory 和工具副作用有撤销或纠正入口。

<a id="s24-05"></a>

### 5.5 性能体验

- 打开本地页面不应等待远程模型；
- 搜索先返回本地结果；
- 大型 Tool Result 不完整塞入 UI 或 Context；
- 后台任务不明显抢占前台交互；
- Context 构建和 Memory 预取应有可观测耗时。
