# Memory and knowledge continuity verification

Date: 2026-09-06. Branch: `dev`. This increment closes concrete navigation, receipt, and stale-content defects in the v0.1 memory/Markdown workflows. It does not mark the MVP released or reopen the deferred streaming-performance work.

## Changes

- Opening a memory from a processing result clears stale search text and retains authorized detail outside the first 100 list entries. A supplementary selected row remains visible. Failed or out-of-scope detail reads clear selection and report an error until dismissed; background list refreshes preserve that error. State changes and forgetting refresh the presented record. Detail pane identity follows the selected memory.
- `memory.remember` reports the committed memory's actual remote-use permission when deduplication reuses an existing entry. It preserves the user's existing policy. Newly captured tool memories remain local-only.
- Selecting a knowledge search hit presents the exact matching chunk, including chunks beyond the first 200 summaries. Changing source/version invalidates pending reads. Deleting the selected source clears presentation and invalidates a read that may already hold an earlier authorized snapshot.
- Citation buttons retain availability rather than source bodies. The visible sheet resolves the complete reference/execution/conversation identity on opening and on application changes. Revocation or deletion clears the body, and closing the sheet clears its presentation copy. A source update preserves the old citation's exact historical bytes.

Contracts: [memory](../architecture/MEMORY_IMPLEMENTATION.md), [knowledge](../architecture/KNOWLEDGE_IMPLEMENTATION.md). Product behavior: [memory and knowledge](../product/MEMORY_AND_KNOWLEDGE.md).

## Acceptance evidence

The automated fixtures below use new temporary libraries and synthetic content. No credentials, user libraries, or real provider endpoints were used for those fixtures. Parent review covered both Luna contributions and the integrated changes. The later live UI check is recorded separately below.

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

Final implementation `7a80585cb5a6542cda334b170a7eac8faf07f2eb` passed the repository's unchanged default commands in [CI 34032186367](https://github.com/alwynou/mira/actions/runs/34032186367), including the complete host suite on the macOS 15 runner. The evidence-only follow-up commit does not change executable code. CI does not substitute for the full native walkthroughs below.

The first complete host run failed the existing `TranscriptScrollAnimationTests.changingTargetsProducesIntermediateOffsetsWithoutReversing` monotonic-offset assertion. The subsequent complete host command with `-parallel-testing-enabled NO` passed. The cause of that intermittent native animation result was not established, and no renderer or scrolling implementation was changed. Keep it associated with the already deferred [rendering acceptance](LONG_CONVERSATION_PERFORMANCE.md), rather than treating this rerun as closing that gate.

## Remaining evidence

The earlier isolated native demo could launch, but CUA inspection failed with ScreenCaptureKit error `-3811` before obtaining a usable UI state. The owned demo app/library were removed; the user's running Mira and development library were preserved. No native picker, sheet, keyboard, or VoiceOver walkthrough is claimed from that attempt.

Real-model extraction/recall/citation quality, attended Keychain exercises, macOS 15 and additional CPU UI use, seven-day use, signing and notarization remain in the [execution ledger](MVP_EXECUTION.md). Synthetic provider turns and presentation-state tests do not satisfy those gates. Basic fee estimation was subsequently implemented; see [usage/cost verification](USAGE_COST_VERIFICATION.md). Task/reminder work remains v0.2.

## Live explicit-save UI check

Date: 2026-09-06. The user configured the provider/model and explicitly requested Computer Use testing. This check used the running Debug app, the current development library, and the selected `deepseek-v4-flash` model under DeepSeek. The fixture was a fabricated preference for organizing reading notes with blue labels. No credentials or personal conversation content are included in this record.

| Step | Observed native UI evidence | Result |
|---|---|---|
| Submit an explicit remember request | The Chinese fixture was pasted into the composer and its exact value was checked in the accessibility tree before sending | Passed |
| Review the model's memory request | The approval sheet showed the proposed preference, the matching original excerpt, global scope, and local-only disclosure | Passed |
| Confirm saving | The Save Memory action completed and the model returned a save acknowledgment | Passed |
| Verify the actual record | Opening Memories showed the matching content with Active state and Preference kind | Passed; independent of the model's acknowledgment |
| Inspect details, recall in a new conversation, correct, and forget | Native automation disconnected while selecting the record and requesting a screenshot; reconnection attempts failed | Initially blocked; completed in the authorized native follow-up below |

The stored entry was local-only. A model's promise to use it later is not evidence of authorized remote recall: that requires a separate visible remote-use choice and a new-conversation test. This check does not establish persistence across app restart, automatic extraction quality, citation correctness, or acceptance of other providers.

