# Local memory production integration

Date: 2026-09-16
Branch: `codex/memory-embedding-prototype`
Host: Apple M1 Pro, 16 GiB, macOS 26.6.2, Xcode 26.6 / Swift 6.3.3.

## Delivered behavior

- Production macOS MLX adapter loads `mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ` at revision `6c3ae70858513f1a78e9cdca3cae330d9075cd2a`. Eight pinned artifacts are size/hash checked before publication. Weights are 4-bit; stored embeddings are normalized 1,024-dimensional Float32 values. BF16 remains a development reference.
- Shared model installation lives outside any library at `~/Library/Application Support/MiraModels/qwen3-embedding-0.6b-4bit`. Core uses a Foundation-only embedding port. Queries never download or load a model; idle library work prepares it and indexes one assertion per GPU dispatch. Restart also loads an existing index with no pending jobs. Queries have queue priority; close/cancellation drains submitted GPU work. Memory-pressure events pause admission and unload; preparation failures have a five-minute retry delay.
- Canonical writes atomically invalidate old vectors and enqueue revision/hash/generation-bound indexing. Completion rejects stale results. Retrieval filters scope, source-workspace permissions, lifecycle, validity, connection and disclosure before top-K, then revalidates actual context/tool sources. Semantic results lead; one distinct lexical result may occupy a reserved slot. A profile contains at most two current communication/language preferences within the six-item total.
- Standard explicit saves are recallable in their permitted scope; sensitive saves stay local. No extra memory-specific approval is requested. Replies do not require visible citations. Internal journal/revision lineage and optional historical citation validation remain.
- Ordinary completed turns enter a durable queue in the consumer checkpoint transaction. Thresholds are four turns, approximately 2,000 user-input tokens, 120 seconds since the last completion or 600 seconds since the oldest completion. A batch is bounded to 16 turns and approximately 8,192 user-input tokens. There is no per-turn model triage request. Full prepared-request/output budget ceilings apply separately.
- V3 extraction uses model paraphrases and host-owned `inputIndex` lineage. Eligible direct, stable, high-confidence standard assertions become active. Other classifications and ambiguous conflicts are skipped without a candidate inbox. Clear corrections can reference bounded prior memories with revision checks. New assertions retain conservative whole-batch lineage. Batch status is visible from each participating execution.
- Capture is always automatic and uses the batch’s last completed conversation route. There is no dedicated extraction purpose, enablement timestamp or mode selection. Budget reservation, revocation checks and uncertain-dispatch protection remain. Removed modes and request shapes have no decoder bridges. Existing explicit editing/forgetting services remain; the previously removed management screens and new chat correction/forget tools are outside this increment.
- Export strips derived vector rows from an isolated database snapshot and vacuums it; live vectors remain intact. Restore queues canonical memories for reindexing and clears pending automatic-capture inputs. Privacy cleanup removes vectors, queued writes and extraction bodies dependent on forgotten sources/prior memories.

## Initial 4-bit integration verification

| Check | Result | Local evidence |
| --- | --- | --- |
| Package memory, archive, restoration and policy suites | 131 tests / 26 suites passed | `/tmp/mira-memory-acceptance.log` |
| Real pinned-model installer/runtime | 5 tests passed, including actual GPU inference and directory replacement | `/tmp/mira-memory-native-acceptance.log` |
| Native settings/read-model suites | 12 tests passed | same log |
| Authored v3 policy fixture + offline evaluation setup | 2 XCTest cases passed | same log |
| Main Debug application build | Passed | `/tmp/mira-memory-app-final.log` |
| Language policy | 2,082 bilingual strings passed | `/tmp/mira-memory-language.log` |
| Broad native run | Swift Testing: 109 host + 173 composition tests passed; one existing window-animation XCTest failed | `/tmp/mira-memory-host-final.log` |

The window failure requires at least three distinct title positions during sidebar animation but observed only the endpoints. A focused rerun also failed on expansion (`/tmp/mira-memory-host-recheck.log`). No window-shell implementation was changed here; this failure remains open and is not counted as a passing host suite.

Package command:

```sh
swift test --package-path Packages/MiraKit --filter 'Memory|SQLiteLibraryRestorerTests|SQLiteLibraryArchiveTests|AgentToolPolicyComposition'
```

For the native hardware tests, prefix the xcodebuild invocation with `TEST_RUNNER_MIRA_TEST_EMBEDDING_MODEL_DIRECTORY=<verified model directory>`. The `TEST_RUNNER_` prefix is required for Xcode to forward the variable. Without it, the hardware-only tests are explicitly disabled; an ordinary skipped run is not real-model evidence. Other host/composition fixtures explicitly inject an offline embedding service and never download models.

