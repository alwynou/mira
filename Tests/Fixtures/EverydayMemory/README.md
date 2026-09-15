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

The opt-in live runner defaults to a shared ceiling of four provider dispatches, including background extraction and tool continuations. `MIRA_EVAL_DISPATCH_CAP` may explicitly set a value from 1 through 12. Select only the necessary cases; this cap is a cost guard, not a request to run the complete corpus.
