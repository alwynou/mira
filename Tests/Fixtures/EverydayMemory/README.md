# Everyday Memory Scenarios

This fixture contains 32 authored synthetic everyday conversation scenarios for testing memory extraction and follow-up behavior from an empty library. It has 16 `zh-CN` scenarios and 16 `en` scenarios. Each language has 8 `active` cases and 8 `notActive` cases, for 16 cases in each expectation group overall.

The scenarios are ordinary user statements followed by a natural question in a fresh conversation. They deliberately do not instruct the assistant to remember, save, retrieve, or search anything. The active cases describe clear, low-risk, reusable preferences or routines. The non-active cases cover temporary circumstances, third-party facts, hypothetical plans, questions, sensitive information, and corrections where an old fact cannot be resolved into a durable replacement. Correction cases are self-contained and should be treated as non-active or review material when the prior fact is unavailable.

The corpus is intended to test memory behavior independently of the current lexical rules. It includes meal and drink preferences, communication style, work habits, exercise, travel, and reading. Statements, follow-ups, and keywords are synthetic; they contain no real conversation history, personal sensitive data, or provider settings.

## Schema

The top-level JSON object has exactly these fields:

```json
{
  "version": 1,
  "hostAnnotations": {
    "stable-kebab-id": {
      "assertionMode": "directStable",
      "aspectKey": "meal.breakfast",
      "changeIntent": "independent"
    }
  },
  "scenarios": [
    {
      "id": "stable-kebab-id",
      "language": "zh-CN" | "en",
      "category": "preference" | "routine" | "temporary" | "thirdParty" | "hypothetical" | "question" | "sensitive" | "correction",
      "statement": "natural user sentence",
      "followUp": "natural question in a fresh conversation without telling it to recall memory",
      "expectation": "active" | "notActive",
      "rationale": "English explanation of why this is or is not safe to auto-activate",
      "requiredTerms": ["content keywords only; empty allowed for notActive"],
      "forbiddenTerms": ["unwanted fact keywords; empty allowed"]
    }
  ]
}
```

`hostAnnotations` is a test-only annotation for the deterministic host gate. It records the expected structured extraction classification for positive cases; production code never reads this map. Negative cases intentionally omit it. The host test supplies a valid `unannotated.preference` key when the map has no entry, so those cases still receive structurally valid direct/standard proposals and cannot pass merely because missing metadata forced review.

`requiredTerms` contains only content keywords that support the expected active fact; it is empty for every `notActive` case. `forbiddenTerms` identifies an unwanted fact or inference that should not be surfaced. Terms are not intended to prescribe a response or encode an extraction prompt.

## Review status

The active and non-active labels are AI-authored provisional annotations. A human review is required before this fixture can qualify for the Q04 quality gate. This is a behavior-oriented test corpus, not a representative human-labeled benchmark, and its results must not be presented as population-level memory quality.

The Chinese statements and keywords are an intentional Unicode test-fixture exception to the repository's English engineering-source policy. The exception is limited to this synthetic `zh-CN` corpus so that Chinese extraction and retrieval can be tested; all fixture schema, rationale, and operating notes remain in English.

## Validation

Validate the file without model endpoints:

```sh
python3 - <<'PY'
import json
from pathlib import Path

path = Path("Tests/Fixtures/EverydayMemory/scenarios.json")
data = json.loads(path.read_text())
scenarios = data["scenarios"]
assert data["version"] == 1
assert len(scenarios) == 32
assert len({item["id"] for item in scenarios}) == 32
assert sum(item["language"] == "zh-CN" for item in scenarios) == 16
assert sum(item["language"] == "en" for item in scenarios) == 16
assert sum(item["expectation"] == "active" for item in scenarios) == 16
assert sum(item["expectation"] == "notActive" for item in scenarios) == 16
assert all(not item["requiredTerms"] for item in scenarios if item["expectation"] == "notActive")
print("validated 32 scenarios: 16 zh-CN / 16 en; 16 active / 16 notActive")
PY
```

Corpus validation is offline. Real-provider execution is owned by the explicitly enabled, bounded evaluator described in [the testing workflow](../../../docs/engineering/EVERYDAY_MEMORY_TESTING.md); ordinary CI never calls model endpoints.

The opt-in ordinary live runner defaults to a bounded provider request-authorization ceiling. `MIRA_EVAL_REQUEST_AUTHORIZATION_CAP` may explicitly set a value from 1 through 12. Select only the necessary cases; this cap is a cost guard, not a request to run the complete corpus.

State-evolution execution is separately gated by `MIRA_RUN_LIVE_MEMORY_STATE_EVAL=1` and uses the same provider configuration variables and case-ID selection. It accepts one to eight explicit state case IDs and a separate authorization cap from 1 through 64. The ordinary empty-library evaluator keeps its existing one-to-four case and 1-to-12 cap. Reports are written incrementally to the new `MIRA_EVAL_REPORT` path. Ordinary CI validates the corpus and compiles the runner but skips provider execution.


