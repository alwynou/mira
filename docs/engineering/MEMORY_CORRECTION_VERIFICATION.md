# Memory correction and extraction diagnostics

Date: 2026-09-21. Issue: [#41](https://github.com/alwynou/mira/issues/41).
Baseline: `96e1416`; branch: `codex/memory-correction-diagnostics`.

## Behavior and diagnosis

The foreground save tool previously accepted independent creation and non-conflicting enrichment, but could not express a correction target. In the previous synthetic tea case the model called that tool for a correction, creating a second current preference. The updated tool uses a separate exact replacement target and keeps the predecessor in history. Source, scope, disclosure and revision checks apply before the atomic receipt transaction. A correction does not inherit the contradicted predecessor's evidence. Uncertain intent or target selection still requires clarification; the host does not infer semantic permission from keywords.

A dispatched extraction pauses whenever later processing fails. That state does not identify its cause. The worker also previously passed `AgentModelFailure` to the generic error conversion, losing the underlying provider failure code as a storage error. It now preserves the typed code with a fixed body-free message. Authorized status and report queries expose only the job's code, never error text or model content. The evaluator records this code instead of repeating the state label. A retry clears the prior error, and source privacy cleanup removes it.

The original reports under `evidence/memory-state-evaluation` remain unchanged. Their three paused attempts have unknown measured usage. These changes cannot retrospectively determine the cause or bill for those attempts.

The new baseline run reproduced two current tea preferences and a dispatched pause with persisted code `outputLimit`. The 2,048-token extraction output target is raised to 8,192 within the same frozen route maximum, preserving provider-default thinking, strict validation and the no-automatic-retry rule. This is a bounded allowance change, not a claim that larger budgets fix every malformed or interrupted response. The original three pauses remain unclassified.

The first post-change Chinese establishment attempt then failed with `invalidInput`; the synthetic watcher identified the static validator diagnostic for an invalid assertion aspect key. The rejected key itself was not retained, so its particular spelling is unknown. The published schema previously advertised only a maximum length, leaving several host constraints implicit. The final schema and instructions now publish the existing ASCII segment grammar, length bounds and reserved whole keys, and explain when null is appropriate. Validator acceptance is unchanged. Tests compare the advertised format with the validator across accepted and rejected keys, including Unicode, whitespace, length and reserved-key boundaries.

The evaluator now permits the explicitly targeted foreground correction path. When that path is used, it checks one current successor, exact source identity and superseded history immediately before waiting for background extraction. Independent establishment and pure-background enrichment still reject a foreground save, and all final state and fresh-context checks remain in place.

## Verification

Local environment: Apple Silicon, macOS 27.0 (26A428), Xcode 27.0 (27A266a). Verification uses synthetic data and temporary libraries, with no personal-library or Keychain access.

The selected package suites cover 67 tests: extraction queries/worker/validator, remember tool/handler/module and the memory workflow. They passed across focused runs, including the final 12-test workflow rerun and 22 validator tests. One newly added fixture initially lacked a model reply and attempted to suppress an unregistered source; correcting that fixture made the intended stale-revision and suppression checks pass. No production invariant was relaxed to pass it.

- Output-budget coverage checks the shared 8,192 target, a 4,096 route clamp and an adapter-specific legal override. Truncated output pauses with no completed commit. Wrapped network, provider, output-limit and cancellation errors retain their categories without carrying adapter-supplied request/error text into the job error.
- Query checks cover pre-dispatch failure, dispatched pause, retry clearing, reopen consistency, completed state, failure-source cleanup, workspace/session/execution filtering and unchanged unknown usage. The privacy test starts with a non-nil failure code and confirms its removal on suppression.
- Correction checks cover exact target references, mutually exclusive enrichment/replacement, current policy, one current successor, predecessor history, only the correcting source as evidence, idempotent receipt replay, stale revision between prepare and commit, source suppression and atomic rollback when relation insertion fails. Existing enrichment, receipt rollback, workspace disclosure and historical-citation tests remain passing.
- The app and focused host tests built successfully with pinned dependencies and `CODE_SIGNING_ALLOWED=NO`: nine XCTest cases, seven passing offline tests and two skipped opt-in live entries. The real waiter now reports its source job's `invalidInput` category, while a different source with no job still times out without inheriting that error.
- `python3 scripts/check_language_policy.py` passed with 2,238 bilingual strings; `git diff --check` passed. No source/target file was added, so no generated Xcode project change was needed.

## Live sample

The baseline used six of eight allowed request authorizations. Its unchanged [state report](evidence/memory-correction/baseline-tea.json) preserves the duplicate-current failure. A read-only watcher limited to the newly created disposable synthetic library captured the job's safe code before cleanup in [companion diagnostics](evidence/memory-correction/baseline-diagnostics.json). The job IDs match; the old evaluator's `paused` error field is a state label, while the companion records `outputLimit`. It does not contain request, output or thinking bodies.

The aggregate ceiling is 48 request authorizations. The first post-change run had a 28-authorization cap and used 23; its unchanged [report](evidence/memory-correction/intermediate-correction-and-auto.json) and [diagnostics](evidence/memory-correction/intermediate-diagnostics.json) preserve both the English correction pass and the Chinese/mixed-path failures. Later runs receive separate caps from the remaining aggregate allowance; unused allowances from settled runs are retired before reallocating them. The launcher sums finalized report counts and rejects a run whose cap would exceed the remaining aggregate budget. Authorization counts are not transport counts or bills. Provider/model, usage, dispatch evidence, memory histories and fresh-context identities are retained in the reports, including any failures. The production HTTP adapter, conversation instructions and provider-default thinking remain in use.

The intermediate automatic-enrichment case consolidated the facts with both sources and history, but the foreground model performed the second save. Its mismatch remains recorded. The final tool instructions explicitly prohibit ordinary new facts and non-conflicting additions without a save request, including additions about an existing entity. This clarification does not create a keyword-based permission gate or establish that a model will always follow the instruction.

The intermediate Chinese case is not a replacement pass: its predecessor was never established. The final evaluator also rejects an empty expected-predecessor set so a later independent save cannot produce a misleading local replacement-success label. Its overall intermediate failure remains unchanged.

A case status of `completed` means its host/state checks passed. Those checks verify identity, lifecycle, source lineage, history and context membership; they do not prove that the replacement wording expresses the corrected value. Answer keyword observations also remain observations, not a semantic oracle. The memory bodies and follow-up answers require separate semantic review. Any review recorded here is an agent review of authored synthetic content, not independent human labeling or population-level quality evidence.

The four runs settled at **46 of 48 request authorizations**. No cap denial occurred in the final explicit-save or final recheck runs. The table counts unique extraction attempt IDs with `dispatched: true`; it does not infer unrecorded transport dispatches from credential authorization counts.

| Run | Per-run cap | Authorizations | Recorded extraction dispatches | Outcome |
|---|---:|---:|---:|---|
| Baseline tea | 8 | 6 | 2 | Duplicate current preferences; one paused attempt with unknown usage |
| Intermediate correction and enrichment | 28 | 23 | 6 | English correction passed; Chinese establishment failed; automatic enrichment used the foreground path |
| [Final explicit save](evidence/memory-correction/explicit-final.json) | 8 | 8 | 1 | Tool commits, later extraction and fresh-session follow-up passed |
| [Final recheck](evidence/memory-correction/final-recheck.json) | 11 | 9 | 2 | Pure-background enrichment passed; Chinese case failed before its first state snapshot |

The per-run caps sum above 48 because unused capacity was reassigned only after earlier runs settled. The aggregate launcher guard used actual finalized authorization counts before allowing each new cap. The reports contain 11 recorded extraction dispatches across all runs. Two dispatched failed/paused attempts have unknown measured usage; reserved/charged budget accounting is not a measured provider bill. The final Chinese failure has no recorded extraction attempt and does not establish whether a conversation request reached transport.

The English correction has one black-tea current preference and a superseded green-tea predecessor. The replacement contains only the correcting source, and the immediate foreground check passed before extraction. Fresh context includes the successor only. Agent semantic review found the answer recommends black tea and mentions green tea only as past preference; the report's forbidden-keyword observation is not treated as failure. The successful second extraction reported 3,683 output tokens, including 3,673 reasoning tokens, exceeding the former 2,048 output allowance. This is evidence for the bounded allowance change, not a guarantee for other requests.

The final explicit-save case preserves one current black-shorthair-cat fact, both source statements and predecessor history through background extraction. A separate fresh session retrieves that current revision and answers with the supported name, breed and color, explicitly declining to invent age, personality or veterinary details. The final pure-background case reaches the same supported fact with `observedUser` authority, zero foreground remember invocations on both statements, two completed extraction attempts, both exact sources and superseded history. Fresh context contains only the successor; agent semantic review found the answer consistent with the saved fact.

The final Chinese case failed with `storage` after setup and before its first step snapshot. No terminal extraction job was captured. This does not identify which operation failed or establish a provider/database cause. The intermediate invalid-aspect-key failure and final unclassified failure both remain in the evidence; Chinese correction is **not qualified**. Follow-up [#43](https://github.com/alwynou/mira/issues/43) requires diagnosis and a separately bounded rerun. The evaluator now adds a static body-free failure-stage marker for future runs; instrumentation added after these live reports cannot reconstruct their missing stage.

This increment does not establish general memory precision/recall, retraction without a stable replacement or macOS 15 runtime acceptance.
