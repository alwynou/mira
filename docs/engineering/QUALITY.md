# 测试、评估与发布质量标准

**文档版本：** v1.2  
**更新日期：** 2026-09-05  
**状态：** 设计基线；当前实现与验收范围见 [实施记录](IMPLEMENTATION_STATUS.md)。

定义各层测试、模型评估、性能与成本观测，以及开发和发布的质量门槛；不记录尚未执行的测试为通过。

返回 [ARCHITECTURE.md](../ARCHITECTURE.md) · 版本范围：[MVP](../MVP.md)

---

<a id="s31"></a>

## 1. Testing 与 Eval Strategy

<a id="s31-01"></a>

### 1.1 Domain Tests

- Scope；
- 时间有效性；
- Revision；
- Evolution；
- Structured Record 变更；
- Delivery Owner；
- 删除语义。

<a id="s31-02"></a>

### 1.2 Runtime Tests

- Agent Loop 停止条件；
- Tool Call / Result 配对；
- 并行屏障；
- 取消竞态；
- Model Attempt 唯一终态；
- Crash Recovery；
- Draft 恢复；
- Retry 不重复副作用。

<a id="s31-03"></a>

### 1.3 Provider Contract Tests

每个 Adapter 使用同一套测试：

- 文本流；
- 多 Content Block；
- Tool Call；
- 参数 Delta；
- Usage；
- 取消；
- 429 / 5xx；
- 非法响应；
- 一次且仅一次 Terminal Event；
- 手工 Model ID；
- 能力覆盖。

<a id="s31-04"></a>

### 1.4 Prompt Golden Tests

固定输入生成稳定快照：

- System Prompt；
- Memory Rendering；
- Untrusted Source 边界；
- Tool Schema 排序；
- Project Context；
- Candidate 排除；
- 冲突 Memory 表达；
- 版本字段。

<a id="s31-05"></a>

### 1.5 Memory Extraction Eval

Fixture 至少覆盖：

- 用户明确“记住”；
- 清晰用户决定；
- Assistant 建议；
- 用户引用他人观点；
- 假设和问句；
- 临时情绪；
- 敏感信息；
- Global / Workspace Scope；
- 时间状态；
- 重复；
- `replaces` 候选；
- 中英混合表达。

指标：

```text
Precision
Recall
Speaker Attribution Accuracy
Scope Accuracy
Temporal Accuracy
Active / Candidate Policy Accuracy
Duplicate Rate
```

<a id="s31-06"></a>

### 1.6 Memory Retrieval Eval

指标：

```text
Hit@K
MRR
Scope Leak Rate
Superseded Recall Rate
Irrelevant Injection Rate
Empty Retrieval Correctness
Source Citation Accuracy
Token Cost per Useful Hit
```

<a id="s31-07"></a>

### 1.7 End-to-End Continuity Eval

```text
Conversation A 形成决定
        ↓
Memory 提取并保存
        ↓
Conversation B 提问
        ↓
预取或 Agent Search 找回
        ↓
回答正确使用
        ↓
引用正确来源
        ↓
不混入相似但错误的 Memory
```

这是 Mira 第一核心质量门槛。

<a id="s31-08"></a>

### 1.8 Provider Matrix

同一 Fixture 在首批支持模型上运行，区分：

- Prompt / Pipeline 缺陷；
- Provider Adapter 缺陷；
- 模型能力差异；
- Structured Output 稳定性；
- 成本差异。

<a id="s31-09"></a>

### 1.9 Search Eval

