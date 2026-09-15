# 用量与费用契约

<!-- Simplified Chinese documentation is explicitly requested by the user on 2026-09-12. -->

This document owns v0.1 token accounting and cost estimation. Provider wire contracts remain in [Providers](PROVIDERS.md); extraction reservations remain in [Automatic memory](AUTOMATIC_MEMORY_IMPLEMENTATION.md).

## Reported usage

`TokenUsage` preserves optional input, output, cache-read, cache-write, and reasoning counters. A missing counter remains unknown. `inputTokenBasis` distinguishes input that includes cache (Chat Completions) from uncached input (Anthropic Messages). `totalInputTokens` adds the separately reported cache categories only when both are known. Reasoning tokens are part of output and are never billed a second time.

Adapters normalize cumulative reports within a single call. OpenAI reads nested prompt/completion details, DeepSeek reads `prompt_cache_hit_tokens`, Kimi reads `cached_tokens`, and Anthropic preserves cache fields from `message_start` through partial `message_delta` reports. Conflicting cache aliases, negative counts, counters above the per-call limit, and impossible subset counts are rejected. No adapter invents a cache zero.

Distinct foreground calls add counters only when every component is known. An interrupted follow-up without usage makes the execution aggregate unknown, even if an earlier tool decision completed with usage. Per-attempt records retain available counters. Failed, interrupted, or still-running calls cannot produce a complete cost estimate from partial counters.

## Frozen pricing

The bundled, offline models.dev snapshot supplies advisory USD prices per million text tokens. Prices belong to the provider-specific `api.json` entry, exact model ID, and allowlisted official endpoint. China/international providers and relay/native providers never share prices merely because model names match. Custom endpoints have unknown prices.

`HTTPModelPricingSnapshot` 由 MiraProviders 拥有，记录准确 model ID、来源 URL、目录版本、获取时间与 `ModelPricing`。价格使用 Decimal，保留输入／输出／缓存读取费率、允许端点、可选输入范围和提供方生效日；目录获取时间不冒充价格生效日。快照存入冻结 `AgentModelRoute.configuration`，当前设置或目录更新不重算历史价格。只有用户显式应用并保存新目录资料，后续执行才采用新快照。

The current estimator supports base text tariffs. For a known context pricing threshold, ingestion restricts the base tariff to inputs strictly below the first threshold; calls at or above that boundary remain unknown. Non-text/audio tariffs, separately priced reasoning, and unsupported tier shapes do not acquire a misleading flat price. Positive cache-write usage remains unpriced because cache lifetime rates are not represented yet. Missing usage or required cache prices also makes the estimate unknown. Explicit reported zero and explicit catalog zero are distinct from missing data.

For inclusive input, cost is `(input - cacheRead) × inputRate + cacheRead × cacheReadRate + output × outputRate`, divided by one million. For exclusive input, the reported input is already uncached. This formula is used only after validation and after ruling out unknown or positive cache writes where applicable. It is an advisory estimate of standard text usage, not a provider invoice, service-credit calculation, or spending guarantee.

## Persistence, settlement, and presentation

前台尝试用量和终态来自当前会话日志，执行计划正文保存冻结路线；独立记忆提取尝试及预算事实保留在业务数据库。归约、类型化读取和当前格式归档校验用量与配置，不读取旧 SQL execution/message 表。旧开发库直接删除，在同一路径初始化当前格式，不添加旧 schema 解码或迁移。

`SessionExecutionAuditPage.modelUsage` 从同一日志 head 返回整次执行的全部尝试元数据，不受请求／输出正文分页限制；自动重试保留独立 ID，手动重试的新执行独立统计。`ModelCostSummary` 在 Provider 层逐次计算，只有全部已记录尝试都能估价才提供总额，否则显示未知、已知小计和未知次数。无调用与零费用分开显示。读取汇总不额外加载页外请求／输出。

原生执行检查器已接入这份完整汇总，按仍可读取的计划优先级显示前台／后台标题；计划因隐私维护已清理时使用通用标题，费用全部保持未知，不从当前设置补回历史价格。独立后台提取的[状态与用量查询](AGENT_EXTRACTION_QUERIES.md)已通过 `MemoryApplication` 接入检查器：按原始回合和工作区分页选择作业，每个作业读取全部尝试，以实际调度、终态、原始用量和逐次冻结路线单独汇总。未调度的预留不计调用，失败预算扣减不冒充实际用量；它与前台费用分别展示。审计权威与生命周期见[会话读取](AGENT_SESSION_READS.md)。

Background token budgets use complete inclusive input plus output. Missing cache totals on an exclusive-input protocol charge the reserved ceiling conservatively. Failed extraction attempts retain their existing conservative reservation charge and show unknown monetary cost; collecting partial failure counters across the worker timeout boundary is not part of this increment. Day attribution continues to use each attempt's actual dispatch time. No monetary hard-limit setting is introduced.

Ordinary logs contain neither usage source bodies nor credentials. Forgetting sensitive bodies leaves accounting metadata available under the existing retention boundary. Prices are calculated only while the persisted snapshots remain readable; purged pricing stays unknown. No runtime catalog fetch or paid endpoint is needed to display history.

## Sources

- [models.dev schema](https://github.com/anomalyco/models.dev/blob/dev/packages/core/src/schema.ts) and [contributor contract](https://github.com/anomalyco/models.dev/blob/dev/AGENTS.md): provider-specific rates and pricing dimensions.
- [Anthropic prompt caching](https://platform.claude.com/docs/en/build-with-claude/prompt-caching): cache counters and lifetime-specific rates.
- [Kimi Chat API](https://platform.kimi.ai/docs/api/chat): cached input usage.

See [verification evidence](../engineering/USAGE_COST_VERIFICATION.md) for tested cases and remaining acceptance gaps.
