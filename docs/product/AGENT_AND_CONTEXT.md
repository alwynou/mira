# Agent、模型接入与上下文产品规范

**文档版本：** v1.2  
**更新日期：** 2026-09-05  
**状态：** 开发前规范基线；实现与验收尚未执行。

定义执行状态、权限体验、Provider 管理和模型上下文的用户行为；不定义协议字段或调度实现。

返回 [PRD.md](../PRD.md) · 版本范围：[MVP](../MVP.md)

---

<a id="s12"></a>

## 1. Agent 与工具执行

<a id="s12-01"></a>

### 1.1 Agent 的职责

Agent 可以：

- 调用用户配置的模型；
- 查询 Memory 和 Knowledge；
- 读取当前 Context；
- 调用授权工具；
- 创建或修改结构化数据；
- 产生 Artifact；
- 请求用户确认或完成 UI 操作；
- 保存可追溯的执行过程。

<a id="s12-02"></a>

### 1.2 用户可见状态

用户至少能够区分：

```text
准备上下文
等待模型
正在生成
等待工具
等待用户确认
正在执行工具
正在取消
已完成
失败
可重试
```

不能用一个持续旋转的 Loading 表示所有状态。

<a id="s12-03"></a>

### 1.3 权限基线

```text
已授权范围内的只读操作
→ 可以直接执行

写入、外部发布和其他副作用
→ 需要明确用户意图或确认

删除、Shell、AppleScript、自动化
→ 默认逐次确认或采用更严格策略
```

Capability（能力存在）、OS Permission（系统权限）与 Tool Policy（Mira 工具策略）必须分开。

<a id="s12-04"></a>

### 1.4 长任务

Agent 长任务可以持久化状态，并在 Mira 再次打开后恢复或明确标记为中断。

在没有独立 Helper（辅助进程）前，不承诺 App 完全退出后继续执行。

这里指 Agent、模型调用与本地处理任务；已经成功交给操作系统调度的本地通知具有独立生命周期。通知是否实际展示还受系统授权、勿扰模式、设备状态与系统调度影响，Mira 不承诺精确送达。

<a id="s12-05"></a>

### 1.5 运行中的对话与重试

同一 Conversation 同时只运行一个用户回合。生成过程中用户可取消；发送新消息前先结束当前回合。多窗口查看同一对话不会启动重复执行。

重试失败回复会显示新的执行记录和可能再次发生的模型费用，不重新创建同一条用户消息。已有部分回复保留中断标记；重试不能把失败内容误当作成功结果。第一版不提供历史消息编辑、回复分叉和任意旧回合再生成。

应用崩溃后显示中断状态和可采取的动作。对于是否已发生写入或外部发布无法确认的操作，先核对结果，再决定重试；不能用自动重试制造重复副作用。

> **参考设计标注｜DeepSeek Harness**  
> 借鉴其 Step 驱动 Agent Loop、追加式执行日志、受保护工具管线、并行安全工具与独占工具的区分。Mira 不照搬动态插件运行时，也不把所有临时检索结果永久变成 Conversation 内容。

---

<a id="s13"></a>

## 2. Model Provider 与 BYOK

<a id="s13-01"></a>

### 2.1 Provider 管理

用户可以配置多个 Provider Connection（服务商连接），包括：

- 官方服务商 API；
- OpenAI-compatible 兼容端点；
- 聚合服务；
- 用户自建兼容端点；
- 本地模型服务。

<a id="s13-02"></a>

### 2.2 Credential（凭据）

凭据由系统安全存储管理，普通数据库只保存引用，不保存明文密钥。

架构应允许：

- API Key；
- OAuth；
- 本地认证；
- 无凭据本地端点。

<a id="s13-03"></a>

### 2.3 Model Discovery（模型发现）

Mira 可以读取 Provider 模型列表，但用户始终可以手工填写 Model ID。

发现失败不应阻止用户使用私有部署名或新模型。

<a id="s13-04"></a>

### 2.4 用途级路由

用户可以为不同用途设置模型：

```text
conversation
agentReasoning
memoryExtraction
knowledgeProcessing
compact
embedding
vision
speech
```

一次 Agent Turn 内主模型路线保持固定。一个 Provider 支持聊天不代表支持工具调用或结构化提取；设置中分别显示各能力是否通过验证，以及当前可使用的功能。

