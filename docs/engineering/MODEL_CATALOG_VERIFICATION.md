# Provider catalog and purpose filtering verification

Date: 2026-09-06. Branch: `dev`. This increment responds to the missing DeepSeek/Kimi entries and the need to select models by use. The owning contract is [Model catalog](../architecture/MODEL_CATALOG.md); product behavior remains in [Agent and context](../product/AGENT_AND_CONTEXT.md).

## Delivered scope

Eight templates cover OpenAI, Anthropic, DeepSeek, Kimi / Moonshot China and international, SiliconFlow China and international, and OpenRouter, alongside the existing custom connection option. The bundled snapshot contains **542 model references**, not 542 verified working models. Manual IDs and explicit account model discovery remain available.

The reviewed models.dev input was retrieved at `2026-09-06T04:49:05Z`; its SHA-256 is `d918bb97da7705f6725ed038536d254bbc51ed37e2a20c9e412eaf302096d95e`. The generator stores this provenance, fixes credential destinations independently of upstream endpoint fields, excludes embedding dimensions from output budgets, and applies official DeepSeek/Kimi compatibility overrides. A regenerated normalized file compares byte-for-byte with the bundled resource. MIT attribution is included in the app's third-party notices.

Settings displays reference information and sources, prepopulates reviewable suggestions for new exact matches, and permits explicit manual overrides. Pool management retains incomplete models. Conversation, tool and memory-extraction eligibility checks exclude invalid configuration, incompatible tasks and unsupported reasoning. JSON extraction has an independent synthetic probe. Unsupported reasoning fields received from a peer terminate safely before a tool batch can execute.

Schema v9 directly replaces the development schema. Libraries at v8 or earlier are rejected intact; no migration or deletion was added. The earlier preview's schema-v8 library and process are not replaced by this increment.

## Parent acceptance

| Check | Evidence |
| --- | --- |
| Full package regression | Swift Testing reports **287 tests / 34 suites**, including one deliberately skipped opt-in M5 benchmark; ordinary tests passed. `/private/tmp/mira-model-catalog-tests.log` |
| macOS app and hostless tests | Debug app build and **16 Host tests** passed (5 localization XCTest cases, 11 renderer/Keychain Swift Testing cases). `/private/tmp/mira-model-catalog-host-accepted.log` |
| Catalog generator | **4 offline Python tests** passed, including tampered upstream destinations, embedding units, official thinking overrides and malformed metadata. Included in CI. |
| Localization | English source policy, **1,087 bilingual keys**, and compiler-extracted UI key coverage passed. |
| Snapshot reproducibility | Identical normalized output from the recorded source bytes and retrieval timestamp. |

Implementation revision `823e5113f8f10b88b6558723d86eb35a4867d70d` passed all clean macOS checks in [CI 34013769247](https://github.com/alwynou/mira/actions/runs/34013769247), including the new generator tests and compiler-extracted language coverage. The Debug app bundles the exact normalized catalog resource with eight providers and 542 references. The final evidence commit changes documentation only.

Tests cover capability-specific readiness, stale extraction, unsupported reasoning before credential access, unexpected reasoning response content, exact endpoint/model matching, frozen metadata, schema rejection, typed mirrors, and backup restoration with both enabled and disabled model selections under a disabled provider. A probe regression proves temporary request capabilities cannot certify unrelated capabilities or bypass the frozen-snapshot comparison.

Parent integration reviewed the delegated diffs and added source task exclusions, stricter endpoint paths, fixed template destinations, source provenance, JSON probes, restored-state coverage and English/Chinese display handling. Core remains Foundation-only and the Host never sends provider requests from a view.

## Remaining evidence

No real credentials or paid model calls were used. Public catalog download was the only new external metadata request. Live provider availability, actual billing, multi-step tool quality and real memory-extraction quality remain deferred. The current Kimi K3/K2.7 thinking continuation protocol remains unsupported; a catalog label cannot override that limitation.

Native provider setup clicks, live language switching and VoiceOver interaction were not verified in this increment. Hostless tests and compilation do not establish native interaction or macOS 15 runtime acceptance. The previous schema-v8 package and its CI evidence remain historical; this document does not relabel that package as schema v9. No public binary release is created.

## Updating the snapshot

Download the public `https://models.dev/api.json` into a temporary file. Record the actual UTC retrieval time and retain the input while reviewing the update. Then run:

```sh
python3 scripts/update_model_catalog.py --input /path/to/api.json --retrieved-at YYYY-MM-DDTHH:MM:SSZ
python3 -m unittest discover -s scripts/tests -v
swift test --package-path Packages/MiraKit
```

Review changed model tasks, units, unsupported protocols and the official thinking allowlists before committing the generated resource. New endpoint templates require separate verification of the official protocol and credential destination; an upstream API field cannot add one automatically. Catalog updates never rewrite saved model configurations or historical snapshots.