CUA `typeText` initially dropped the Chinese characters and submitted punctuation only. The subsequent attempt used `paste` and verified the input before sending. This is recorded as an automation input failure, not a Mira text-input defect. No database edits or library reset were used as substitutes for UI actions.

The automation error was `Sky Computer Use native pipe closed before response`, recurring after a CUA session reset. SkyComputerUseService diagnostic reports were present and a process check still found Mira running. No usable screenshot was captured. This is an automation-service blocker, not evidence that Mira crashed. The successful accessibility observations above support only the explicit-save path.

On the user's follow-up request, the failure was reproduced specifically when selecting a memory. CUA could inspect Finder; after the user switched Mira back to a conversation, CUA could inspect both the conversation and the unselected memory list again. Selecting the memory then caused another service failure, and the screenshot fallback failed through the closed pipe. The service's diagnostic reports show `EXC_BREAKPOINT` / `SIGTRAP` with `_assertionFailure` and `Array.remove(at:)` on the faulting thread. These observations narrow the trigger to inspecting the selected-memory UI; they do not identify the exact service defect or establish a Mira accessibility violation. No speculative SwiftUI workaround was applied.

## Authorized native memory follow-up

Date: 2026-09-06. The user explicitly authorized AppleScript/macOS accessibility to continue the same UI tests. AppleScript operated the memory detail, editor, replacement form, and forgetting confirmation; CUA operated the working conversation, citation, and inspector surfaces. OS window captures supplied visual confirmation where AppleScript could not decode attributed button labels. All mutations went through Mira's visible UI. Provider configuration, Keychain credentials, and the development library were not reset.

| Boundary | Observed evidence | Result |
|---|---|---|
| Detail and source | The blue-label preference showed revision 1, global scope, explicit-user authority, its exact committed-message excerpt, and remote use disallowed. Open Conversation returned to that source conversation | Passed |
| Reviewed remote use | Only the fabricated memory's remote-use checkbox was enabled in Edit. Saving produced revision 2 and the detail displayed remote use allowed | Passed |
| Independent recall | A new conversation asked for the saved preference without supplying the color. DeepSeek answered blue and emitted a resolvable version-2 memory citation | Passed |
| Citation evidence | The citation sheet displayed the blue preference and the original committed-message excerpt | Passed |
| Semantic correction | Replace Memory created a green-label preference under a new memory ID. The old entry's detail displayed the confirmed replacement relation | Passed; list presentation issue below |
| Recall after correction | Another new conversation asked for the current preference without supplying either color. DeepSeek answered green and cited the new memory's version 1; its citation sheet displayed matching manual-entry evidence | Passed |
| Historical reference stability | Reopening the earlier blue answer's citation still displayed version 2 with the blue content and a notice that the memory had since changed | Passed |
| Forget and generated-content cleanup | The green memory was forgotten through the visible confirmation. It disappeared from the Active list. Its previous answer was replaced by the app's forgotten-memory cleanup notice, while the user question remained | Passed |
| No old-preference revival in a new conversation | A further new conversation asked for the current label color without supplying an answer. The model reported no available memory. The execution inspector independently showed a completed `memory.search` receipt of `{"memories":[],"truncated":false}` | Passed for this live case |

The final conversation remains open for inspection. The green replacement was forgotten; the superseded blue entry remains as historical test data. This was one live DeepSeek smoke test, not a statistical memory-quality evaluation. App restart/persistence, automatic extraction, cross-workspace isolation, other providers, VoiceOver, and the wider Q04–Q06 acceptance remain outside this run. No source changes, rebuild, or broad automated regression rerun were needed for this UI-only test.

### Findings from the initial walkthrough

- The Active memory list labels the superseded blue entry as Active alongside its green successor; after forgetting the successor, the old row still appears Active. Only its detail discloses that it was superseded. The live new-conversation test did not revive it, but the management UI should distinguish current and superseded entries clearly.
- The initial model acknowledgment promised to consider the blue preference in future conversations while the saved entry was still local-only. The later recall check succeeded only after the explicit remote-use change. The save acknowledgment should explain the committed disclosure policy accurately.

The follow-up [natural memory and retained-history fix](NATURAL_MEMORY_VERIFICATION.md) resolves these two findings and changes the forgetting contract. The explicit-retrieval prompts above do not establish ordinary-input recall quality. The native automation defect is tracked separately above; it was handled through the authorized AppleScript fallback, with no Mira crash observed.
