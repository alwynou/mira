# 本地搜索与中文检索

**文档版本：** v1.2  
**更新日期：** 2026-09-05  
**状态：** 设计基线；当前实现与验收范围见 [实施记录](../engineering/IMPLEMENTATION_STATUS.md)。

定义检索管线、FTS 能力探测、短查询回退、规范化、结果与向量扩展；量化验收门槛在质量标准中。

返回 [ARCHITECTURE.md](../ARCHITECTURE.md) · 版本范围：[MVP](../MVP.md)

---

<a id="s25"></a>

## 1. Search Index Architecture

中文搜索是基础可用性，不是后续增强。

<a id="s25-01"></a>

### 1.1 Search Pipeline

```text
Query Normalize
        ↓
Language / Character Pattern Detect
        ↓
FTS Candidate Search
        ↓
Metadata / Scope / Time Filter
        ↓
Entity / Alias Expansion
        ↓
Optional Vector Candidate Merge
        ↓
Rank / Deduplicate
        ↓
Typed SearchResult
```

<a id="s25-02"></a>

### 1.2 FTS 双路径基线

#### Word-oriented Index

FTS5 `unicode61` 用于：

- 英文；
- 数字；
- Swift 类型名；
- 文件名；
- 大部分代码 Token；
- 拉丁语前缀和短语。

#### CJK / Substring Index

FTS5 `trigram` 用于：

- 中文和混合文本子串；
- 无空格语言；
- 文件路径片段；
- 用户不精确的局部查询。

#### 少于三个 Unicode 字符的中文查询

`trigram` 对短查询能力有限。采用：

```text
先应用 Scope / 类型 / 时间硬过滤
+
规范文本列上的有界 LIKE / 前缀查询
+
严格 Result Limit
```

避免全库无限扫描。SQL `LIMIT` 只限制返回行数，不能限制为找到这些行所做的扫描；实现必须另设候选扫描上限与可取消的查询时间预算。MVP 初始最多扫描 20,000 个已按 Scope 过滤的候选、最多 200 ms，超限显示结果不完整并提示增加关键词 / 筛选条件，不能把截断结果称为全量。

启动时用实际链接的 SQLite 创建临时 FTS5 unicode61 / trigram 表进行能力探测；不能把开发机 sqlite3 CLI 的能力当成发行 App 在最低系统上的能力。若 trigram 缺失，使用已测试的受限文本回退并明确性能边界，禁止静默显示中文搜索无结果。正式选择系统 SQLite 或自带 SQLite 的依据是最低支持系统的探测与性能门槛。

<a id="s25-03"></a>

### 1.3 Normalization

- Unicode 规范化；
- 大小写折叠；
- 全角 / 半角规范化；
- 可配置标点处理；
- 保留代码中的 `_`、`.`、`/` 等有意义边界；
- Entity Alias 单独索引。

规范化后的检索列与原文分开保存，原文和引用定位不被大小写或 Unicode 转换改写。FTS 查询使用字面词构造器，SQL 参数绑定；用户输入的引号、MATCH 运算符、`%` 和 `_` 不直接当作查询语言执行。

<a id="s25-04"></a>

### 1.4 SearchResult

```text
SearchResult
├── kind                  memory / note / sourceChunk / message / task / event / transaction / artifact
├── id
├── title
├── snippet
├── score
├── sourceReference
├── workspaceId?
├── occurredAt / updatedAt
└── matchReasons[]
```

<a id="s25-05"></a>

### 1.5 Vector Index

向量检索是可选增强：

- 索引可重建；
- 记录 Embedding Model、维度和版本；
- 不把向量数据库作为事实源；
- Provider 不可用时 FTS 仍可工作；
- 隐私策略决定哪些内容可以发送远程 Embedding。

<a id="s25-06"></a>

### 1.6 Search Eval Dataset

初始数据集必须包含：

- 两字中文；
- 三字及长中文词；
- 中文同义改写；
- 中英混合；
- 英文缩写；
- Swift 类型名和函数名；
- 文件路径；
- 数字、金额和日期；
- Workspace Scope；
- 已被替代 Memory；
- 不应返回任何结果的负样本。

指标：Hit@K、MRR、Scope Leak、Short-query Latency、Irrelevant Result Rate。
