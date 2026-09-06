# Usage and cost contract

This document owns v0.1 token accounting and cost estimation. Provider wire contracts remain in [Providers](PROVIDERS.md); extraction reservations remain in [Automatic memory](AUTOMATIC_MEMORY_IMPLEMENTATION.md).

## Reported usage

`TokenUsage` preserves optional input, output, cache-read, cache-write, and reasoning counters. A missing counter remains unknown. `inputTokenBasis` distinguishes input that includes cache (Chat Completions) from uncached input (Anthropic Messages). `totalInputTokens` adds the separately reported cache categories only when both are known. Reasoning tokens are part of output and are never billed a second time.

Adapters normalize cumulative reports within a single call. OpenAI reads nested prompt/completion details, DeepSeek reads `prompt_cache_hit_tokens`, Kimi reads `cached_tokens`, and Anthropic preserves cache fields from `message_start` through partial `message_delta` reports. Conflicting cache aliases, negative counts, counters above the per-call limit, and impossible subset counts are rejected. No adapter invents a cache zero.

Distinct foreground calls add counters only when every component is known. An interrupted follow-up without usage makes the execution aggregate unknown, even if an earlier tool decision completed with usage. Per-attempt records retain available counters. Failed, interrupted, or still-running calls cannot produce a complete cost estimate from partial counters.

## Frozen pricing

The bundled, offline models.dev snapshot supplies advisory USD prices per million text tokens. Prices belong to the provider-specific `api.json` entry, exact model ID, and allowlisted official endpoint. China/international providers and relay/native providers never share prices merely because model names match. Custom endpoints have unknown prices.

`ModelCatalogMetadata.pricing` contains Decimal input/output/cache-read rates, permitted base URLs, an optional supported input range, and an optional provider effective date. Its enclosing metadata records source URL, snapshot hash, and retrieval timestamp. Retrieval time is not presented as a provider's effective date. The complete metadata is frozen in the execution route or background attempt route. Updating settings or the bundled catalog does not reprice historical calls. Existing saved metadata acquires new prices only when the user applies a current catalog reference and saves the model.

The current estimator supports base text tariffs. For a known context pricing threshold, ingestion restricts the base tariff to inputs strictly below the first threshold; calls at or above that boundary remain unknown. Non-text/audio tariffs, separately priced reasoning, and unsupported tier shapes do not acquire a misleading flat price. Positive cache-write usage remains unpriced because cache lifetime rates are not represented yet. Missing usage or required cache prices also makes the estimate unknown. Explicit reported zero and explicit catalog zero are distinct from missing data.

For inclusive input, cost is `(input - cacheRead) × inputRate + cacheRead × cacheReadRate + output × outputRate`, divided by one million. For exclusive input, the reported input is already uncached. This formula is used only after validation and after ruling out unknown or positive cache writes where applicable. It is an advisory estimate of standard text usage, not a provider invoice, service-credit calculation, or spending guarantee.

## Persistence, settlement, and presentation

Schema **11** stores the full value as `usage_json` in executions, foreground attempts, and memory extraction attempts. Typed reads and backup validation check the counters and historical pricing metadata. There is no migration from earlier development schemas. The loader rejects unsupported versions; the authorized development procedure deletes obsolete runtime libraries without backup and reuses the current path.

Foreground estimates are calculated per actual model attempt from the frozen execution route. Background job details expose dispatched attempts, their own route snapshots, dispatch times, finality, and usage. Retries remain distinct calls. A combined total is shown only when every recorded call is known; otherwise the UI shows unknown, a known subtotal, and the number of unpriced calls. The execution inspector and extraction status distinguish foreground and background costs. No-call states are displayed separately from a zero charge.

Background token budgets use complete inclusive input plus output. Missing cache totals on an exclusive-input protocol charge the reserved ceiling conservatively. Failed extraction attempts retain their existing conservative reservation charge and show unknown monetary cost; collecting partial failure counters across the worker timeout boundary is not part of this increment. Day attribution continues to use each attempt's actual dispatch time. No monetary hard-limit setting is introduced.

Ordinary logs contain neither usage source bodies nor credentials. Forgetting sensitive bodies leaves accounting metadata available under the existing retention boundary. Prices are calculated from persisted non-secret snapshots and usage; no runtime catalog fetch or paid endpoint is needed to display history.

## Sources

- [models.dev schema](https://github.com/anomalyco/models.dev/blob/dev/packages/core/src/schema.ts) and [contributor contract](https://github.com/anomalyco/models.dev/blob/dev/AGENTS.md): provider-specific rates and pricing dimensions.
- [Anthropic prompt caching](https://platform.claude.com/docs/en/build-with-claude/prompt-caching): cache counters and lifetime-specific rates.
- [Kimi Chat API](https://platform.kimi.ai/docs/api/chat): cached input usage.

See [verification evidence](../engineering/USAGE_COST_VERIFICATION.md) for tested cases and remaining acceptance gaps.
