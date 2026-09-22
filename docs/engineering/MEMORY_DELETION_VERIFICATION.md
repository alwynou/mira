# Memory deletion and lifecycle acknowledgments

Date: 2026-09-22. Scope: [#55](https://github.com/alwynou/mira/issues/55).

## Behavior

Memory management now exposes **Delete memory** / **删除记忆** with the existing native irreversible confirmation. The conversational `memory.delete` tool submits one exact authorized memory/revision to a durable body-free queue. The library processes it after the source execution settles, outside execution and workgroup ownership. The app independently displays pending/completed/failed status; a tool receipt alone never claims deletion completed. Replacement acknowledgments retain superseded history, and withdrawal acknowledgments retain archived wording.

Deletion reuses `memory.forget` maintenance, clears domain wording/revisions/evidence/search data, preserves original inline conversation history and a body-free tombstone, and suppresses old-source recapture. A committed deletion instruction is also suppressed for background capture. Revision changes fail the request instead of deleting changed content. Closing/reopening and uncertain completion reconcile durable evidence without another model call. Runtime settlement transitions and business commits wake the processor.

## Automated verification

- Core: 16 focused tests passed for descriptors, exact target/quote preparation, scope/disclosure, and pending versus committed acknowledgment contracts.
- Data: 17 focused tests passed across deletion queue/workflow, retraction workflow, and save acknowledgment suites. The new workflow exercises the actual tool loop, authorization failures, failed-insert rollback, one durable request, completed purge, source suppression, pending/completed archive inspection, and rejection of a structurally valid forged request lacking a journal invocation.
- Composition: the deletion integration test passed all five parameters: normal completion, intervening revision, closing/reopening during the held reply, loss after maintenance admission, and loss after domain purge but before maintenance completion. The test proves the memory still has a body while the reply is running and that completion clears every revision and evidence excerpt. Existing memory management and conversation-page tests passed in the first combined run. Native transcript state tests passed all six cases, including status-driven row/measurement invalidation. Localization tests and the language-policy check passed (2,255 bilingual strings).
- A read-only review identified that a failed execution settlement could need another wakeup without a business write. The library now observes runtime transitions too. An initial rerun stalled in Xcode test startup. The subsequent focused rerun passed all 15 composition tests, including every deletion parameter, on the final processor implementation (`/tmp/mira-delete-composition-final.log`).
- The final Debug app build passed. CI results are recorded with [PR #56](https://github.com/alwynou/mira/pull/56). No live-provider calls were made in this task; synthetic adapters do not establish natural-language decision or wording reliability.

Local logs: `/tmp/mira-delete-core-tests.log`, `/tmp/mira-delete-package-final.log` (retains a corrected test-assertion failure), `/tmp/mira-delete-workflow-final.log` (5 workflow cases passed), `/tmp/mira-delete-composition.log` (three deletion parameters passed), `/tmp/mira-delete-composition-final.log` (15 tests passed), `/tmp/mira-delete-recovery-tests.log` (five deletion parameters passed), `/tmp/mira-delete-host-tests.log`, `/tmp/mira-delete-final-host.log`, `/tmp/mira-delete-app-build.log`.

## Native verification

The local machine runs macOS 27.0 (26A428), with the macOS 27 SDK. `MemoryManagementUITests` could not start because Xcode timed out enabling automation mode (`/tmp/Mira-Memory-Delete-UI.xcresult`). The full host target also reproduced an existing native-divider mouse-tracking assertion in `MiraWindowShellTests.testInspectorPreservesWindowSidebarAndPresentationState`. A later test process stalled in `_prepareTestConfigurationAndIDESession` before composition tests began; it was terminated after capturing a stack sample. These are retained local failures, not passes or omitted checks.

A separate native-app walkthrough used only `/tmp/Mira-Memory-Delete-Native-20260922`, `--demo`, and authored disposable content; the UI explicitly indicated that no network requests were sent. The old running app was closed normally without deleting its data. Native AX and screenshot observations verified:

| Fixture | Observed result |
| --- | --- |
| English, light, 1000×740 | Delete action visible; native confirmation explains irreversibility and retained original chat; cancel retains content; confirm removes the current entry; history detail contains only the forgotten tombstone with no original wording. |
| Chinese, dark, requested 850×620 | Native content settled at 850×672, as in prior minimum-window fixtures. The delete label and confirmation are translated, readable, and not clipped. Confirm removes the current entry; history shows the two body-free tombstones after reopening the same fixture library. |

Screenshots and AX observations are retained in the task's native-tool history. The disposable fixture app was closed and its synthetic library removed after verification. The exact 850×620 outer-frame layout, standalone conversation status badges in the native app, macOS 15 native runtime, and a full four-way language/appearance matrix remain unverified. The status models, invalidation, and actual completion semantics are covered by the focused tests; that is not a claim of visual verification for those badges.

## Limits

The conversational tool can target only a current memory already authorized for the model; management can also delete local-only and historical entries. Ambiguous, quoted, and hypothetical requests are constrained by tool and conversation instructions, while exact target/source/workspace/revision and transaction boundaries are enforced in code. General model semantic compliance and broad M3 memory quality remain separate acceptance work. No personal library, original conversation, credentials, or real chat content was deleted or committed.