Coverage includes coalescing and checkpoint rollback/rebuild, completion-based idle timing, multi-fact model paraphrases, all-turn provenance, no extra approval, manual-fact correction and stale-revision rejection, wrong scope, source suppression, foreground/worker cancellation, disclosure, semantic paraphrases, model-generation changes, late index writes, malformed vectors, restart with an already-built index, full forget workflows, archive omission and reindexing.

## Native UI and development library

The freshly built app opened the recreated development library at its original `~/Library/Application Support/Mira` path. The old identified development runtime files were removed under the standing repository authorization; no backup or compatibility library was retained. Keychain was not accessed or deleted. Connection configuration must be recreated in the new library; the follow-up below removes separate extraction-purpose setup.

The following UI observations predate the always-automatic follow-up. The verified eight model files were installed from the already-validated prototype download; production code has no prototype-directory fallback. Clicking **Prepare local model** in the running app changed the status to **Ready for semantic search**. CUA screenshots/accessibility observations verified English and Simplified Chinese in light and dark appearance at 840 × 720, manual and automatic draft modes, the missing extraction-route prompt, ready model status, and discard behavior. Temporary language/appearance changes were restored and the unsaved capture-mode draft was discarded.

The native 760 × 560 minimum-size check remains unverified: two CUA drag attempts, including after raising the window, returned `noWindowsAvailable`. No minimum-size screenshot is claimed. Installing/error states were verified structurally and by adapter tests, not through a full visual matrix. No shared design token changed.

## Remaining acceptance

- No paid DeepSeek extraction/answer evaluation ran in this increment. Structural checks trust semantic classification fields; they cannot prove that a model classified hypothetical, quoted or third-party content correctly. The authored v3 host fixture tests labeled policy behavior, not semantic safety or Q04 quality.
- Existing-memory reconciliation supplies at most 32 current eligible facts (8 KiB content budget); it is not exhaustive semantic deduplication. Assistant context is omitted when its reply has auxiliary sources. No episode fallback was added.
- Production end-to-end p95 context latency, 10,000-fact SQL/vector quality, calibrated no-answer behavior, energy, real memory-pressure/UI interaction and macOS 15 runtime are not established by the prototype or these integration tests. Q04/Q05/Q06 remain open where applicable.
- The memory manager remains intentionally unavailable pending its separate design. This work does not claim to complete all M3 user-facing correction/forget workflows or release acceptance.

## Always-automatic conversation model follow-up

The user requested one automatic behavior with the conversation model and maximum practical reuse of cached prefixes. The worker now reads the actual frozen route and foreground request from the batch’s last completed journal execution. It never selects a separate purpose or silently uses a newly changed global default. JSON output uses a prompt plus host validation; a separate JSON-capable model is unnecessary.

Original system instructions and tool definitions are retained. The extraction instruction, schema and target batch are appended as the final user message. Foreground messages are copied unchanged only within a 16 KiB bound and when every source is already tracked by the extraction batch or its validated prior memories. Otherwise the stable system/tool prefix is retained with the compact batch. If the optional history exceeds a context/request/daily budget during pure preparation, it is dropped once before any network dispatch. There is no alternative-model fallback. This bounded design deliberately avoids resending arbitrary full history to chase cache hits.

Providers receive `tool_choice: none` (or the Anthropic equivalent), and streams reject tool calls despite retained definitions. The request output ceiling starts at 2,048 tokens, bounded by the original route; the adapter raises it where needed for a legal explicit Anthropic thinking budget. Thinking remains enabled according to the conversation configuration. Reservation counts encoded wire bytes and the effective output ceiling, avoiding duplicate accounting for the internal semantic snapshot. Reported cache reads remain visible in usage/cost accounting; cached input still counts toward the daily token budget.

Evidence:

