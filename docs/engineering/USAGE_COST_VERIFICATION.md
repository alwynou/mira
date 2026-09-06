# Basic usage and cost verification

Date: 2026-09-06. Branch: `dev`.

The user explicitly deprioritized comprehensive cost accounting during this increment. This implementation stops at basic estimates and correct unknown-state handling. Advanced prices, money limits, invoice reconciliation, and a usage dashboard are deferred. Streaming-performance work remains paused. The contract is [Usage and cost](../architecture/USAGE_AND_COST.md).

## Delivered

- Optional cache-read, cache-write, and thinking counters, with explicit inclusive/exclusive input semantics, normalized by the provider adapters.
- Frozen catalog prices in foreground execution routes and background attempt routes, with per-call and foreground/background estimates. Unknown calls keep the combined total unknown and remain visible next to the known subtotal.
- Partial/interrupted calls do not produce complete estimates. Distinct model decisions retain separate counters; a missing later report invalidates the execution total. Large valid aggregates use a separate bound from individual provider reports.
- Input/output, cache, and thinking usage in execution details and background memory status. Thinking stays within output cost. Cost formatting follows the display locale and distinguishes tiny nonzero amounts from zero.
- Execution audit presentation is tied to the loaded execution identity, preventing stale usage from being calculated against a newly selected route.
- Schema 11 uses validated `usage_json`; inclusive background budgets count separately reported caches, with conservative reservation charging for missing totals. Historical route/pricing metadata is validated on reads and restore.

The regenerated models.dev snapshot contains 540 models (no additions/removals), 493 supported base-rate entries, and 44 entries restricted to a conservative input range. Source SHA-256: `e110ff7f880cc2cf6e6a432d6094cf12eb6d4b65146a4295fdddd48c0d1633ff`; retrieved `2026-09-06T12:29:24Z`. The only unrelated upstream metadata changes are corrected OpenRouter output limits for `deepseek/deepseek-v4-flash-0731` (943718 → 131072) and `~deepseek/deepseek-v4-flash-latest` (131072 → 943718). The checked-in catalog reproduces identically from that source with the generator.

Separate reasoning tariffs, positive cache-write usage, unsupported dimensions and above-range calls remain unknown. This includes current native DeepSeek price entries with an explicit reasoning tariff; it does not restrict model selection or thinking. Direct and proxy endpoints do not inherit each other's prices. Prices remain advisory metadata from [models.dev](https://github.com/anomalyco/models.dev/blob/dev/packages/core/src/schema.ts).

## Evidence

Local verification uses isolated temporary libraries, synthetic transports, Apple M1 Pro, macOS 26.6.2, and Xcode 26.6. No paid model endpoints or user libraries were used.

- Full package suite: **326 tests in 35 suites passed**. The existing opt-in scale benchmark remains skipped by the ordinary test command.
- Hostless app tests: **5 XCTest cases + 59 Swift Testing cases passed**, including both cost languages and tiny-amount formatting.
- Debug app build passed through the host test command. The final Release build passed. The staged Xcode project was generated twice from an isolated export and reproduced identically; unrelated icon/design work was excluded.
- Python tooling: **14 tests passed**. Catalog malformed values, zero-vs-missing, context bands and provenance cases are covered.
- Language policy and compiler-extracted coverage passed for **1,153 bilingual entries**.
- Provider tests exercise repeated cumulative reports, cache aliases/conflicts, Anthropic partial event merging, omitted counters, invalid values and interrupted streams.
- Runtime/store tests cover the missing-usage follow-up, extended usage across reopening, inclusive/exclusive extraction charges, reserved fallback, invalid-use atomicity, snapshot freezing and incomplete totals. The existing current-format backup/reopen suite passes with schema 11.

Initial test runs exposed stale adapter-version assertions, a Swift test macro error, and host-test resource loading. These were corrected before the full reruns. The first implementation [CI run](https://github.com/alwynou/mira/actions/runs/34034170246) passed package, catalog and language checks but failed the existing deferred-scroll scheduler test: it assumed a callback would execute within a fixed 40 ms sleep. The test harness now waits for the actual callback with a bounded deadline; the production scheduler, renderer and animation code are unchanged. The full local host suite passed again. This is test synchronization, not new streaming-performance acceptance.

## Remaining acceptance

The native UI capture service previously failed with ScreenCaptureKit `-3811`; no new attended UI walkthrough is claimed here. Real provider billing comparison, extraction/citation quality, macOS 15 runtime use, keyboard/VoiceOver exercise, seven-day usage and signed/notarized distribution remain open in the [execution ledger](MVP_EXECUTION.md). Those core and delivery checks take priority over further cost work.

This is a direct development schema change. Existing schema-10 libraries and their backups are preserved and rejected intact by the new version; a fresh directory is needed to run it. The user's running app, `.build/dev-library`, default library, icon/design assets, and prototypes were not replaced or deleted.
