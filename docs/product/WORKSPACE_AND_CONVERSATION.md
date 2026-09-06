# 工作空间、对话与用户场景

**文档版本：** v1.2  
**更新日期：** 2026-09-05  
**状态：** 设计基线；当前实现与验收范围见 [实施记录](../engineering/IMPLEMENTATION_STATUS.md)。

定义用户如何组织工作空间、开展对话、冷启动及完成核心场景；不定义运行时数据模型。

返回 [PRD.md](../PRD.md) · 版本范围：[MVP](../MVP.md)

---

<a id="s07"></a>

## 1. 产品信息架构

macOS 的长期信息架构包括：

```text
Mira
├── Home / Today
├── Inbox
├── Workspaces
│   ├── Project Context
│   ├── Working Memory
│   ├── Conversations
│   ├── Project Memory
│   ├── Knowledge
│   └── Artifacts
├── Memories
├── Knowledge
├── Schedule & Records
│   ├── Calendar
│   ├── Reminders
│   ├── Tasks
│   ├── Events
│   └── Finance
├── Search
├── Timeline / Activity
└── Settings
```

并非每个入口都必须在第一个 MVP 中出现，但领域边界不能彼此混用。

<a id="s07-01"></a>

### 1.1 Home / Today

用于展示当下最需要关注的少量内容：

- 未完成任务；
- 即将到来的日程和提醒；
- 当前活跃 Workspace；
- 最近自动记住且可撤销的内容；
- 需要审核的少量高风险候选；
- 失败或等待用户处理的 Agent 任务。

Home 不是强制启动页。应用默认可以恢复用户上次位置。

<a id="s07-02"></a>

### 1.2 Inbox

Inbox 承载：

- 未归类 Conversation；
- Quick Capture（快速捕获）；
- 待处理导入；
- 尚未决定 Workspace 的内容。

<a id="s07-03"></a>

### 1.3 Workspace

Workspace 表示一个长期项目、主题或生活领域。

基线默认采用单层 Workspace，不建设层级继承。跨 Workspace 组织通过标签、链接、实体和搜索完成。

---

<a id="s08"></a>

## 2. Conversation 与 Workspace

<a id="s08-01"></a>

### 2.1 Conversation

Conversation 表示一次相对连续的话题或任务上下文。

它是：

- 消息组织边界；
- Agent Execution 的关联边界；
- Compact 的主要边界；
- 上下文连续性的主要可见载体。

它不是：

- 长期 Memory 本身；
- Workspace 的全部知识；
- 结构化任务或日程的替代品。

<a id="s08-02"></a>

### 2.2 Workspace

Workspace 可以拥有：

- 多个 Conversation；
- Project Context；
- Project Memory；
- Knowledge Source 与 Note；
- Artifact；
- 项目相关 Task、CalendarEvent 和 FinancialTransaction。

Conversation 可以没有 Workspace，默认归入 Inbox。

<a id="s08-03"></a>

### 2.3 Conversation 与长期连续性

新的 Conversation 不需要加载另一个 Conversation 的全部历史。

它可以通过：

- Project Context；
- Working Memory；
- 相关 Global Memory；
- 相关 Project Memory；
- Agent 主动检索原始来源；

恢复必要的长期连续性。

---

<a id="s19"></a>

## 3. macOS 产品形态

<a id="s19-01"></a>

### 3.1 定位

> Personal AI Workspace（个人 AI 工作空间）

macOS 重点支持：

- 多 Workspace；
- 多 Conversation；
- 文件和知识处理；
- Agent 执行；
- Memory 与 Context 检查；
- 长任务；
- 搜索与整理；
- 快捷键和多窗口体验。

<a id="s19-02"></a>

### 3.2 推荐基础布局

```text
┌──────────────────────────────────────────────────────────────┐
│ Toolbar / Command                                            │
├──────────────┬──────────────────────────┬────────────────────┤
│ Sidebar      │ Main Content             │ Inspector          │
│              │                          │                    │
│ Home         │ Conversation / Note      │ Context            │
│ Inbox        │ Calendar / Search        │ Memory             │
│ Workspaces   │ Knowledge / Artifact     │ Execution          │
│ Memories     │                          │ Source             │
│ Knowledge    │                          │                    │
└──────────────┴──────────────────────────┴────────────────────┘
```

Inspector 可以在普通使用时收起，在调试、核对来源和管理权限时展开。

---

<a id="s20"></a>

## 4. 核心用户场景

### 场景 A：跨 Conversation 延续项目讨论

