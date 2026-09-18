# Memory recall and local embedding correction

Date: 2026-09-18
Working branch: `codex/settings-session-analysis`

## Delivered behavior

Standard explicit memory saves now permit future model use within the existing scope and source permissions. Sensitive saves remain local-only. The memory module no longer requires fixed intent prefixes or adds a second approval prompt; exact source quotes, suppression, host policy, frozen route identity and transactional business authorization remain enforced. Deduplicating an existing local-only assertion does not widen its policy.

The current session-refactor tree now includes the local Qwen3-Embedding-0.6B 4-bit implementation originally developed in `08e2083`. MLX inference is host-owned; normalized 1,024-dimensional Float32 vectors and indexing jobs are derived SQLite records. Canonical memory and session schemas were not replaced. Missing vector projections can be recreated from the existing canonical records; no old-format decoder or schema bridge was added. This increment keeps the current background extraction configuration and does not port the separate extraction redesign from that branch.

Canonical mutations atomically invalidate vectors and queue indexing. Job commits check revision, content hash, index generation and model identity. The worker indexes while foreground work is idle and drains submitted inference on close. Export removes vectors only from its isolated snapshot; restored memories are reindexed. Forgotten and removed memories lose vectors and cannot be restored by a late job.

Real-model calibration exposed two issues in the earlier retrieval settings: the 0.5 floor excluded useful natural paraphrases, and broad lexical OR matches could override semantic rejection. The current floor is 0.4 for this pinned model; lexical supplementation with a ready model is restricted to a complete literal query or an unindexed fact. Unavailable local inference retains lexical fallback. This is a finite acceptance corpus, not general precision or latency certification.

## Evidence

- The original nickname-save/new-conversation workflow failed before the change with three issues: extra approval, denied save, and no persisted memory (`/tmp/mira-memory-recall-before.log`). The corrected workflow passes through the production journal/runtime/tool/business layers with synthetic model transport.
- Focused package checks: **52 test functions in 11 suites passed**, covering explicit-save receipts, standard/sensitive disclosure, deduplication, source suppression, source workspace restrictions, vector ranking, background indexing, stale jobs, cancellation/close, privacy cleanup, export and restore (`/tmp/mira-memory-fix-package-final.log`). Parameterized cases are reported inside those function counts.
- The archive test had stale expectations for an unsettled model stream. They were aligned with the existing session contract: an interrupted attempt with no settled output has no fabricated assistant body. The test now also proves that live vectors survive export, exported vectors are absent, and restored records queue reindexing.
- Real Qwen GPU acceptance: **20 synthetic memories, 39 queries**; **28/29 positive queries found an expected memory**, **10/10 unrelated queries returned no memory**, and **14 expected hits were absent from the production lexical baseline**. The baseline is a second request-scoped `recallMemories` store with embeddings disabled, not a whole-query substring search. Detailed fixtures and the retained miss are described in [semantic fixtures](MEMORY_SEMANTIC_FIXTURES.md).
- Full `MiraHostTests`: **103 Swift Testing functions in 16 suites passed with one explicitly recorded known model issue**; XCTest executed **21 cases, one credential-gated case skipped, zero failures** (`/tmp/mira-memory-host-final.log`). The hardware suite was enabled with `TEST_RUNNER_MIRA_TEST_EMBEDDING_MODEL_DIRECTORY`; it was not a skipped or fake-vector run.
- Focused composition checks: **17 tests in three suites passed**, covering execution/reopen, library lifecycle and memory editing (`/tmp/mira-memory-composition-final.log`). The final worker lifecycle checks passed all three tests (`/tmp/mira-memory-worker-final.log`).
- Main Debug app build passed (`/tmp/mira-memory-app-build.log`). Language policy passed with **2,105 bilingual strings**; `git diff --check` passed.

## Existing development library and native smoke test

The app was stopped and the single affected standard nickname memory was revised through `MemoryApplication.reviseMemory`, including the expected revision and normal library lease. Only its remote-use policy and revision changed; its content, identity and evidence were verified unchanged. Other memory permissions were not bulk-updated. The shared model files, provider configuration, credentials and existing conversations were retained.

After rebuilding and opening the app, the index worker generated the current revision's 4,096-byte vector and drained its queue. A new conversation in the native app correctly recalled the nickname from the first short question. Its journal records the revised memory as request context, establishing that the answer used the saved memory rather than prior messages in that conversation. This was one live configured-provider smoke request; the larger quality corpus used only synthetic data and local embedding inference.

No layout was changed. This smoke test does not establish a full light/dark/localization/minimum-window visual matrix, macOS 15 runtime acceptance, large-library latency, or general model recall quality.