- Package memory/archive/policy/model/provider acceptance: **173 tests in 29 suites passed**, `/tmp/mira-always-auto-package.log`.
- After strengthening exact serialized DeepSeek message-prefix equality: **20 focused tests in two suites passed**, `/tmp/mira-auto-prefix-final.log`.
- The four-turn production workflow verifies identical foreground instructions/tools/message prefix, no separate route selection, actual multi-fact commit and cancellation after budget-policy revision. Worker tests cover optional-prefix refitting before a single network dispatch.
- Provider fixtures verify the exact repeated DeepSeek message prefix and unchanged tool definitions/model/thinking settings, prohibited tool responses, Responses controls, and Anthropic output 4,097 for a 4,096-token thinking budget.
- No paid request or live DeepSeek cache-hit measurement ran. Prefix equivalence is tested locally; actual cache hits and billing savings are not claimed. [DeepSeek’s cache documentation](https://api-docs.deepseek.com/guides/kv_cache/) describes matching and best-effort behavior.

The old empty development app was stopped and its identified library recreated at the same path for the new request/policy shape. The shared model directory and Keychain were left intact.

Final native acceptance for this follow-up:

- Focused settings/purpose/session suites: 17 Swift Testing cases plus two offline XCTest cases passed (`/tmp/mira-memory-settings-native.log`).
- Entire `MiraHostTests` target: 109 Swift Testing cases passed; XCTest executed 21 with one credential-gated live case skipped and no failures (`/tmp/mira-auto-host-tests.log`). The previously intermittent window-animation test passed in this run; no window-shell implementation was changed and this is not evidence of a timing fix. Hardware embedding cases were disabled without the explicit model-directory environment variable; the earlier real-model run remains the hardware evidence.
- Main Debug application build passed (`/tmp/mira-auto-app-build.log`); language policy passed with 2,097 bilingual strings; `git diff --check` passed.
- The new application’s memory settings were inspected through native screenshots in English and Simplified Chinese, light and dark, at 840 × 720. No capture-mode selector or extraction-route setup appears. The Models page shows only the conversation route. Language and appearance were restored to Simplified Chinese / Follow System. No daily budget or provider credential was changed.
- A minimum-size drag again failed with CUA `noWindowsAvailable` after raising Settings. The 760 × 560 check remains unverified; no minimum-size screenshot is claimed.


## Daily quota removal follow-up

A user-observed four-turn run reached the automatic extraction threshold but failed before dispatch because the default 10,000-token daily quota was compared with a conservative byte-based request ceiling. No extraction request was sent and no memory or vector was created by that run. This exposed a gap in the earlier synthetic acceptance.

At the user's request, extraction now has no configurable daily token quota or aggregate spending gate. The policy model/store, policy-revision gating, daily balance API, related persisted fields and settings controls are removed directly. The worker still validates the frozen model's context/output limits, bounds batches, reuses eligible prefixes, disables tools during extraction, and validates sources before dispatch and commit. Per-attempt conservative estimates remain accounting metadata; reported provider input/output/cache counters remain the authority for actual usage and cost estimates. Prefix construction is not proof of a live provider cache hit.

The settings page contains the automatic-capture explanation and local embedding status/preparation. It has no quota input, remaining counter, or Save/Discard controls. The component preview and native UI test expectations follow the same behavior.

Verification results for this follow-up:

- Package memory, archive and restoration checks passed: **126 tests in 25 suites**, `/tmp/mira-no-quota-package-final.log`. Repeated requests with estimates above the former quota now prepare successfully; aggregate same-day estimates do not block extraction. Model context limits, connection revocation before dispatch, revocation during streaming, source validation and rollback remain covered.
- A synthetic four-completed-turn workflow using the production extraction worker and real pinned MLX model passed. Its extraction request estimate exceeded 10,000 tokens, and it persisted **one active memory and one normalized 1,024-dimensional Float32 vector**. The provider response was a local fixture; embedding ran on the GPU. This is not a paid-provider extraction-quality or cache-hit measurement.
- The native run passed: **110 Swift Testing cases in 17 host suites**, **21 XCTest cases with one credential-gated case skipped and no failures**, and **10 targeted composition cases**. Evidence: `/tmp/mira-no-quota-host.log`. Real-model checks were enabled through `TEST_RUNNER_MIRA_TEST_EMBEDDING_MODEL_DIRECTORY`. The window-animation case passed; no window-shell change is claimed.
- Main Debug application build passed (`/tmp/mira-no-quota-app.log`), and Mira was restarted. Screenshot inspection identified the missing `Extraction model` translation, which was restored. The final language check passed with **2,094 bilingual entries**; an incremental build to package that translation passed (`/tmp/mira-no-quota-label-build.log`) and the application was restarted. Tests were not repeated for that catalog-only correction. `git diff --check` passed. No new target or file registration was needed.
- A native Simplified Chinese/light screenshot confirmed the automatic explanation, local embedding preparation control and absence of quota/remaining/Save/Discard controls. CUA capture failed with ScreenCaptureKit error -3811; the screenshot skill fallback succeeded. Local screenshots: `/var/folders/hd/vw9cr2s54879tqf2kphbkzlw0000gn/T/codex-shot-2026-09-16_16-02-49-w4392.png` (empty-library conversation) and `/var/folders/hd/vw9cr2s54879tqf2kphbkzlw0000gn/T/codex-shot-2026-09-16_16-02-49-w4403.png` (memory settings, before the label correction). English/dark/minimum-size and unrelated UI flows were not rerun for this follow-up. Updated UI automation assertions were not executed.

For the schema removal, the stopped application's identified development library was recreated at the same `~/Library/Application Support/Mira` path under the standing repository authorization. Previous development conversations and provider/model configuration were cleared. The shared embedding model files and Keychain were preserved. Provider and conversation-model configuration must be recreated before another user conversation test; the synthetic acceptance data was confined to temporary libraries.

The user explicitly requested change-scoped acceptance: do not repeat already-passing checks without a new relevant change, failure or unresolved concern, and do not expand a small fix into unrelated acceptance work.