1. 用户打开 Mira Workspace。
2. 新建 Conversation，询问此前架构决定。
3. Mira 预取少量相关 Project Memory。
4. Agent 在需要时继续搜索来源。
5. 回答中展示 Memory 来源和当前有效性。

### 场景 B：自动记住清晰的用户决定

用户说：

> Mira 的核心继续使用 Swift，不使用 Rust Core。

Mira：

1. 识别为用户明确决定；
2. 自动保存为 Project Memory；
3. 在对话中显示可撤销提示；
4. 下次讨论技术栈时正确召回；
5. 不把此前 Assistant 提出的 Rust 方案误记成用户决定。

### 场景 C：高风险冲突进入候选

用户说：

> 也许以后还是做个云端服务更方便。

Mira 不应直接替代“无 Mira 自建后端”的已确认规则，而应生成待审核冲突或仅保留为 Conversation 内容。

### 场景 D：导入资料并形成知识

1. 用户导入 PDF 或 Markdown。
2. Mira 保存原始 Source。
3. 文本被解析和索引。
4. 用户可以搜索片段并创建 Note。
5. 重要结论可以成为带 Evidence 的 Memory。
6. 外部文档里的指令不自动升级为系统指令。

### 场景 E：从对话创建提醒并发布到 Apple

用户说：

> 明天下午三点提醒我发架构文档，并同步到系统提醒事项。

Mira：

1. 创建内部 Reminder；
2. 保留源 Message；
3. 发布到 Apple Reminders；
4. 将通知所有者设为 Apple，避免重复通知；
5. 发布失败时保留 Mira 记录并显示可重试状态。

### 场景 F：轻量记账与纠正

用户说：

> 记一笔，今天买键盘花了 699 元。

随后说：

> 刚才是 679，不是 699。

Mira 保留当前金额 679 元，并允许查看原金额、修改来源和时间。

### 场景 G：复杂历史检索

用户问：

> 我们讨论过的所有 Memory 自动提取策略有哪些？各自为什么没选？

Mira 不只依赖预取，而是主动调用 Memory、Conversation 和 Source 搜索，综合多个来源回答。

### 场景 H：Agent 文件任务

1. 用户通过系统选择器授权项目目录。
2. Agent 在授权范围内搜索和读取文件。
3. 只读操作可直接执行。
4. 写入或删除需满足权限策略。
5. Execution Inspector 显示调用过程、失败和结果。

---

<a id="s21"></a>

## 5. 冷启动体验

Mira 不能要求用户积累大量 Memory 后才体现价值。

<a id="s21-01"></a>

### 5.1 首次即可获得的价值

首次配置 Provider 后，用户可以立即：

- 对话；
- 创建 Workspace；
- 写 Project Context；
- 读取授权文件；
- 创建 Task、Reminder 和 CalendarEvent；
- 导入 Markdown / PDF；
- 使用本地搜索。

<a id="s21-02"></a>

### 5.2 可选快速初始化

用户可以选择填写：

- 称呼和语言偏好；
- 希望 Mira 的回答风格；
- 当前关注项目；
- 自动记忆偏好；
- 是否导入已有 Markdown / Obsidian 资料。

所有步骤都可跳过。

<a id="s21-03"></a>

### 5.3 首条 Memory 反馈

Mira 在第一次形成有效 Memory 时应清晰展示：

- 记住了什么；
- 来源在哪里；
- 作用范围；
- 如何撤销或编辑。

用户应在第一天就理解 Mira 与普通聊天窗口的差异。


## Thinking in conversations

Thinking is a core conversation capability. A supported model can use its native thinking mode during ordinary replies and Agent tool calls. Settings expose service default, on/off when supported, and the model's available effort or token-budget controls. A model that always thinks does not receive a misleading disable option.

Provider-returned visible thinking appears in a collapsible section before the answer and remains available after reopening the conversation. A stopped response may contain thinking without an answer; it remains visibly incomplete. Signatures and encrypted/redacted provider state are never presented as readable thought text. Thinking is not automatically saved as a user fact or a memory.

Changing settings applies to a new execution. A running assistant/tool turn retains its frozen settings and continuation state. Model capability, enabled settings and a successful connection test are separate facts; an error is surfaced without silently switching models or disabling thinking.

## Streaming and reading position

While the reader is at the latest response, the transcript follows the rendered output as it grows, including asynchronous Markdown layout. Starting a manual scroll pauses following. Returning to the bottom or selecting “Jump to latest” resumes it. Opening a cited historical message preserves the reading position. Sending a new user message returns to the latest turn. Completed replies do not replay text entrance animations when revisited.