使用[相关规范 §1.6](../architecture/SEARCH.md#s25-06)中文、英文、代码和负样本数据集。

<a id="s31-10"></a>

### 1.10 Persistence Tests

- Migration from every supported schema；
- 事务故障注入；
- WAL Crash Recovery；
- Blob 丢失 / Hash 不匹配；
- Mark-and-Sweep；
- TypedJSON 未知版本；
- 索引删除后重建；
- 大数据分页。

<a id="s31-11"></a>

### 1.11 Architecture Tests

通过 Swift Package 依赖和静态检查保证：

- Core 不导入 Apple UI / EventKit / GRDB；
- View 不直接依赖 Database；
- Provider Wire 类型不进入 Core；
- Secret 类型不实现普通日志描述；
- 禁止跨层反向依赖。

---

<a id="s32"></a>

## 2. Performance、成本与冷启动

<a id="s32-01"></a>

### 2.1 请求性能指标

记录：

```text
contextBuildMs
memoryPrefetchMs
providerQueueMs
timeToFirstTokenMs
modelTotalMs
toolExecutionMs
persistenceCommitMs
```

<a id="s32-02"></a>

### 2.2 Context 成本

- Stable Header Hash；
- Durable Prefix Token；
- Turn Context Token；
- Memory Token；
- Tool Schema Token；
- Cache Read / Write Token；
- Compact 前后 Token。

<a id="s32-03"></a>

### 2.3 Background Budget

```text
dailyRemoteTokenBudget
monthlyEstimatedCostBudget
maxConcurrentBackgroundJobs
battery / power policy
idle policy
```

达到预算后后台任务暂停，不影响用户本地数据访问。

<a id="s32-04"></a>

### 2.4 典型成本场景

架构应提供可配置模拟器，而不是在文档写死某个价格：

```text
每日 Conversation Turn
平均输入 / 输出 Token
Memory Extraction 频率
文档导入频率
Compact 频率
Embedding 频率
Provider 价格目录
        ↓
日 / 月估算
```

价格变化时只更新目录，不修改历史 Usage。

<a id="s32-05"></a>

### 2.5 Database 性能

- Message / RuntimeEvent 使用 RowID 和 Sequence；
- 常用列表有覆盖索引；
- Search 和 Timeline 使用分页；
- 大型正文不在列表 Query 中读取；
- Graph 只加载可见子图；
- 定期 `ANALYZE` / 合理维护由 Data 层控制。

<a id="s32-06"></a>

### 2.6 冷启动

首次使用不依赖已有 Memory：

- Provider 配置后立即对话；
- 创建 Workspace / Project Context；
- 导入文件并本地搜索；
- 创建 Task / Reminder；
- 首次自动 Memory 提供 Undo / Edit / Source 反馈。

实现顺序由 [MVP](../MVP.md) 统一定义。上述内容是完整产品的冷启动方向，Task / Reminder 不属于 v0.1。

---

<a id="quality-gates"></a>

## 3. MVP 质量门槛

以下是首个版本的验收目标，不是已经取得的结果。所有检查记录 Fixture 版本、实现提交、操作系统 / CPU / 内存、Provider / Model ID、参数、Prompt / Adapter 版本、调用数与费用。模型指标逐个已验证配置计算，不能用两家平均值掩盖某一家不合格。

### 3.1 门槛矩阵

| ID | 验收对象 | 通过条件 | 阶段 |
|---|---|---|---|
| Q01 | 信任与隐私 | 固定攻击 / 越权集全部通过：跨 Scope、neverRemote、来源策略继承、授权撤销、伪造引用、工具权限注入均无越界结果 | M2–M5 |
| Q02 | Runtime 确定性 | Fake Provider / Tool 的正常、拒绝、失败、取消、超时、重试、工具配对、EOF 和完成竞态全部通过；无重复终态与重复提交 | M1–M2 |
| Q03 | 数据可靠性 | 每个已发布 Schema 可迁移；提交、Blob 安装、清理、备份 / 恢复故障注入全部通过；恢复后完整性与引用校验通过 | M0–M5 |
| Q04 | Memory Extraction | 至少 160 条人工标注 Fixture（正 / 负样本各至少 80），每个验证模型运行 3 轮；Active Precision ≥98%，适合捕获的清晰陈述 Recall ≥80% | M3–M5 |
| Q05 | Memory Retrieval | 至少 80 条查询，Hit@6 ≥90%；Scope 泄漏、已替代 / 已删除普通召回均为 0；所有抑制重跑 Fixture 不复活 | M3–M5 |
| Q06 | 连续性与引用 | 至少 40 个跨 Conversation 场景，每个验证模型 3 轮；回答正确使用记忆且引用正确的比例 ≥90%；系统将引用解析为真实对象的准确率 100% | M3–M5 |
| Q07 | 搜索与性能 | 中文短词、混合文本、代码 / 路径、空结果和查询转义 Fixture 全部通过；本地性能符合下表，超限不假称完整结果 | M4–M5 |
| Q08 | 使用与恢复体验 | 键盘完成核心流程、VoiceOver 可辨状态、取消 / 错误 / Undo / 来源 / 恢复入口可用；至少 7 天真实使用记录无未解决严重缺陷 | M5 |
| Q09 | 分发 | 每个标为支持的最低系统 / CPU 通过安装与升级；对外版本签名、公证及迁移恢复通过 | M5 对外交付 |

Q04 的敏感自动捕获、Assistant 建议冒充用户决定、Scope 错误、未确认高影响替代，以及 Q06 中无授权副作用是单独的零容忍 Fixture：即使平均指标达标，出现一次也阻止该配置启用相关能力。有限 Fixture 通过不是对所有未来输入的零错误保证。

Precision / Recall 分母、允许的多条等价答案、引用正确性与负样本定义随数据集保存；正例同时标注主体、Scope、时间、授权与应为 Active / Candidate / 不保存。不得只用相同模型自评其输出，也不得把手工删掉失败样本当作提升。

### 3.2 本地性能目标

参考数据规模：10,000 条 Memory、50,000 个 Markdown Chunk、100,000 条 Message；固定数据种子。参考最低验收设备为可运行 macOS 15、16 GiB 内存、SSD 的目标 Mac；记录具体 CPU，区分冷启动与热缓存。

| 测量 | 初始目标 |
|---|---|
| 启动到可操作本地页面 | 冷启动 P95 ≤3 秒，不等待 Provider |
| Memory 预取 + Context 构建 | P95 ≤300 ms，不含网络和 Provider 排队 |
| 本地搜索到可展示结果 | P95 ≤500 ms；短词扫描上限由 [Search](../architecture/SEARCH.md) 定义 |
| 流式 UI 主线程更新 | 无可复现的连续 100 ms 以上阻塞；通过 Instruments 验证 |
| 用户点击取消后的本地状态反馈 | ≤200 ms；网络真正停止另记录，不把外部取消延迟归为 UI 卡死 |

每项至少运行 30 次，保留分布与环境。若最低设备不达标，先定位瓶颈或明确缩小支持范围；调整目标必须记录理由，不能只改阈值让失败通过。Provider 首 Token 延迟只观测，不对用户作硬保证。

### 3.3 必需故障用例

- 同一消息重复提交、两个窗口发送、取消与 stream.completed 同时到达、取消后迟到 Delta。
- SSE 的中文 UTF-8 跨网络块、未完成工具参数、未知事件、连接直接 EOF、重复 Usage 与缺失 Usage。
- 同一提取源重复 Job、版本升级、处理期间撤销 / 遗忘、Scope 变更、Provider 策略收紧。
- 替代关系循环、冲突替代、删除替代者、来源更新与来源删除。
- 两字中文无结果 / 超限、MATCH 特殊字符、不同 Workspace 猜测 ID、符号链接越界。
- Blob 写完而事务失败、事务成功后重启、GC 与新增引用竞态、备份期间 GC、缺失 / 错误 Hash。
- 备份路径穿越、错误 Schema、坏库、磁盘满、恢复中断；旧资料库保持可用。
- 恢复后不重放模型请求或副作用；凭据和失效文件授权不被恢复为有效。

### 3.4 真实 Provider 验证

CI 默认使用合成 Fixture 和 Fake Provider，不依赖开发者密钥，也不自动消耗真实模型额度。准备真实 Provider 凭据后，在本地手动运行受预算约束的协议与质量验证，只发送公开合成内容。

每一类协议至少选择一个实际可用的端点 / 模型，分别记录文本、工具调用、结构化提取、窗口配置、取消和 Usage 能力。任意兼容端点不自动继承这个结论；未通过提取的端点仍可作为聊天连接，但不启用其自动记忆用途。

真实模型 ID 与端点将在首次集成时由实际可用配置确定，目前未填写具体模型，不将任何价格、可用性或质量假设冻结为事实。

### 3.5 证据与执行状态

| 检查类型 | 本轮状态 |
|---|---|
| 文档结构、引用与规范一致性 | 本轮执行，结果记入评审记录 |
| 当前系统 sqlite3 CLI 的 trigram 探测 | 已执行，只对本机 CLI 有效；见 [参考资料](../REFERENCES.md) |
| Swift Package 构建、应用运行和测试 | 未执行；尚无工程代码 |
| 最低 macOS / Intel 验证 | 未执行 |
| 真实 Provider 协议与模型质量 | 未执行；实现时选择模型并配置凭据 |
| 签名、公证、安装升级与 7 天使用 | 未执行；发布前完成 |

后续测试报告保存命令、环境、结果摘要和失败样本定位；不在报告复制用户私密数据。实现变更后先运行受影响检查，完整发布门槛在候选版本统一执行。
