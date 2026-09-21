# Memory enrichment verification

Date: 2026-09-21
Issue: [#33](https://github.com/alwynou/mira/issues/33)
Branch: `codex/memory-enrichment`

## Problem and behavior

The isolated diagnostic attached to #33 reproduced three failure cases with fictional bicycle facts. Adding a nickname with a different or null aspect key created two current memories. Reusing the same aspect key skipped the new detail. Exact-text deduplication and explicit correction controls passed. The original memory was supplied directly to the extraction claim, so candidate retrieval was not the cause.

The extractor now distinguishes non-conflicting `enrichment` from `explicitReplacement` and `independent`. Enrichment names an exact existing memory or a strictly earlier output item and supplies the complete resulting assertion. The host checks target identity, revision, scope, kind, disclosure policy and validity, then atomically creates the complete current representation and supersedes the previous one. Enrichment inherits prior evidence and binds the input batch evidence, deduplicated by full source identity. Exact repeated output items are reused within a batch, including across different source turns. The existing 100-source evidence limit fails closed rather than dropping provenance.

Same, different and null aspect keys do not change an explicitly targeted enrichment. Similarity and aspect labels alone cannot authorize merging. The model remains responsible for identifying the same entity and distinguishing an addition from a contradiction. The earlier diagnostic's `independent` classification is intentionally replaced with the explicit enrichment contract; the host does not reinterpret arbitrary independent assertions through text heuristics.

No storage schema, native layout or design token changes are required. Existing stored memories are not bulk rewritten, and no development library is deleted. The additive extraction fields do not introduce an old-format decoder or migration adapter.

## Evidence

The focused package run passed 71 tests across seven suites (40 Data tests and 31 Core tests):

```sh
swift test --package-path Packages/MiraKit --filter 'MemoryEnrichmentTests|MemoryExtractionValidatorTests|MemoryExtractionWorkerTests|JournalMemoryExtractionCommitTests|JournalMemoryExtractionStoreTests|MemoryExtractionWorkflowTests|SQLiteMemoryPrivacyStoreTests'
```

Coverage includes same/different/null aspect keys, an earlier raw output target, exact duplicate and explicit correction controls, unchanged retry identities, current/history/recall results, inherited and new evidence, skipped targets, stale revisions, independent entities, scope/disclosure mismatch, and invalid target shapes/validity bounds. Injected relation-write failure and inherited-source suppression roll back the entire transaction. The forgetting domain test suppresses both source executions, purges the selected enriched memory and rejects replay without reviving its predecessor. It does not claim completion of journal-wide library maintenance.

`python3 scripts/check_language_policy.py` passed with 2,240 bilingual entries, and `git diff --check` passed. `xcodegen generate` regenerated the project. The existing `state-evolution.json` UI test resource was already in the checked-in project but missing from `project.yml`; its declaration now preserves that resource during regeneration.

The Debug app build passed with the repository's prescribed `xcodebuild` command and `.build/xcode` DerivedData path. The hostless `MiraHostTests` run passed all 109 Swift Testing tests and all five localization XCTest cases. Of 23 XCTest cases, two were skipped and one failed: `MiraWindowShellTests.testInspectorPreservesWindowSidebarAndPresentationState`, line 141, “The native divider must enter mouse tracking.” The isolated retry failed identically. A separate source archive of `origin/main` at `58e9fa8de73bfdf4f9d48d1f04cea4e9fc7b091b`, with separate DerivedData and package checkouts, reproduced that exact single-test failure (exit 65). No window-shell behavior was changed and no check was bypassed; required CI remains the merge gate.

Local evidence logs are `/tmp/mira-memory-enrichment-acceptance.log`, `/tmp/mira-memory-enrichment-app.log`, `/tmp/mira-memory-enrichment-host.log`, and `/tmp/mira-main-baseline-58e9fa8-window-shell-result.log`. The isolated baseline archive and build artifacts were removed after verification. These transient logs are not repository artifacts.

## Limits

All new tests use synthetic journal messages, isolated databases and model fixtures. They do not call a paid endpoint or read a personal library. Live-model classification quality and candidate discovery remain separate gates; this change does not claim universal semantic deduplication. Already duplicated current memories are not swept or retroactively consolidated.

Native visual acceptance and a live conversation walkthrough were not performed for this data/contract change. Local checks on macOS 27 do not establish macOS 15 runtime behavior; CI results must be reported separately.
