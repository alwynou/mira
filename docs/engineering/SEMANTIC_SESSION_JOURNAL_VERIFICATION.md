# Semantic session journal verification

Date: 2026-09-16. Environment: Apple M1 Pro, macOS 26.6.2, Xcode 26.6,
Swift 6.3.3. This increment implements the boundary described in
[DSH source research](DSH_SESSION_LOG_RESEARCH.md).

## Result

- Canonical v5 JSONL contains one ordered assistant settlement per model attempt.
  The streaming timer and byte threshold replace an authenticated active-draft
  sidecar; they append no token or draft-patch events to the conversation log.
- Text, thinking and tool calls retain their original block positions in live
  activity, settled history and request replay. Parallel tool bodies remain
  concurrent; their result events settle in model-call order. Publication checks
  authorization again after waiting for an earlier result.
- Request manifests reference original user messages, settled model output and
  tool results. Exact materialized input, block identities, continuation and the
  tool-observation wrapper are preserved. Execution replay uses these references.
- Cancellation, process recovery and archive restoration preserve eligible
  unfinished blocks, then retire the draft after a durable settlement. Privacy
  cleanup includes both the sidecar and referenced content.

Visible answer/thinking summaries keep their independent privacy lifetime. This
change reduces repeated request/transcript bodies; it does not claim zero duplication.

## Scoped automated evidence

Only affected package suites, native composition tests and localization tests were
selected. No full package or app test suite was run. Intermediate logs retain the
failures found during integration; the final result for each boundary is below.

| Boundary | Final evidence |
|---|---|
| State, request manifests, model drafts/timers, activity, audit, query, retry, source dispatch, kernel and automatic memory extraction | Named suites passed in `/tmp/mira-v5-contract-tests.log`; this run also exposed fixture and privacy issues in other suites, resolved by the scoped runs below |
| Model thinking fixture, interrupted history, forged tool evidence and public tool/context challenge | Relevant suites passed in `/tmp/mira-v5-corrections.log`; its remaining privacy failure was resolved in the storage run |
| Journal append/recovery, payload cleanup, live output and privacy erasure | Relevant suites passed in `/tmp/mira-v5-storage-tests.log`; its remaining unfinished-draft archive failure was resolved in the final boundary run |
| Archive restore/catalog, active drafts, exact request/block order, concurrent tool settlement and cancellation | 37 tests in five suites passed in `/tmp/mira-v5-final-boundaries.log`; the separate crash suite in that run found five obsolete fault-injection fixtures |
| Archive with both an active draft and external payload | The extended restoration fixture passed in `/tmp/mira-v5-mixed-archive-test.log`; catalog entries follow drafts → payloads → session logs |
| Process termination and repeated recovery | All 16 scenarios passed in `/tmp/mira-v5-crash-tests.log` after adapting the fixtures to actual inline/external storage boundaries |
| Native startup recovery, conversation state and stream buffer | 20 tests passed in `/tmp/mira-v5-host-tests.log` |
| Localized diagnostics | Five `MiraHostTests/LocalizationTests` passed in `/tmp/mira-v5-localization-tests.log`; language policy passed with 2,108 bilingual strings |
| Final app | `/tmp/mira-v5-final-app-build.log`: `BUILD SUCCEEDED` |

The final package boundary selection was:

```sh
swift test --package-path Packages/MiraKit --filter 'SQLiteLibraryRestorerTests|LibraryArchiveFileCatalogTests|AgentProcessCrashTests|AgentToolExecutorIntegrationTests|SessionActiveDraftTests|SemanticSessionJournalTests'
swift test --package-path Packages/MiraKit --filter AgentProcessCrashTests
```

The crash fixture now uses non-UTF-8 module bytes to exercise pending external
payload writes/cleanup. Inline privacy erasure stops after replacement-log
publication. The thinking-draft scenario stops after sidecar publication and
verifies 6,080 thinking bytes plus continuation, one model dispatch and one terminal
fact across two independent recovery processes.

Host checks used `MiraCompositionTests` filtered to `LibraryRecoveryTests`,
`ConversationPageStateTests` and `ConversationStreamBufferTests`, followed by
`MiraHostTests` filtered to `LocalizationTests`. Both used Debug, the arm64 macOS
destination, locked package versions, `.build/xcode` and disabled code signing.
The final build used the same arguments with scheme `Mira` and action `build`.

## Native and inspectable JSONL evidence

The offline demo ran with `--demo --verify-multiround-flow` against the isolated
`.build/verification/mira-v5-demo` directory. The expanded native transcript showed:

1. First reasoning, first source inspection text, first tool call.
2. Second reasoning, second source inspection text, second tool call.
3. Final reasoning and `Both sources agree: alpha and beta.`

After quitting and reopening the app, the same order appeared without duplicate
steps. The session JSONL contains three `request/start`, three `assistant/message`,
two `tool/call`, two `tool/result` and one `turn/end`, with no `response_delta`.
The native check used the existing dark Chinese layout; no UI layout was changed.

Local synthetic artifacts, intentionally excluded from Git:

- `.build/verification/session-v5-example.jsonl`: 24,353 bytes; two model steps,
  one tool call/result, and a deliberately text-before-thinking block order.
- `.build/verification/mira-v5-demo/Sessions/sessions/A6F836AB-E9F6-4FE0-A0D1-4BDB1AF4312F.jsonl`:
  the three-step native demo, 37,023 bytes.

These are fixture measurements, not compression benchmarks or private conversations.

## Development library and limits

The obsolete development session/domain data was cleared at the same application
support path. No backup or compatibility library was created. Model settings,
library identity, Keychain credentials and the shared Qwen 4-bit model were retained.
The cleanup initially removed the empty privacy store's schema marker; it was
restored, and empty full-text indexes were rebuilt. Settings row digests matched
before and after cleanup. The final app reopened normally with an empty transcript
and the existing DeepSeek model selected.

No paid provider request, complete light/dark or language UI matrix, macOS 15 runtime,
large-library benchmark, physical power-loss test or exhaustive fault-window sweep
was performed. These focused checks do not close those separate product gates.