跨 Provider Fallback（跨服务商降级）默认禁止；只有用户显式配置后才能发生。

用途路线缺失时提示配置，不把主对话模型默认为所有后台任务的已授权路线。可以由用户一键将已配置路线应用到选定用途，并说明这些用途的额外数据处理。

<a id="s13-05"></a>

### 2.5 使用量与费用

Mira 应展示：

- 输入和输出 Token；
- Provider 返回的 Cache Read / Write Token；
- 当前模型和连接；
- 基于价格目录计算的费用估算；
- 前台任务与后台任务的费用拆分。

费用必须标记为估算，不冒充服务商账单。

---

<a id="s14"></a>

## 3. Context Engine 的产品行为

<a id="s14-01"></a>

### 3.1 三层 Context

每轮模型请求由三类内容组成：

```text
Stable Header
稳定头部

Durable Conversation Surface
可持续的对话表层

Turn-scoped Context
仅当前请求有效的上下文
```

#### Stable Header

包括：

- Mira 身份与系统规则；
- 权威等级和安全规则；
- 当前冻结的工具定义；
- 当前执行配置。

#### Durable Conversation Surface

包括：

- 用户消息；
- Assistant 最终消息；
- 必须保持连续性的操作结果；
- Compact Checkpoint；
- 明确的用户 Steering（转向或纠正）。

#### Turn-scoped Context

包括：

- 本轮相关 Memory；
- Knowledge Source 片段；
- Working Memory；
- 当前时间和环境状态；
- 临时搜索结果；
- 本轮用户输入。

Turn-scoped Context 保存在 Request Snapshot（请求快照）中以便审计，但下一轮不默认继续注入。

<a id="s14-02"></a>

### 3.2 正确性优先于缓存

Mira 应尽量保持 Stable Header 和 Durable Conversation Prefix（持久对话前缀）稳定，以利用 Provider 的 Prompt / KV Cache（提示词 / 键值缓存）。

但不能为了缓存命中，把第三轮检索到的无关资料一直留到第三十轮。

产品原则是：

> 在不损害当前回答相关性、正确性和隐私边界的前提下保持前缀稳定。

<a id="s14-03"></a>

### 3.3 有限预取与 Agent 主动检索

每轮开始前进行轻量本地预取，只提供少量高相关 Memory。

复杂历史问题由 Agent 主动调用：

- `memory.search`；
- `knowledge.search`；
- `source.open`；
- `timeline.search`。

这两条路径共同存在，不二选一。

“仅当前请求有效”意味着每次实际发送前重新选择与验证资料；一次用户回合内，后续工具步骤仍保留完成任务所需的工具调用与结果。回合结束后，临时检索不自动进入下一回合。具体协议配对与预算规则由架构文档定义。

<a id="s14-04"></a>

### 3.4 Context Inspector

用户可以查看：

- Stable Header 的版本；
- 本轮使用的 Memory；
- 本轮使用的资料片段；
- 每项的来源与选择原因；
- 哪些内容因预算被省略；
- 哪些内容仅本轮有效；
- 是否切换了 Prefix Series；
- Provider 实际返回的缓存使用数据。

<a id="s14-05"></a>

### 3.5 Prompt 呈现规则

架构必须定义稳定的 Prompt Composition Contract（提示词组合契约），包括：

- Mira 身份；
- 权威顺序；
- Memory 呈现格式；
- 未确认、过期和冲突信息的处理；
- 外部文档不得升级为系统指令；
- Prompt 和 Renderer（渲染器）版本追踪。

PRD 不冻结具体 XML 或 Markdown 语法，但要求不同 Provider 获得语义一致、可审计的上下文。

<a id="s14-06"></a>

### 3.6 Compact

Compact 是 Conversation 内部的模型上下文压缩，不是 Memory，也不会删除原始 Message。

基线规则：

- 压缩最旧的连续完整区间；
- 保留最近 Conversation Tail；
- 不拆开 Tool Call 与对应 Tool Result；
- 结果只有确实减少 Token 时才落地；
- Compact 使用独立用途模型路线；
- 当 Compact Route 与主对话路线相同时，可以重放相同前缀尝试利用缓存；
- 当路线不同时，只发送必要的待压缩区间，不强求原会话缓存；
- Compact 后从替换点建立新的稳定前缀。
