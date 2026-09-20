# Native memory management verification

Date: 2026-09-20. Issue: [#11](https://github.com/alwynou/mira/issues/11).
Baseline: `0b70e14`; implementation branch: `codex/memory-management`.

## Scope

The approved [design proposal](MEMORY_MANAGEMENT_DESIGN_REVIEW.md) is implemented in the native conversation shell. Memories now opens scoped, paged Current/History lists with literal search and update-time ordering. Detail exposes the current statement, independent disclosure settings, immutable evidence, wording revisions, replacement relationships, archive/restore, and revision-bound forgetting. At narrow widths, selection opens a detail with a Back action. The existing conversation pages remain mounted and retain drafts, streams, and reading state.

Manual additions start local-only. Editing preserves memory identity, source, scope, subject, connection restrictions, and validity bounds. Replacement starts with a blank new statement, shows the old statement, and leaves the previous record in history. Explicit competing replacements can be confirmed against their current successor or rejected; automatic extraction does not create a review inbox. Forgotten records are body-free and have no restore action.

All memory writes use the existing application ports. Forgetting uses library maintenance with the exact memory ID and expected revision. Library generation changes clear list, detail, related-memory, and source caches and dismiss management editors/confirmation sheets. Queries filter before their 100-row limit and use update-time/ID keyset pagination. Validity transitions schedule a fresh query, including transitions outside the first page. No database schema or design token change is introduced.

Source navigation validates the immutable user-message reference against the authoritative session snapshot. It loads contiguous 128-message pages so jumping backward cannot hide intervening messages. The operation is cancellable and bounded to 32 pages; an older source produces a localized limit message rather than an incomplete transcript. Its implementation preserves existing draft and reading-state objects. This limit is independent of memory recall and source authorization.

## Verification

Local environment: Apple Silicon, macOS 27.0 (26A428), Xcode 27.0 (27A266a). CI independently targets macOS 15 package execution and macOS 26 app/host execution. Local native checks do not establish macOS 15 or macOS 26 runtime acceptance.

- Application Debug build passed with existing unrelated warnings.
- Complete `MiraHostTests` run passed: 109 tests in 17 suites.
- `swift test --package-path Packages/MiraKit --filter 'JournalMemoryStoreTests|MemoryApplicationOwnershipTests|MemoryModuleTests'` passed: 16 tests. Coverage includes filter-before-limit behavior, cursor binding, scope isolation, body-free history, and validity transitions outside the first page.
- Focused composition checks passed: 13 tests across `MemoryEditorModelTests`, `MemoryManagementModelTests`, and `ConversationSourceNavigationTests`. They cover local-only manual defaults, frozen edit/replacement metadata, revision conflicts, related selection outside the filtered list, competing replacement confirmation, generation rebinding, forgetting, and contiguous source navigation without draft or reading-state loss. The five management tests also passed after cancellation/drain changes.
- Source and compiler-extracted localization checks passed: 2,239 bilingual strings. Initial fixture failures were corrected before these passing runs; they are not counted as acceptance evidence.

### Native interaction evidence

The app ran with `--demo --data-directory /tmp/Mira-Memory-Native-Review`, using authored synthetic records and the offline demo provider. Native interaction checks covered:

- English/light: manual local-only addition, selection, wording edit with unchanged evidence, replacement with the previous record in History, forget confirmation, body-free forgotten detail without restore, and an unsent draft retained through management and forgetting.
- Chinese/dark: current list, narrow list/detail navigation, localized edit sheet, preserved original English authored content, exact conversation source quotation, and View original message returning to the source while preserving an unsent draft.
- The existing native minimum is a 850 × 620 pt content constraint; system chrome contributes to the outer frame. The narrow detail capture is 850 × 672 pixels, with subsequent native layout at 881 × 672 on this OS. The edit sheet is 560 × 580 with scrollable content and a visible fixed action row. These dimensions describe this local runtime, not a promise about every macOS version's frame decoration.

Synthetic screenshots: [English/light detail](evidence/memory-management/en-light-detail.png), [narrow detail](evidence/memory-management/zh-dark-minimum-detail.png), [edit sheet](evidence/memory-management/zh-dark-minimum-editor.png), [conversation source](evidence/memory-management/zh-dark-source.png), and [source return with retained draft](evidence/memory-management/zh-dark-source-return.png).

`MiraUI` / `MemoryManagementUITests` passed both complete native flows: Chinese/dark at the native minimum (84.793 seconds) and English/light in a wide window (79.202 seconds). The final local result is `/tmp/Mira-Memory-UI-Verified.xcresult`. The fixtures exercise manual default permissions, creation, editing, replacement, search, history, confirmation, body-free forgetting, and retained draft. [Wide list/detail](evidence/memory-management/en-light-wide-detail.png) and [forgotten detail](evidence/memory-management/en-light-forgotten.png) are final-run captures.

The first XCTest UI attempt timed out while initializing system automation before application launch. Later fixture corrections account for native row values, transient text-selection accessibility, scrolling to actions, and window sizing. The final run above passed; earlier failures are not counted as acceptance. GitHub package and app/host checks must pass on the linked PR before merge.

## Limits

The deterministic tests and offline demo use synthetic data and make no model requests. They do not establish natural-memory extraction quality, real-provider recall quality, or embedding performance. VoiceOver, Reduce Transparency, Increase Contrast, Intel execution, and native macOS 15 runtime remain separate acceptance work. Knowledge and Tasks management screens remain deferred. This increment does not close all M3 release gates.

The standing engineering workflow is now recorded in `AGENTS.md` and [Development](DEVELOPMENT.md): issue, fresh branch from updated main, implementation and verification, linked PR, then merge after required checks pass.
