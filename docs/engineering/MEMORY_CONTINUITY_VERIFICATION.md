# Bilingual memory continuity across process restart

Follow-up status: the [current issue verification](MEMORY_ISSUE_CLOSURE_VERIFICATION.md) completes the outstanding restart/citation checks and records closure of the historical correction issue as not reproduced under the user’s instruction. The outcomes and reports below are the unchanged earlier evidence.

Issue: [#52](https://github.com/alwynou/mira/issues/52). Baseline: `f4bf05a`, after the shared acknowledgment guidance in PR #51.

## Scope and evidence

This increment evaluates four authored synthetic flows: English/Chinese ordinary preferences through background extraction, and English/Chinese explicit saves through `memory.remember`. The follow-up opens a fresh session in a separate test process after the establishing process exits. It does not change production prompts, memory policy, provider adapters, schemas or UI.

The host requires an empty starting library and exactly one current source-bound revision. Ordinary replies must make zero foreground memory-write attempts; explicit saves require a successful invocation, matching committed receipt/result, and a subsequent reply round. Both wait for the actual production extraction job to finish, including the normal 120-second idle trigger. Foreground explicit-save material must remain unchanged through background extraction.

The establishing phase closes its library and returns before its `xcodebuild` process exits. The launcher waits for that exit before starting recall. The second phase checks a new test PID and process-instance UUID, the same library/run/scenario identity, exact original journal input and settled receipt, and the persisted frozen model route. It compares full memory, evidence, revision and replacement material, including bodies, source hashes and remote-use policy. Fresh-session recall must retain that material and include the exact original memory ID/revision in an actual model request. Citations using the app-owned bracket syntax are resolved by the production citation query; other visible reference formats require separate review.

The reports preserve synthetic source text, per-round visible output, final replies, settled tools/results, memory snapshots, extraction outcomes and per-attempt usage. They omit the API key, opaque thinking continuation and complete request/wire payloads. Chinese text in the corpus and evidence is an intentional synthetic language fixture exception. Reply and fact semantics are reviewed separately; a host `completed` status alone does not qualify the wording.

## Bounded execution

The task reserves eight credential authorizations for each of four cases, 32 overall. Establishment has a ceiling of six, leaving at least two for recall. The launcher reserves each phase before launch, retains unused or uncertain reservations after failure, refuses reused output directories, and has no retry loop or cross-case borrowing. Counts represent credential admission before transport, not provider bills or exact HTTP request counts. All libraries are disposable and contain synthetic data; the launcher removes only its own root after child exit. Personal libraries and Keychain are not accessed.

Configuration: DeepSeek `deepseek-flash`, `chat.completions` / `deepseek.chat`, provider-default thinking, production local Qwen embeddings, a 1,000,000-token context limit and an 8,192-token output ceiling. The shared `ConversationInstructions.default` is checked in each actual retained model request.

The first run exposed a launcher defect: Foundation serialized the owned directory under `/var`, while Python resolved the same directory under `/private/var`. All four establishment tests exited successfully, but the launcher's string comparison rejected their reports and deleted the disposable roots before recall. The [original process report](evidence/memory-continuity/initial/run-report.json), [ledger](evidence/memory-continuity/initial/budget-ledger.json) and all four raw establishment reports are retained unchanged. Its `totalUsed: 0` counts only launcher-accepted phases and must not be read as zero consumption: the final raw reports contain 12 authorizations (2, 4, 2, 4). The conservative old ledger held 24 authorizations until those reports were reviewed.

The correction compares canonical paths and adds a one-time explicit recovery import. It validates the completed old reports, carries all 12 actual authorizations into a new ledger, and starts fresh libraries because the old ones were deleted. Each ordinary case has six authorizations remaining and each explicit case four, still bounded by eight lifetime authorizations per case and 32 overall. Recovery establishment caps are five and three respectively, reserving at least one for recall; unused establishment allowance remains available to that case's recall. No report, original ledger, product prompt or provider setting is rewritten to hide the failure.

## Verification results

| Case | Initial authorizations | Recovery authorizations | Qualified result |
|---|---:|---:|---|
| English ordinary | 2 | 2 establish + 1 recall | Fact and process-restart continuity passed |
| Chinese ordinary | 2 | 2 establish + 1 recall | Fact and process-restart continuity passed; reference format limitation below |
| English explicit save | 4 | 3 establish; recall not run | Initial receipt/save/deduplication passed; restart continuity unqualified |
| Chinese explicit save | 4 | 3 establish; recall not run | Initial receipt/save/deduplication passed; restart continuity unqualified |

Total observed authorizations were **24/32**, with lifetime per-case counts 5, 5, 7 and 7. Each explicit case had only one authorization left after the recovery establishment; this was insufficient to finish both extraction and a new-session answer. No additional run was launched. All eight owned disposable roots were confirmed absent after the child processes exited.

Both [English](evidence/memory-continuity/recovery/en-automatic-writing-plan.recall.json) and [Chinese](evidence/memory-continuity/recovery/zh-writing-plan.recall.json) ordinary follow-ups correctly state the three-task writing-plan routine. Agent semantic review found the initial acknowledgments faithful and free of premature persistence or future-use claims, and the stored facts entailed by their source statements. Establishment and recall use distinct test PIDs/UUIDs and fresh session IDs. Full memory material, source execution and route match exactly across restart; the final request contains the same revision-1 memory reference. English used test PIDs 50100 → 51469; Chinese used 52495 → 53418. The [launcher process report](evidence/memory-continuity/recovery/run-report.json) retains successful exits for all four of these phases.

The Chinese follow-up displays a raw memory reference in fullwidth parentheses, not the app-owned `[memory:…@revision]` syntax. Its fact and context reference are correct, but `verifiedCitations` is empty and native citation formatting/resolution is **not qualified**. The English answer has no visible citation. These observations do not constitute native UI verification.

All four [initial establishment reports](evidence/memory-continuity/initial/run-report.json) have semantically sound acknowledgments and stored facts. For both explicit saves, `memory.search` precedes a successful `memory.remember`; the next visible reply acknowledges that matching committed result. The foreground memory remains unchanged through a completed extraction with zero additional accepted memories. The [English](evidence/memory-continuity/recovery/en-explicit-reading-room.establish.json) and [Chinese](evidence/memory-continuity/recovery/zh-explicit-meeting-time.establish.json) recovery attempts also saved successfully and acknowledged the correct committed fact. Their three foreground authorizations exhausted the recovery establishment cap, so background extraction paused with `credentialMissing` while the evaluator retained `request_authorization_cap_reached` at `background_extraction`. Neither recovery attempt reached recall. These failures remain visible; initial success cannot substitute for a complete restart flow.

Across the ten raw phase reports, 18 conversation attempts have complete usage and six extraction attempts completed. Two additional extraction attempts are marked dispatched/paused internally but were denied another credential authorization; their reserved-token charges are not observed provider billing. Deduplicated reported usage is 46,839 input / 2,063 output tokens for conversation and 11,763 input / 1,602 output tokens for completed extraction. Missing usage on the two paused attempts remains unknown.

The recovery launcher's historical summary uses `totalUsed: 18` for accepted/settled phases, `totalCommitted: 24` including held reservations, and `totalReserved: 36` for the sum of sequential phase caps. That last number is not concurrent allowance or consumption: unused establishment allowance is reused by recall. The raw reports establish the actual 24 authorizations. The final launcher now labels reported usage, settled usage, held allowance, accounted allowance and the sum of phase caps separately; an offline regression covers failed final reports so their observed usage cannot disappear behind zero accepted phases.

[#52](https://github.com/alwynou/mira/issues/52) remains open for both explicit-save restart flows and the noncanonical visible memory-reference format. No broad M3 or Q04–Q06 status changes.

Offline validation passed 28 selected host tests with three live entries skipped. After tightening context evidence to the final request, the 16 continuity-specific checks passed again with the live entry skipped. Both commands built the app. Eleven focused Python launcher checks passed, including alias paths, global/per-case budget exhaustion, imported historical usage, one-time recovery, distinct-process gating and retaining a root when child exit is unknown. The language policy passed with 2,245 bilingual strings, project generation remained consistent and whitespace checks passed. No unrelated package suite or native UI run was added locally.

The host commands selected `EverydayMemoryLiveTests`, `MemoryContinuityEvidenceTests`, `MemoryContinuityHandoffTests` and `MemoryContinuityLiveTests` from `MiraHostTests`. The launcher tests run with `python3 -m unittest discover -s scripts/tests -p test_memory_continuity_launcher.py`. Ordinary CI skips all live calls.

## Remaining limits

These are four authored examples from one model/configuration. They do not qualify broad M3 acceptance, independent Q04–Q06 quality, other providers, failed/refused/local-only live wording, native interaction, macOS 15 runtime behavior or interruption/crash recovery. This is an orderly process exit and restart. The historical unclassified storage failure in [#43](https://github.com/alwynou/mira/issues/43) remains separate and open.
