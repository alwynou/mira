# Canonical session log integration onto main

Date: 2026-09-18

## Integration boundary

Local `main` was fast-forwarded to `origin/main` at `ae68f7a3c65b56282e2dee50bfa8602386c92b55` before integrating `codex/settings-session-analysis` (`f6defeb3f402dc28e3ea5d4ec5862a4fbb639b07`). The merge tree starts from that main revision and selects the feature branch's canonical session-log implementation and its required callers. A fresh fetch before publication confirmed the same remote baseline.

The log now uses DSH v3 shared records, inline immutable content, atomic physical frames, settled stream records, and journal-derived continuation. Sidecars, persisted active drafts, request/replay manifests, and session erasure plans are removed. Tool provenance and ordered settlement retain main's behavior; tool failure details use the new log field.

Main remains authoritative for memory ranking/thresholds, embedding service and model, automatic extraction batching, output controls, historical task authorization, and settings. The branch's additional memory-search tuning and provider-settings fix are excluded. Changes in memory/knowledge/archive callers adapt the canonical source identity and removal of session erasure only.

Extraction selects the last completed batch turn. It derives the original instructions, tools, current-turn context and user message from the journal; the extraction appendix still covers every batch source. The format does not retain exact historical full-message arrays or HTTP requests, so cache-prefix identity beyond the stable system/tool prefix is not guaranteed. The owning extraction contract documents this limit.

`AGENTS.md` now requires fetching the relevant remote and fast-forwarding the local baseline before switching or creating branches, while preserving unrelated work.

## Acceptance evidence

- Focused package integration: **776 tests in 116 suites passed**. Selection covers agent/session boundaries, memory, knowledge privacy, task tools, business receipts, archive/restoration and provider request controls. `/tmp/mira-main-log-package-final.log`.
- Added last-batch-turn/scope regression: journal reader suite **8 tests passed** (overlaps the package run; not an additional eight unique tests). `/tmp/mira-main-log-reader-final.log`.
- `MiraHostTests` scheme: **109 platform Swift Testing cases**, **171 composition Swift Testing cases**, **21 platform XCTest cases with one credential-gated case skipped**, and **5 composition XCTest cases**, no failures. `/tmp/mira-main-log-host-final.log`.
- Opt-in native model suite: **3 tests passed**, using existing verified Qwen3 0.6B 4-bit weights. It checks semantic paraphrases, unrelated-query rejection, normalized 1,024-dimensional vectors, service closure, and automatic four-turn extraction into the native index. No paid provider or real conversation data was used. `/tmp/mira-main-log-native-memory-final.log`.
- The first native run hit SQLite busy in its separate test observer while the background worker committed. The observer now has a bounded five-second busy timeout; the production store is unchanged. All three native cases passed on rerun.
- Debug application build passed. `/tmp/mira-main-log-app-final.log`.
- Language policy passed with **2,163 bilingual entries**; whitespace and local Markdown link checks passed.

One capability-only session-search test exhausted its 200 ms deadline during an earlier heavily concurrent run. It passed in isolation and in the final 776-test run; no search algorithm or deadline was changed.

## Development runtime and native inspection

The stopped development library at `~/Library/Application Support/Mira` was deleted and recreated at the same path under the repository's standing development-data authorization. Its old conversations, memory records, and provider/model configuration were cleared. Shared model weights and Keychain credentials were preserved. The reopened application created the current extraction schema and an empty memory table.

Native accessibility inspection confirmed the new empty-library conversation and main's automatic-memory/current-conversation-model controls. A native screenshot confirmed the Simplified Chinese dark memory-settings screen and Qwen3 0.6B 4-bit label. Light appearance, English, minimum-size and the complete native inspector/interaction matrix were not rerun; passing builds and host tests do not substitute for that matrix. This run was on the current macOS host, not a macOS 15 runtime test.
