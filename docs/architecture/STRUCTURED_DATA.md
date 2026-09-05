# 结构化记录与通知一致性

**文档版本：** v1.2  
**更新日期：** 2026-09-05  
**状态：** 开发前规范基线；实现与验收尚未执行。

定义记录、候选、时间与金额、Revision、Apple 投影及可恢复通知交付；在对应 MVP 里程碑才实施。

返回 [ARCHITECTURE.md](../ARCHITECTURE.md) · 版本范围：[MVP](../MVP.md)

---

<a id="s22"></a>

## 1. Structured Data Architecture

<a id="s22-01"></a>

### 1.1 通用记录字段

```text
StructuredRecord Common
├── id
├── workspaceId?
├── state
├── sourceAuthority
├── createdAt
├── updatedAt
├── revision
└── deletedAt?
```

统一通过 EvidenceLink 追溯来源。

<a id="s22-02"></a>

### 1.2 EventRecord

只描述已经发生或观察到的事件：

```text
EventRecord
├── id
├── workspaceId?
├── title
├── description?
├── occurredAt / occurredRange
├── location?
├── participants?
├── tags[]
├── state                recorded / corrected / removed
├── createdAt
├── updatedAt
└── revision
```

未来计划不能存成 EventRecord。

<a id="s22-03"></a>

### 1.3 Task

```text
Task
├── id
├── workspaceId?
├── title
├── notes?
├── status               open / inProgress / completed / cancelled
├── dueAt?
├── priority?
├── completedAt?
├── createdAt
├── updatedAt
└── revision
```

<a id="s22-04"></a>

### 1.4 Reminder

```text
Reminder
├── id
├── taskId?
├── title
├── notes?
├── trigger
├── status               scheduled / completed / cancelled
├── deliveryOwner        mira / apple
├── createdAt
├── updatedAt
└── revision
```

<a id="s22-05"></a>

### 1.5 CalendarEvent

```text
CalendarEvent
├── id
├── workspaceId?
├── title
├── notes?
├── startAt
├── endAt
├── timeZone
├── allDay
├── recurrence?
├── location?
├── status               scheduled / completed / cancelled
├── deliveryOwner        mira / apple
├── createdAt
├── updatedAt
└── revision
```

<a id="s22-06"></a>

### 1.6 FinancialTransaction

```text
FinancialTransaction
├── id
├── workspaceId?
├── direction            expense / income / refund / transfer
├── amount
├── currency
├── occurredAt
├── merchant?
├── category?
├── note?
├── relatedTransactionId?
├── status               recorded / corrected / voided
├── createdAt
├── updatedAt
└── revision
```

不包含银行账户余额、复式分录和税务模型。

<a id="s22-07"></a>

### 1.7 Natural Language Extraction

```text
Committed User Message
        ↓
Structured Intent Extractor
        ↓
Candidate Objects
        ↓
Deterministic Validation
时间 / 金额 / 币种 / 必填字段
        ↓
Duplicate & Existing Record Match
        ↓
Intent Policy
明确命令 → Commit
模糊提及 → Candidate
        ↓
Persist Record + Revision + Evidence
```

同一句 Message 可以创建多个记录。

<a id="s22-08"></a>

### 1.8 RecordRevision

```text
RecordRevision
├── id
├── entityKind
├── entityId
├── revision
├── operation            created / updated / completed / cancelled / removed
├── actor                user / agent / system
├── sourceReference?
├── changedFields
├── reason?
└── changedAt
```

采用当前状态 + 轻量 Revision，不建设完整 Event Sourcing。

<a id="s22-09"></a>

### 1.9 Apple Projection

```text
ExternalProjectionLink
├── id
├── recordKind
├── recordId
├── destination          appleCalendar / appleReminders
├── externalIdentifier?
├── publishedRevision?
├── state                notPublished / pending / published / failed / missing
├── lastAttemptAt?
├── lastObservedAt?
├── lastError?
└── deviceId
```

特点：

- Device-bound（设备相关）；
- 默认 Local-only；
- 不作为 Mira 记录身份；
- Apple 副本删除可被标记 `missing`；
- Apple 业务字段不自动回写。

<a id="s22-10"></a>

### 1.10 单一通知所有者

本地事务与系统外部调度不是一个原子事务，采用可恢复的发布工作流：

```text
Mira Record + Desired Delivery + LocalJob committed
        ↓
Remove / verify previous scheduled delivery if switching
        ↓
Install requested delivery with stable identity
        ↓
Persist observed delivery owner / revision / result
```

`deliveryOwner` 表示用户期望的所有者，另存实际 `NotificationDelivery`：record ID、desiredRevision、observedOwner?、requestIdentifier?、state（pending / scheduled / failed / uncertain / cancelled）、lastAttemptAt 和 error。只有 scheduled 且 observedOwner 与当前期望一致时显示成功。

切换时先撤下旧通道、确认其状态，再安排新通道；失败期间可能存在通知空窗，需在 UI 说明。状态不确定时不自动启用第二通道。此策略追求单一通知通道，不宣称跨系统 exactly-once 或无损原子切换。

Mira 通知使用稳定记录 ID 作为 requestIdentifier，更新前读取当前 Revision，取消 / 删除清除 pending 与已投递的同 ID 通知。Apple 创建成功但本地回执丢失时先核对外部副本，不盲目重复创建；不能可靠识别时进入 uncertain，由用户决定。

<a id="s22-11"></a>

### 1.11 候选、时间与金额契约

结构化候选保存为 `RecordProposal`，包含目标类型、typed payload、源消息版本、解析时区、解释后的绝对时间、候选状态和确认结果；不混用 Memory.state。提交前重新校验目标 Revision 与用户意图。过期 Proposal 不会因用户几天后打开而按新的“今天”重新解释。

时间使用明确的 instant、local date / time、timeZone ID 与 precision。全天日程使用本地日期范围、结束日期不包含；不得把日期直接转换成 UTC 零点。夏令时缺失 / 重复时间需要明确选择。MVP Reminder 只支持一次性确定时刻，重复、地理围栏和自然语言条件另行实现。

FinancialTransaction 使用正数 Decimal 金额 + 规范化币种代码 + direction；不使用 Double 保存金额，不默默假定所有币种都是两位小数。退款和转账不隐式抵销原记录，保留关联。该模型在对应里程碑实施前不预建完整账本。

> **参考设计标注｜Apple EventKit / UserNotifications**  
> EventKit Adapter 负责创建和更新 Apple 外部副本；UserNotifications Adapter 负责 Mira 自己的本地通知。Core 只依赖语义 Port，不知道 `EKEvent`、`EKReminder` 或 `UNNotificationRequest`。
