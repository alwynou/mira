# Chinese memory correction follow-up

Date: 2026-09-22. Issue: [#43](https://github.com/alwynou/mira/issues/43).
Baseline: `29b1d7c`; branch: `codex/chinese-memory-diagnostics`.

## Diagnostic correction

The previous [correction evaluation](MEMORY_CORRECTION_VERIFICATION.md) preserved a Chinese case that failed with `storage` before its first state snapshot. That report predates failure-stage instrumentation and cannot identify which operation failed. Its temporary library was removed. The historical report remains unchanged, and this increment does not infer a database or provider defect from the generic code.

Review found a concrete loss in the evaluation harness: failed or indeterminate admission results already carry a typed safe error, but the step and follow-up guards replaced it with a generic storage wrapper. Completion errors could similarly lose their category when an execution audit was unavailable. The harness now records the audit's safe error code first, otherwise the command result's typed code, otherwise a fixed admission/execution fallback. The original error message never enters the report. Request-cap denial retains its separate classification. A failed/indeterminate completion no longer causes a required status query that could obscure the earlier result; best-effort audit evidence still has precedence. Stage labels distinguish completion failure from a status query that actually ran.

This changes only the opt-in evaluation harness. No memory/runtime/provider behavior, model prompts, authorization policy, validator acceptance, thinking mode or extraction timing is changed. The confirmed diagnostic loss is not established as the cause of the previous Chinese failure.

## Verification

Local environment: Apple Silicon, macOS 27.0 (26A428), Xcode 27.0 (27A266a). The app and focused host tests use pinned dependencies and `CODE_SIGNING_ALLOWED=NO`. The new offline regression checks failed and indeterminate command codes, audit precedence with and without a failed commit result, the no-typed-error fallback, and serialization excluding an error-body sentinel actually supplied to those paths. Existing cap-denial and incremental-report checks remain.

The focused run passed eight offline host tests with two opt-in entries skipped. The final scoped rerun also covers the completion-stage labels refined after the live confirmation. Language policy passed with 2,238 bilingual strings. No target or source file was added, so project generation is not required. This is not macOS 15 runtime acceptance.

## Bounded synthetic reruns

Only `zh-update-style-explicit-replacement` is selected. Each run uses a fresh disposable library, the production HTTP adapter, `deepseek-flash` on `api.deepseek.com`, `chat.completions` / `deepseek.chat`, provider-default thinking, the existing local Qwen embeddings, a 1,000,000-token context limit, and an 8,192-token conversation/extraction output ceiling. Production idle extraction remains 120 seconds; the evaluator observes for up to 240 seconds without advancing its clock or adding filler turns. No personal library or Keychain credentials are read.

The separate aggregate ceiling is 24 credential request authorizations. Each run has a cap of 12; the launcher refuses to overwrite a report, refuses an unsettled prior run, and verifies the sum of finalized authorizations plus a proposed cap remains within 24. Credential authorizations are not transport dispatch counts or bills. Only attempt metadata explicitly recording dispatch is counted as known extraction dispatch evidence.

The [unchanged baseline report](evidence/chinese-memory-correction/baseline.json) completed on `29b1d7c` with seven authorizations and two completed extraction dispatches. It establishes the original background-first preference with observed-user authority, then replaces it through one exact foreground save before background extraction. The successor has only the correcting source, the predecessor is superseded, and a fresh session receives only the successor revision. Agent semantic review confirms the successor and answer describe conclusion before background. The answer's additional suggested structure is general advice, not a persisted new preference. Its literal memory reference is not recorded as a verified visible citation; this sample makes no citation-rendering claim.

The [unchanged confirmation report](evidence/chinese-memory-correction/confirmation.json) also completed with seven authorizations and two completed extraction dispatches in an independent library. It used the typed-code harness correction; the final completion-stage label refinement followed this run. Production behavior was identical in both runs. Its immediate foreground replacement, later extraction, exact correction evidence, predecessor history and fresh-session context checks all passed. Agent semantic review confirms the memory and answer use conclusion before background. The answer mentions the old ordering explicitly as superseded, so its forbidden-keyword observation is true without contradicting the corrected preference.

| Run | Authorization cap | Authorizations used | Recorded extraction dispatches | State result |
|---|---:|---:|---:|---|
| Baseline | 12 | 7 | 2 | Completed; no mismatches |
| Independent confirmation | 12 | 7 | 2 | Completed; no mismatches |
| Total | 24 | 14 | 4 | Two successful samples |

All four recorded extraction attempts completed with provider-reported input/output and reasoning usage; these counters do not establish an exact monetary bill. The remaining authorization allowance was not used. No new failed or partial attempts were omitted. The older failures remain in their original evidence, including unknown usage where it was unknown.

Neither run reproduced the prior `storage` failure. The Chinese scenario now has two successful authored synthetic samples, but completion does not explain the historical failure or establish a general Chinese-memory success rate. [#43](https://github.com/alwynou/mira/issues/43) remains open for that unclassified historical failure; a future recurrence should be investigated using the stage and preserved safe error code before selecting a production fix. Keyword observations are descriptive only; state identity, lineage and context checks are distinct from agent semantic review of memory bodies and answers. Retraction without a stable replacement, independent human labeling and broad M3 quality remain outside this increment.
