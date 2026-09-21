# Memory state-evolution evaluation

Date: 2026-09-21. Issue: [#40](https://github.com/alwynou/mira/issues/40).
Baseline: `ecd829a`; branch: `codex/memory-state-evaluation`.

## Scope

The existing opt-in host evaluator now inspects sequential memory changes through production application APIs. It covers automatic and explicit same-entity enrichment, correction, unresolved retraction, forgetting with a real library reopen, and related-but-unsupported questions. All conversation content is authored synthetic data in disposable temporary libraries. The evaluator does not open the personal library or system Keychain.

The previous state runner checked answer substrings without a durable evaluation report, effective lifecycle checks, lineage checks, or exception-safe cleanup. Its provider protocol parameter was parsed but not applied to the installed model. The revised setup binds the selected provider and validates the resolved invocation protocol/dialect before dispatch. Thinking retains the provider default.

Foreground enrichment is inspected immediately after the production save tool settles; a later extractor cannot conceal an independently duplicated foreground save. Automatic cases wait for the production idle trigger and persisted extraction settlement, with no shortened timer or filler turns. Effective lifecycle distinguishes current memory from raw `active` records that have been superseded, expired or forgotten.

The report separates state/identity assertions from answer keyword observations, retains failures and safe error codes, and records exact context memory references and citation resolution. A successful foreground reply does not establish extraction completion. An answer keyword match does not prove semantic correctness.

## Verification

Local environment: Apple Silicon, macOS 27.0 (26A428), Xcode 27.0 (27A266a).

- Focused `MiraHostTests/EverydayMemoryLiveTests` and `EverydayMemoryWaitTests` build and run passed: nine XCTest cases, including seven offline passes and two disabled live entries. The command used the pinned package versions and `CODE_SIGNING_ALLOWED=NO`. The stale-failure regression failed against the old waiter (`failed` / `invalidInput` instead of `unavailable` / no error), then passed with the source-scoped waiter. It uses a deterministic in-process adapter and the ordinary four-turn batch trigger, without model requests or an accelerated production clock. The other fixture checks cover protocol mismatches and valid DeepSeek setup, explicit state caps, strict corpus selection, duplicate current records, missing lineage/history, forgotten body/context availability, preservation of failed/unrun report cases, and the distinction between the last authorized read and a rejected credential admission.
- `python3 scripts/check_language_policy.py` passed with 2,238 bilingual strings; `git diff --check` passed. `xcodegen generate` registered the test-only embedding helper and wait regression. No production schema, UI, credentials or personal-library records were changed.
- Live evaluation is recorded below separately from these deterministic checks.

## Live sample

The sample uses `deepseek-flash` at the explicitly configured DeepSeek endpoint,
with `chat.completions`, `deepseek.chat`, the production HTTP adapter, provider-default
thinking and the production conversation instructions. The context limit is
1,000,000 tokens; conversation output is bounded at 8,192 and extraction output
at 2,048. The cached production Qwen 4-bit embedding model reached `ready` before
requests. This retains normal indexing and retrieval; readiness alone does not
prove that every retrieved result came from vector search.

The initial automatic-enrichment smoke run used seven of eight authorized
credential reads. Its unmodified [JSON report](evidence/memory-state-evaluation/smoke-auto.json)
retains the mismatch. The first statement was captured by background extraction.
On the second statement, the foreground model invoked `memory.remember`; the
subsequent extraction completed with zero memory writes. There was one current
consolidated memory, its predecessor was superseded, and both exact source
identities were retained. The fresh-conversation answer correctly described
Miso as a black shorthair cat. This is useful combined-path evidence, but it
does **not** qualify as a pure-background enrichment pass.

The [remaining six scenarios](evidence/memory-state-evaluation/remaining.json)
used their shared 40-authorization ceiling. Total use was 47 of the two configured
ceilings totaling 48. No automatic retry or unbounded rerun was performed. Both
live XCTest invocations exited with failures, as expected from the retained
mismatches and the final cap rejection; they are not reported as passing suites.

| Synthetic case | Observed result | Qualification |
|---|---|---|
| Automatic cat enrichment | One current black shorthair cat memory; both sources and history retained; fresh answer retains the supported facts. Second step used `memory.remember`. | Mixed-path result; pure background enrichment remains unqualified. |
| English tea replacement | Green tea and black tea both remain current and both enter fresh context. Later extraction paused. | Persisted correction conflict reproduced despite a plausible answer. |
| Chinese update-order replacement | Initial extraction paused; a foreground save records the new order; fresh answer uses it. Second observation hit the stale-error bug. | No established predecessor or qualified replacement chain. |
| Flight-preference retraction | Initial extraction paused; no memory established; follow-up reports no preference. Second observation hit the stale-error bug. | No retraction evidence; an empty baseline cannot validate this behavior. |
| Forget and reopen | Initial automatic capture succeeded; maintenance completed; settled close/reopen retains no current or historical body material; fresh context and answer omit the forgotten preference. | Complete state checks passed; answer review consistent. |
| Related but unsupported airline question | Hotel memory remains current; answer explicitly says no airline preference is known. | Complete state checks passed; answer review found no unsupported airline inference. |
| Explicit cat enrichment | Both tool writes committed; one current complete memory with both exact sources and superseded predecessor; later extraction completed with no duplicate. | State checks passed through background settlement. Fresh-conversation follow-up was blocked before credential authorization at the per-run cap. |

This is an agent review of authored synthetic answers, not independent human
labeling. The report's two `completed` cases are diagnostic outcomes, not an
estimate of general memory quality. No recognized visible citation syntax was
produced in these answers, so there were no positive citation-verification
examples; raw `memory:...` text in some answers does not establish a rendered or
verified citation.

Across both reports, 38 foreground attempt records have known usage totaling
87,303 input and 10,298 output tokens. Nine background attempts include six
completed attempts reporting 6,651 input and 2,481 output tokens and three paused
attempts with unknown usage. Input totals include cache tokens; output totals
include any reported reasoning subset. These are sums of distinct attempt IDs,
not billing totals. No monetary cost is asserted.

The live binary was built before a final evaluator review strengthened the
replacement oracle to reject a still-current predecessor and added exact
inherited-source identity checks. The final checks are verified offline, and
the saved live snapshots are rechecked against those stronger conditions. The
review also wired the ordinary evaluator's selected embedding mode into its
library opening; that separate entry is not used by these state-evolution runs.
No production behavior changed during the sample. Rechecking the saved snapshots
confirms exact inherited source-reference inclusion and superseded history for
both enrichment cases. The stricter replacement check still rejects the tea case
because it has two current records and no successor relation. The Chinese case
has no established predecessor and cannot pass a replacement check.

The live sample also exposed an observer defect: after a paused extraction, the
workload's source-independent failure remained set until a later extraction
event. The old waiter could therefore label the next message `failed` before
that message had a persisted job. The final evaluator removes that shortcut and
waits for the selected source's own job or timeout. The Chinese replacement and
flight-retraction runs contain this premature second-step result and remain
unqualified; their earlier paused jobs are real observations, while the later
job-less `failed` snapshots are evaluator failures, not proof of a second
product extraction failure. The original JSON is retained unchanged.

The English tea correction already demonstrates why answer-only checks were
insufficient: the follow-up recommends black tea, but both the old green-tea
and new black-tea memories remain current and enter the request context. The
foreground model used `memory.remember` for the ordinary correction even though
the tool description assigns ordinary statements to background capture and
excludes corrections from enrichment. Its new record has no predecessor
relation. The following extraction attempt was dispatched and paused, with no
reported usage. The public extraction report exposes that state but not its
causal error; no network, provider, parsing or token-limit cause can be claimed
from this artifact. Reserved/charged accounting for that attempt is an estimate,
not measured tokens or billed cost.

## Limits

This is a small diagnostic corpus with provisional authored labels. It does not satisfy the independent human labeling, corpus sizes, repeated runs or model coverage required by Q04–Q06. Semantic review of a handful of synthetic answers cannot establish population-level precision or recall. Native interface interaction, accessibility, macOS 15 runtime, Intel execution and distribution remain outside this change.

The live request cap counts credential-read authorizations immediately before transport creation, including authorizations that may not produce a completed HTTP response. It is distinct from dispatch count, token usage and billing. Reported token usage is retained separately for foreground and extraction attempts; unknown usage or cost must remain unknown.

The next priority is [#41](https://github.com/alwynou/mira/issues/41): diagnose
paused extraction and make ordinary correction durable, then complete the
unqualified live paths with a separately bounded run. The current evidence does
not justify changing product semantics or hiding failures with weaker labels.

Procedure: [Everyday memory testing](EVERYDAY_MEMORY_TESTING.md).
