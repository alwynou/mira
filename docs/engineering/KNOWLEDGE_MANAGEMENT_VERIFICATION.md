# Native Knowledge management verification

Date: 2026-09-23. Scope: [#59](https://github.com/alwynou/mira/issues/59), following the approved [Knowledge management design](../product/KNOWLEDGE_MANAGEMENT_DESIGN.md). This increment implements Knowledge; further Memory work remains paused.

## Delivered behavior

Knowledge is a retained main-pane destination beside Memory. A 320 pt source list supports current-text/title search, exact Inbox/workspace filters, status, ordering and keyset pagination. The right reader provides rendered Markdown, original lines, historical versions and source information. Below a 790 pt main pane, navigation changes to list/detail with retained filters. The existing native sidebar, titlebar, conversation drafts and citation authorization remain in use.

The presentation model obtains local management reads through library-owned Knowledge application leases. Reads are bounded, generation checked and cleared on maintenance, closure or observation cancellation. Admitted mutations settle independently of view navigation; obsolete read/action failures cannot repopulate a different library binding. Import copies explicit UTF-8 Markdown selections, defaults to local-only, freezes update revisions and does not expand permission for duplicates or updates. Revocation and deletion use the existing revision-bound library maintenance flow. Source deletion clears all retained versions and affected derived content; external files and original user messages remain.

No schema migration, provider call, live file watcher, PDF import or Tasks interface is added. Layout values are defined in `MiraTheme` and exported to the shared token JSON. All new app-owned labels have English and Simplified Chinese catalog entries.

## Automated evidence

Local environment: macOS 27.0 (26A428), Xcode 27.0 (27A266a). This is not a macOS 15 runtime result.

| Check | Result |
| --- | --- |
| `swift test --package-path Packages/MiraKit --filter 'KnowledgeManagementTests\|KnowledgeApplicationOwnershipTests\|JournalKnowledgeStoreTests\|KnowledgeModuleTests'` | Passed: 14 data tests and 13 core tests. |
| `xcodebuild -project Mira.xcodeproj -scheme MiraCompositionTests -configuration Debug -destination 'platform=macOS' -derivedDataPath .build/xcode -onlyUsePackageVersionsFromResolvedFile CODE_SIGNING_ALLOWED=NO -only-testing:MiraCompositionTests/KnowledgeManagementModelTests test` | Final run passed all 9 tests. |
| `xcodebuild -project Mira.xcodeproj -scheme Mira -configuration Debug -destination 'platform=macOS' -derivedDataPath .build/xcode -onlyUsePackageVersionsFromResolvedFile CODE_SIGNING_ALLOWED=NO build` | Passed after the final source change. |
| `python3 scripts/check_language_policy.py --extracted-dir .build/xcode/Build/Intermediates.noindex/Mira.build/Debug/Mira.build` | Passed: 2,343 bilingual keys, including extracted UI coverage. |
| `python3 scripts/export_design_tokens.py`; `xcodegen generate` | Generated artifacts updated with their owning sources. |
| Required local `MiraHostTests` target | Not fully green: XCTest executed 53 tests, with 3 intentional live-evaluation skips and 1 divider mouse-tracking failure. The separate Swift Testing run reported 110 tests in 17 suites passing, with existing opt-in checks skipped. |

The local host failure is `MiraWindowShellTests.testInspectorPreservesWindowSidebarAndPresentationState`, at the assertion that the native divider enters mouse tracking. It repeated in an isolated rerun. The failing assertion and native divider path are unchanged; the cause is not established, and this record does not reclassify the failure as a pass. Required CI checks must pass before merge.

The first composition run exposed three incorrect test assumptions: observing a nil page during transition, retaining a workgroup across privacy maintenance, and deleting using an obsolete source revision. Tests now wait for settled pages, reacquire the current workgroup and use the refreshed revision. The final 9-test run passed after the action-error lifetime guard was added.

The focused package tests cover more than one source page, cursor/filter mismatch, exact scopes, local-only reads, current versus historical search, a latest failed version with a retained successful current version, more than 100 retained versions, late-chunk search, Unicode titles, CRLF and corrupt blobs. Composition tests cover import/deduplication without permission expansion, failed updates, original/current version paging, exact revision conflicts, revoke/rebind, deletion, observation cancellation/reopening, mixed import outcomes and stopping before admission. Fixtures are synthetic and isolated; tests use no credentials or paid endpoints.

## Native review

The Debug app ran with `--demo` and an explicit disposable library under `/tmp/mira-knowledge-native-review/library`. A separate review bundle identifier prevented use of the normal library. Authored fixtures contained a 30-line, 851-byte Markdown document with headings, a list, quotation, table and code block, plus a separate 261-byte update. Original files were retained after deletion. No provider requests were sent.

| Surface or interaction | Observed result |
| --- | --- |
| English/light, 1280 × 800 pt window | Two-column list/reader, readable Markdown and native import review. The final build displays the selected version size as `851 bytes` even on a Chinese-language OS. |
| Chinese/dark, minimum supported width | App settled at 850 × 672 pt including the 52 pt toolbar (620 pt pane). List and detail use separate compact navigation; labels and import/update controls fit. |
| Import and update | File picker → local-only review → imported result → local source; update retains source title/scope/permission and exposes two versions. |
| Current/historical reading | Current update and the original snapshot display independently. Historical reading shows an explicit banner. Original-text mode ends at line 30, without an artificial line 31 from the trailing newline. |
| Search and no results | A current-body match opens the returned line range; an absent query shows no results and can be cleared. Filters survive navigation. |
| Model-use permission | Allow confirmation changes the badge; revocation explains retained local answers/thinking, rebinds the library and keeps the document locally readable. |
| Delete | Confirmation identifies the source, all versions and affected generated answers/thinking. Confirming the disposable source returns to Sources: 0 with no cached reader body. Reimport succeeds. |
| Conversation continuity | An unsent synthetic draft survives Knowledge navigation and return to the conversation. |

The OS file picker disabled an intentionally invalid-UTF-8 sample, so native failed-parse presentation was not established by that attempt; failed import/update outcomes are covered by the automated fixtures. Some later background-window captures returned Stage Manager thumbnails. Those captures were discarded; only full-size app/sheet captures are retained below. Keyboard focus in native file selection was recovered through its Go to Folder control. Neither thumbnail output nor an attempted selection is counted as successful visual evidence.

- [English/light reader](evidence/knowledge-management/en-light-detail.png)
- [Chinese/dark compact list](evidence/knowledge-management/zh-dark-list.png)
- [Chinese/dark compact reader](evidence/knowledge-management/zh-dark-detail.png)
- [Chinese/dark update review](evidence/knowledge-management/zh-dark-update.png)
- [Chinese/dark versions](evidence/knowledge-management/zh-dark-versions.png)

## Remaining limits

This review does not establish macOS 15 native rendering, VoiceOver narration, Reduce Transparency/Increase Contrast, a complete keyboard-only workflow, full-size native 100-file batches, large-corpus interaction latency or the full historical citation/privacy matrix. These are separate acceptance limits; existing exact citation and privacy contracts are retained. The browser prototype evidence is a design reference, not a substitute for this native review. Live-model Knowledge answer quality and remaining Memory acceptance are outside this increment.
