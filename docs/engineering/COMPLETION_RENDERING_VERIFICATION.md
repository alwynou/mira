# Completion rendering verification

Date: 2026-09-14. Environment: macOS 26.6.2, Apple Silicon, Xcode 26.6.

## Change and failure boundary

The final model-attempt event cleared live output before the asynchronous durable query replaced it. Completion also invalidated prepared Markdown for status-only row changes and immediately ended the last text fade. Together these could produce a blank/rebuilt answer or a sudden brightness change.

A successful attempt now emits an execution handoff marker. The bound presentation retains its latest delivered body until a matching durable draft or completed execution reaches the handoff cursor. Core retains only the execution ID and authorization epoch, not the old text or writer lease. Cancellation, privacy invalidation, closing, and ordinary clears still remove the transient body immediately. A stale snapshot or another execution cannot settle the handoff.

Status-only row updates reuse prepared Markdown and the mounted native view, preserving attachments and selection. The final text fade finishes naturally; Reduce Motion still disables it. A self-contained completed activity preview accompanies the existing streaming preview.

## Focused verification

Only completion rendering and its directly affected cancellation/privacy boundaries were tested. Fixtures were synthetic, with isolated test storage and no paid provider requests.

| Check | Result |
| --- | --- |
| `swift test --package-path Packages/MiraKit --filter 'SessionOutputTests\|AgentLiveOutputIntegrationTests'` | 14 tests passed; covers actual executor handoff, output ordering, cancellation, and privacy revocation |
| `MiraHostTests`: `ConversationStreamBufferTests`, `NativeTranscriptRowTests`; `MiraCompositionTests`: `ConversationPageStateTests` | 27 tests passed; includes pending-tail retention, stale snapshot protection, stable row identity, selection, and immediate revocation |
| `MiraMarkdownViewTests`: `statusOnlyCompletionPreservesTransientRendering()`, `streamingFadeSettlesWithoutContentLoss()`, `reduceMotionSkipsFadeDrawing()`, `terminalAndReuseState()` | 4 tests passed; fade markers, final bitmap, code attachment identity, selection, Reduce Motion, and reuse |
| `ConversationFlowUITests`: `testCompletionKeepsRenderedAnswerEnglishLight`, `testCompletionKeepsRenderedAnswerChineseDark` | 2 native UI tests passed |
| Debug `Mira` app build, signing disabled | Passed |
| `git diff --check` | Passed |

Host and UI checks used `.build/xcode`, `-destination 'platform=macOS'`, resolved package versions, and explicit `-only-testing` filters. Swift Testing method filters included `()`; the four Markdown tests were verified in a separate invocation after the initial method filters selected no tests.

## Native evidence

The native fixture streams through thinking, answering, and completion. The UI checks repeatedly assert that the answer remains present and its leading/top position stays fixed through completion and four settled samples. English/light uses the regular window; Chinese/dark uses the 850 pt minimum width. Visual inspection confirmed continuous body placement, expected text growth, and the activity transition to completed.

| Appearance | Streaming | Completed |
| --- | --- | --- |
| English, light | [Before](evidence/2026-09-14-settlement-en-light-streaming.png) | [After](evidence/2026-09-14-settlement-en-light-completed.png) |
| Chinese, dark, minimum width | [Before](evidence/2026-09-14-settlement-zh-dark-streaming.png) | [After](evidence/2026-09-14-settlement-zh-dark-completed.png) |

Result bundles: `Test-MiraHostTests-2026.09.14_15-55-40-+0800.xcresult`, `Test-MiraHostTests-2026.09.14_15-56-34-+0800.xcresult`, and `Test-MiraUI-2026.09.14_15-56-54-+0800.xcresult` under `.build/xcode/Logs/Test`.

These checks are deterministic transition regressions and sampled native observations, not a frame-by-frame performance benchmark. Live-provider timing, Intel, and macOS 15 runtime verification were not performed. Unrelated feature suites were not run.

The later [multiround process presentation](MULTIROUND_PROCESS_VERIFICATION.md) folds all reasoning on completion, including the final round. This intentionally reduces the process height above the answer. Current continuity checks retain renderer/selection identity and verify stable geometry after that fold, instead of requiring the answer's absolute vertical position to remain unchanged across it.
