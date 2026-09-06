# Memory and knowledge continuity verification

Date: 2026-09-06. Branch: `dev`. This increment closes concrete navigation, receipt, and stale-content defects in the v0.1 memory/Markdown workflows. It does not mark the MVP released or reopen the deferred streaming-performance work.

## Changes

- Opening a memory from a processing result clears stale search text and retains authorized detail outside the first 100 list entries. A supplementary selected row remains visible. Failed or out-of-scope detail reads clear selection and report an error; state changes and forgetting refresh the presented record. Detail pane identity follows the selected memory.
- `memory.remember` reports the committed memory's actual remote-use permission when deduplication reuses an existing entry. It preserves the user's existing policy. Newly captured tool memories remain local-only.
- Selecting a knowledge search hit presents the exact matching chunk, including chunks beyond the first 200 summaries. Changing source/version invalidates pending reads. Deleting the selected source clears presentation and invalidates a read that may already hold an earlier authorized snapshot.
- Citation buttons retain availability rather than source bodies. The visible sheet resolves the complete reference/execution/conversation identity on opening and on application changes. Revocation or deletion clears the body, and closing the sheet clears its presentation copy. A source update preserves the old citation's exact historical bytes.

Contracts: [memory](../architecture/MEMORY_IMPLEMENTATION.md), [knowledge](../architecture/KNOWLEDGE_IMPLEMENTATION.md). Product behavior: [memory and knowledge](../product/MEMORY_AND_KNOWLEDGE.md).

## Acceptance evidence

All fixtures use new temporary libraries and synthetic content. No credentials, user libraries, or real provider endpoints were used. Parent review covered both Luna contributions and the integrated changes.

| Boundary | Evidence |
|---|---|
| Memory navigation | `MemoryPresentationTests`: 101 memories, stale search, bounded-list selection, changed filter, nonexistent and out-of-workspace IDs, archive and forget refresh |
| Truthful reused-memory receipt | `MemoryToolTests.reusedMemoryReceiptReportsCommittedRemoteUsePolicyWithoutChangingIt`: real store, durable tool dispatch and approval path; one memory remains, its remote-use permission is preserved, and the receipt agrees |
| Search result inspection | `KnowledgePresentationTests`: a 230-section Markdown file whose matching chunk lies beyond the displayed summaries; exact version/body, reload, version change, stale chunk action and scope clearing |
| Late read after deletion | A real application chunk read is suspended after obtaining authorized bytes. Deletion completes through the presentation model before the read resumes; selection and body remain empty |
| Citation policy and identity | Revocation and deletion while observing, reopening after removal, exact historical bytes after update, wrong conversation identity, observation replacement and cancellation |
| Application and backup continuity | `KnowledgeApplicationTests.knowledgeFlowSurvivesApplicationReopenAndBackupRestore`: initial search/open/read/cited turn; new application/store instances resolve the old citation and execute another search-backed turn; a current schema-v10 backup restores to an isolated library and repeats the citation/tool flow. Request snapshots, tool receipts and source audit references are checked |

Local verification on Apple M1 Pro, macOS 26.6.2, Xcode 26.6:

- Full MiraKit suite: 308 tests in 34 suites passed; the opt-in scale benchmark remains skipped in the ordinary command.
- Debug app build and host tests: five XCTest cases plus 57 Swift Testing cases passed. The new presentation coverage uses production application/store boundaries; it is not a full native UI walkthrough.
- Release build passed. The staged Xcode project was regenerated from an isolated export of the staged sources and reproduced identically; unrelated local icon/design work was excluded.
- Eight Python script tests passed. Language policy and compiler-extracted UI coverage passed for 1,132 bilingual entries. No new translation keys were needed.

The first complete host run failed the existing `TranscriptScrollAnimationTests.changingTargetsProducesIntermediateOffsetsWithoutReversing` monotonic-offset assertion. The subsequent complete host command with `-parallel-testing-enabled NO` passed. The cause of that intermittent native animation result was not established, and no renderer or scrolling implementation was changed. Keep it associated with the already deferred [rendering acceptance](LONG_CONVERSATION_PERFORMANCE.md), rather than treating this rerun as closing that gate.

## Remaining evidence

The isolated native demo could launch, but CUA inspection failed with ScreenCaptureKit error `-3811` before obtaining a usable UI state. The owned demo app/library were removed; the user's running Mira and development library were preserved. No native picker, sheet, keyboard, or VoiceOver walkthrough is claimed from this attempt.

Real-model extraction/recall/citation quality, attended Keychain exercises, macOS 15 and additional CPU UI use, seven-day use, signing and notarization remain in the [execution ledger](MVP_EXECUTION.md). Synthetic provider turns and presentation-state tests do not satisfy those gates. Fee estimation and other v0.1 completion gaps remain separate follow-up work. Task/reminder work remains v0.2.