## State-evolution corpus

`state-evolution.json` complements the empty-library scenarios with multi-step synthetic cases. It retains explicit replacement, retraction without a stable replacement, forget/reopen, and related-but-unsupported recall, and adds same-entity non-conflicting enrichment through automatic capture and explicit `memory.remember`. Automatic cases wait for the production idle trigger (up to four minutes); one completed turn does not imply immediate background extraction. Foreground cases require a successful production `memory.remember` invocation and inspect context before an idle extraction can begin.

The six `retractionNearMiss` cases cover quoted dialogue, hypothetical changes and uncertain intent in both languages, with exactly `establish` then `preserve`. They require a real current baseline, no memory-write attempts, unchanged assertion/evidence/history through foreground processing, background extraction and reopen, and the same current reference in fresh-session context. A translation-task quotation is not the same as a user retracting an earlier statement by correcting its provenance. These are authored provisional labels, not keyword-based production permissions or independently qualified semantic judgments.

A state-evolution runner executes natural-language steps through the same production conversation and extraction path used by `EverydayMemoryLiveTests`. The special `forget` step is a harness action rather than model input: resolve the established memory and submit the production `memory.forget` `AgentLibraryMaintenanceRequest`, then close and reopen the temporary library before the follow-up. This prevents an evaluator from accidentally testing a conversational request to forget instead of Mira's actual privacy boundary.

The state report distinguishes deterministic host/state checks from answer keyword observations. It records execution and extraction outcomes, memory IDs/revisions/effective lifecycle/body, exact source references and relations, the precise memory references included in model context, visible citations and production citation verification, plus the request-authorization cap and count. Answer keyword checks are heuristic observations for human review; they are not semantic correctness judgments. The report identifies the embedding mode. Offline runs remain lexical-only. Explicit `MIRA_EVAL_EMBEDDINGS=local` runs wait for the production local model to become ready and preserve its normal indexing behavior. Foreground cases retain immediate tool snapshots and also wait for extraction afterward to detect later duplicates.

Completed step replies are bound to the exact session and execution, never selected from another turn by page order. If a failure prevents the normal snapshot, available execution audit and partial usage are retained separately without replacing the primary safe failure. Unavailable evidence is distinct from an observed empty result; per-attempt completeness and truncated audit pages remain explicit. Deduplicate usage by attempt identity when combining normal and failure snapshots.

The ordinary and state-evolution runners use the same `ConversationInstructions.default` as the macOS conversation host. New state reports record that exact guidance; historical reports retain their original instructions. When reviewing a reply, distinguish understanding in the current conversation from a claim of durable storage or guaranteed future recall. A later successful background extraction does not retroactively justify a premature saved-memory claim in the earlier reply. The matching foreground tool result is the evidence for a new explicit save; attempted calls, older replies and unrelated receipts are insufficient. Review wording in its language and context rather than making keywords a semantic pass/fail gate.

The corpus validator rejects duplicate or malformed IDs, unsupported kinds and step expectations, missing required sequence structure, empty text, and unknown selected IDs. Offline XCTest cases also exercise duplicate final representations, missing lineage/details, forgotten-memory context leakage, and effective lifecycle states that raw `state == active` would misclassify.

## Cross-process continuity corpus

`continuity.json` contains exactly four authored synthetic cases: `en` and `zh-CN`, each with an ordinary preference and an explicit save request. Ordinary inputs have no save instruction. Explicit inputs intentionally request `memory.remember`. The Chinese inputs and questions are a narrowly scoped Unicode fixture exception; schema and operating instructions remain English. These four labels are provisional examples, not an independent quality benchmark.

The opt-in `MemoryContinuityLiveTests` entry runs either establishment or recall. Establishment requires an empty library, exact source-bound memory state and completed production extraction. An explicit save also requires the matching successful receipt/result and a later model reply. Recall runs only after the establishing process exits, in a new XCTest process with the same disposable library and a fresh session. It compares full memory, evidence, revision and replacement material; the original source execution and receipt; persisted provider route; and the actual fresh-session context reference. Visible citations are verified through the production query.

The launcher in `scripts/run_memory_continuity.py` reserves eight credential authorizations per case across both phases, with a six-authorization establishment ceiling and 32 overall. It preserves failure reports and process exit evidence, refuses output-directory reuse, and does not automatically retry or borrow another case's allocation. An explicit one-time launcher recovery imports prior actual counts before allocating the remainder; it cannot reset the task budget. Model reply and stored-fact semantics require separate review. See the [testing workflow](../../../docs/engineering/EVERYDAY_MEMORY_TESTING.md) for invocation and limits.
