# Ordinary capture and stable-prefix verification

Date: 2026-09-06–07 (Asia/Shanghai)

## Scope and diagnosis

The inspected development library had `manualOnly` capture, no extraction jobs, and only a conversation-purpose binding. The configured model already had verified JSON extraction capability. Ordinary preference statements therefore never reached background extraction. The automatic-active classifier also recognized too few routine phrasings and unnecessarily depended on the extractor preserving verbatim content without telling it to do so.

OpenAI-compatible transport already placed system/developer instructions at message index zero; Anthropic already used its dedicated system field. The inspector showed alphabetically sorted canonical JSON, which made `messages` appear before `system`. Separately, prefetched memories were appended to the system string and changed the effective history prefix.

A new application regression also exposed a Chinese recall gap: a two-character topic inside an ordinary longer request could not match the trigram-only prefetch path.

## Changes

- Recognize reviewed, bounded first-person routine preference grammar and instruct the extractor to preserve self-contained direct statements verbatim. When every direct-active gate passes, store the full exact user quote instead of model paraphrases. Full-source evidence, policy, confidence, stability, subject, sensitivity, and conflict checks remain authoritative. Questions, reported/third-person wording, mixed instructions, and unsupported facts still require review.
- Supplement lexical recall with native local Chinese word segmentation. Two-character words use escaped substring matching under the same scope and disclosure filters; explicit short keyword searches remain available. FTS-only ranking remains BM25, while supplemented queries use stable ID order.
- Keep stable system instructions and pinned workspace background ahead of durable history. Put retrieved memory in a distinct untrusted `context` message before the current user message. Freeze it during tool continuations and keep it out of durable history.
- Prevent ordinary statements from opening manual memory approval when automatic capture is enabled; mistaken manual tool calls receive a denial and the reply can finish before background extraction. Explicit save requests keep their reviewed path.
- Display system instructions first in request inspection, ordered messages next, and canonical JSON separately. Show capture mode and actionable capture-off guidance even with no extraction jobs.

## Deterministic evidence

- `swift test --package-path Packages/MiraKit --disable-automatic-resolution`: **340 tests passed in 37 suites**.
- `xcodebuild ... test` using the documented pinned packages and `.build/xcode`: **passed**, with 5 XCTest cases and 59 Swift Testing cases (**64 host tests**), and a successful Debug application build.
- Source and compiler-extracted localization policy checks: **1,193 bilingual strings passed**.
- `git diff --check`: passed.

Tests cover ordinary Chinese habit capture through the actual application/SQLite/background worker flow, active state without a remember command, new-conversation prefetch without a search command, unrelated queries, candidate/private/forgotten/wrong-scope exclusions, short keyword search, immutable system/history prefixes across changing memory, complete tool continuation, and OpenAI system/developer plus Anthropic request shapes. Duplicate or misplaced context and invalid reasoning/tool payloads fail before credential access; invalid context also fails atomically before an attempt is persisted. Existing cancellation, suppression, retry, restore, and privacy suites remain green.

The host build retains existing scroll-test concurrency warnings and harmless App Intents metadata warnings. This task does not change the paused streaming renderer or scrolling behavior.

## Native follow-up

The existing Computer Use session failed to start ScreenCaptureKit capture, so the walkthrough used the user's previously authorized AppleScript/macOS accessibility fallback, with native window screenshots and read-only metadata corroboration. All content remained in the configured local development library; no credentials or raw conversation/audit payloads are included in this report.

The first two attended passes exposed additional real-model behavior: a manual remember call interrupted ordinary capture, a third-person rewrite triggered review, and source-recording time was mistaken for a validity boundary. The final code immediately denies inappropriate manual save calls under automatic capture, stores exact direct user evidence instead of rewrites, and explicitly distinguishes provenance time from user-stated validity in the extraction schema and instructions.

In the attended Debug walkthrough with the final extraction behavior, the existing DeepSeek model completed the ordinary preference reply and its separate extraction without any tool calls or approval interaction. The resulting memory was active, remote-eligible under the enabled policy, and preserved the exact source wording. A separate conversation asking for breakfast advice naturally received that preference, recommended the relevant breakfast, and cited its exact revision. Its canonical sequence was `[context, user]`, with one memory reference and no preference body in `system`; no memory-search instruction or tool call was needed. The advice request's extraction also completed without an extra saved fact.

The library now has an explicit global `memoryExtraction` binding to its configured model and `automaticWithUndo` enabled. The daily extraction token limit is 20,000; with the existing 8,192-token model output setting, final request reservations were about 11,200, above the original 10,000 default. No history was backfilled. Initial setup still defaults to manual-only for new libraries, and existing model thinking settings were preserved.

All 340 package tests, 64 host tests, the Debug application build, and both localization checks passed after the final validity-instruction and context-shape corrections. The two duplicate review candidates from failed attended passes were removed through the native UI; the successfully activated preference and historical conversations were retained.

## Limits

This is a bounded preference-capture and single-model smoke test, not general memory-quality acceptance. Arbitrary multi-clause or partial-quote statements, inference, sensitive facts, and the broad same-category conflict barrier can still produce review candidates. Short-word recall is lexical, not semantic embedding search; word segmentation can differ by macOS runtime. No cache-hit rate improvement is claimed solely from request ordering. macOS 15 runtime, broader provider quality, and distribution acceptance remain open.
