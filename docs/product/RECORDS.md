# 结构化记录产品规范

**文档版本：** v1.2  
**更新日期：** 2026-09-05  
**状态：** 设计基线；当前实现与验收范围见 [实施记录](../engineering/IMPLEMENTATION_STATUS.md)。

定义事件、任务、提醒、日程和轻量财务记录的业务含义及 Apple 发布体验；版本范围由 MVP 决定。

返回 [PRD.md](../PRD.md) · 版本范围：[MVP](../MVP.md)

---

<a id="s15"></a>

## 1. Structured Data（结构化数据）

Memory 与可操作的结构化记录必须分开。

<a id="s15-01"></a>

### 1.1 基础对象

```text
EventRecord
已经发生、被观察或被记录的一件事

Task
需要完成的事项

Reminder
在某个时间或条件提醒用户

CalendarEvent
占据某段时间的安排

FinancialTransaction
收入、支出、退款或转账等轻量财务流水
```

<a id="s15-02"></a>

### 1.2 EventRecord 边界

EventRecord 只描述已经发生或已经观察到的事件，不再同时表达“未来计划”。

未来计划进入 CalendarEvent；需要执行的行为进入 Task；需要通知的行为进入 Reminder。

事件本身可被搜索和回顾，默认不再重复生成同内容的“memorableEvent Memory”。只有从事件中形成长期认识时，才产生 Memory。

<a id="s15-03"></a>

### 1.3 从 Conversation 自动提取

同一句话可以创建多个对象。

例如：

> 今天在盒马花了 126.8 元，明天下午三点提醒我报销。

可以产生：

- 一条 FinancialTransaction；
- 一条 Reminder；
- 原始 Conversation Message；
- 它们之间的 Evidence（证据）关系。

处理规则：

```text
明确命令
→ 直接创建或修改

明确事实但没有要求执行
→ 根据用户设置自动记录，或生成可撤销提示

金额、时间、对象或意图不明确
→ Candidate，等待确认
```

<a id="s15-04"></a>

### 1.4 变更与溯源

结构化记录采用：

```text
当前有效状态
+
轻量 Revision 历史
+
Evidence Link
```

用户可以追溯：

- 原始值；
- 当前值；
- 谁修改；
- 哪句话或哪个 Tool Result 触发；
- 修改时间；
- 取消、完成或删除历史。

不建设完整 Event Sourcing（事件溯源）系统。

<a id="s15-05"></a>

### 1.5 轻量财务记录的产品范围

FinancialTransaction 支持：

- 自然语言记账；
- 收入、支出、退款与转账；
- 金额、币种、商户、分类和备注；
- 按时间、类别、商户和 Workspace 汇总；
- 搜索和修改；
- CSV 导出；
- 退款或纠正关系。

当前明确不做：

- 银行账户自动同步；
- 信用卡对账；
- 复式记账；
- 税务核算；
- 投资资产净值；
- 将其包装成专业财务软件。

<a id="s15-06"></a>

### 1.6 Mira 与 Apple Calendar / Reminders

Mira 内部 CalendarEvent 与 Reminder 是规范事实源。

用户可以选择单向发布到：

```text
Mira CalendarEvent → Apple Calendar
Mira Reminder      → Apple Reminders
```

当前产品边界：

- 不从 Apple 全量导入；
- Apple 端标题、时间、备注和优先级修改不回流；
- Apple 发布失败不回滚 Mira 内部记录；
- Mira 可以检查外部副本是否仍存在以及发布是否成功；
- 外部副本丢失时可以重新发布。

<a id="s15-07"></a>

### 1.7 单一通知所有者

为了避免重复通知，每条 Reminder / CalendarEvent 必须只有一个默认通知所有者：

```text
deliveryOwner = mira
由 Mira 的本地通知负责

deliveryOwner = apple
由 Apple Calendar / Reminders 负责
```

发布到 Apple 并启用 Apple 通知后，Mira 不再为同一触发条件重复安排本地通知。

“是否只回读 Apple Reminder 的完成状态”保留为产品假设；当前不以隐式方式引入半双向同步。

<a id="s15-08"></a>

### 1.8 时间、候选与提醒失败

相对时间以原消息发送时间和当时的时区解释。跨日重试不能把“明天”重新解释为另一天；遇到夏令时不存在或重复的本地时间、无明确时刻的表达时，展示解释并要求必要的澄清。

结构化候选拥有独立审核入口，不占用 Memory 的候选生命周期。只有已提交且时间完整的 Reminder 才能尝试安排通知；通知未授权、调度失败或 Apple 发布失败都必须在记录上可见，不能显示“已安排通知”。

从 Mira 通知切换到 Apple 通知，或反向切换，是一个可能失败的多步操作。只在旧通道移除与新通道确认完成后显示成功；状态不确定时提示用户，不自动启动第二条通知通道。

> **参考设计标注｜Apple EventKit / UserNotifications**  
> EventKit 用于创建 Apple Calendar 与 Reminders 外部副本；UserNotifications 用于 Mira 自己负责的本地通知。Mira 的业务事实仍保存在本地数据库，外部系统状态不静默覆盖内部记录。
