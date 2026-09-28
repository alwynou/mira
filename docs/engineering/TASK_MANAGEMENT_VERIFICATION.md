# Tasks management verification

Date: 2026-09-28. Scope: [issue #73](https://github.com/alwynou/mira/issues/73), native macOS task and one-time reminder management. Product and technical contracts remain in [Records](../product/RECORDS.md) and [Tasks and reminders](../architecture/TASKS_AND_REMINDERS.md).

## Result

The Tasks sidebar now opens management in the existing window shell. Exact Inbox/workspace scope, title/notes search, status filters and bounded pages lead to task details, original evidence and revision history. Users can create, edit, start, complete, cancel and reopen tasks; review pending proposals; and explicitly request notification permission, retry scheduling or resume restored reminders. Due dates remain separate from reminders.

Editing retains a frozen revision and draft across a conflict until explicit reload. Identical save retries retain their operation identity. Presentation reads are scoped to the mounted observer and library generation; accepted writes stay owned by the application/library after navigation. Unchanged reminder times preserve restored `paused` state during other edits. Pending proposal lookup uses an exact ID instead of searching only the first 100 proposals.

## Automated verification

All data and transports were synthetic. No paid provider or real credential was used.

| Check | Result |
|---|---|
| `swift test --package-path Packages/MiraKit --disable-automatic-resolution --filter 'TaskIntegrityTests\|TaskWorkflowTests\|ReminderSchedulerTests\|TaskToolSequenceTests'` | Passed: 26 tests across four selected suites. Covers task/proposal receipts, source freshness, CAS, rollback, notification ownership, paused reminders and cleanup. |
| Task management paging/search case, rerun after adding normalization assertions | Passed. 205 initial tasks reach the fifth page; literal punctuation, notes, case/diacritic/width normalization and invalid page bounds are covered. |
| `MiraCompositionTests/TaskManagementModelTests` | Four passed: scope/search/status, preserved conflict draft and explicit reload, lifecycle/reminder validation, accepted save after navigation and maintenance-generation invalidation. |
| `MiraCompositionTests/MacTaskManagementFixtureTests` | Passed after correcting the test to supply an explicit future reminder time. Verifies real offline runtime settlement, proposal evidence/acceptance, fixture statuses and idempotent reseeding. |
| `MiraHostTests/LocalizationTests` | Seven passed. The task locale test passed again after adding the missing create-toolbar translation. |
| `MiraHostTests/MiraWindowShellTests/testNativeConversationHeaderTracksTrafficLightsScrollDetailAndNativeControls` | Passed with Tasks toolbar/navigation included. |
| Debug app build, `xcodegen generate`, design token export | Passed. Generated project and token JSON are committed together. |
| `python3 scripts/check_language_policy.py` | Passed with 2,444 bilingual catalog entries. |
| `git diff --check` | Passed. |

Xcode checks used `-project Mira.xcodeproj -configuration Debug -destination 'platform=macOS' -derivedDataPath .build/xcode -onlyUsePackageVersionsFromResolvedFile CODE_SIGNING_ALLOWED=NO`, the matching `Mira` or `MiraCompositionTests` scheme, and the listed `-only-testing:` selectors. Full pre-merge regression is delegated to the repository's required CI checks instead of duplicating the same suites locally.

The initial implementation had a catch-variable shadowing compile error, and one build read the localization catalog during its write. Both were corrected before the passing builds. The first combined composition run passed all four model tests but failed the fixture's acceptance assertion because it omitted the required corrected time; the focused fixture rerun passed. Native Chinese inspection found untranslated “Add task” and “Last updated”; both were added, the locale test rerun, and the rebuilt native screen rechecked.

## Native evidence

Environment: Apple Silicon, macOS 27.0 (26A428). The disposable library was `/tmp/mira-tasks-native-73`. Launch with `--demo --verify-task-management --data-directory <disposable-directory>`; the flag seeds records through application services and a real journal-backed offline `task.change` proposal. Its notification port deliberately denies permission and never schedules real notifications. Restarting preserves manual changes and does not duplicate the proposal.

English/light was checked at 1100 × 760 and the 850 × 620 minimum; Chinese/dark at 850 × 620. Checked states and actions:

- Exact Inbox/workspace selection, active/all/cancelled filters, case-insensitive title/notes search and empty results.
- Manual title/notes, independent due date and one-time reminder, save, edit, start, complete, reopen and cancel. The final history showed six revisions with retained earlier content.
- Permission-required explanation, explicit permission request and scheduling retry. The denied synthetic response stays permission-required; saving never reports scheduling success.
- Pending proposal source quote, disabled acceptance before exact-time confirmation, successful acceptance after confirmation, empty pending list afterward and navigation to the original message.
- Persisted accepted task after app restart; compact list/detail navigation, native date controls, scrollable sheet, Escape cancellation and visible focus. Accessibility text exposes actions, task status, reminder status, source and revision disclosures.
- New-conversation draft retained after visiting Tasks and the source conversation. A separate 40-paragraph synthetic conversation kept its native scroll value `0.3947702462553948` before and after Tasks navigation, with Jump to latest still available.

Screenshots contain only synthetic records. Stage Manager returned thumbnails through the interaction capture, so full-window evidence was obtained through the screenshot skill and visually inspected:

- [English light, list and detail](evidence/task-management/english-light.png)
- [English light, minimum-window list](evidence/task-management/english-light-compact.png)
- [Chinese dark, minimum-window detail](evidence/task-management/chinese-dark-compact.png)
- [Chinese dark, edit sheet](evidence/task-management/chinese-dark-editor.png)

## Remaining boundaries

This increment does not requalify real OS permission prompts, notification delivery after full app exit, Focus mode, distribution signing, Intel, or a macOS 15 native runtime. Prior delivery evidence remains historical. Paused/resume, failure races, stale evidence and paging scale are covered by synthetic automated tests; native screenshots do not claim those platform outcomes. Full VoiceOver traversal, Increase Contrast and Reduce Transparency were not rerun; shared design-system treatments were retained. Live-model interpretation and wording were not evaluated.

Recurring/conditional reminders, EventKit/Apple Calendar/Reminders publishing, iOS and sync are outside this issue. Wider M3–M6 release gates remain tracked in [MVP](../MVP.md).
