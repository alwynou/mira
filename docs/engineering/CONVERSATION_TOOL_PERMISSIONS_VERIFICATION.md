# Conversation tool permission scope verification

Date: 2026-09-28. Scope: [issue #69](https://github.com/alwynou/mira/issues/69). This corrects the shared-global composer behavior introduced by #67. The owning contract is [Bash and scoped tool permissions](../architecture/BASH_AND_TOOL_PERMISSIONS.md).

## Behavior and implementation

Settings and an unsent conversation edit the global default. First submission captures a separate conversation selection before admission can dispatch any tool. Later composer changes affect only that library/conversation pair. Pending admission remains conversation-scoped until reconciliation; definitive rejection removes the unused selection and restores draft scope. Existing conversations without saved consent use Ask, rather than inheriting a later elevation of the default. There is no schema migration or library deletion.

Runtime lookup uses the invocation's admitted session identity and its owning library, not the page currently selected in a window. Workgroup replacement preserves the injected reader. The option rows now accept a selection and action, allowing the same presentation to edit either scope. The menu labels its scope explicitly in English and Chinese; self-contained component previews cover both appearances.

## Automated evidence

Local host: Apple silicon, macOS 27.0, Xcode 27.0 (27A266a), Swift 6. Synthetic libraries, models and preference suites only; no paid endpoint or credentials.

- `ToolPermissionTests`: conversation/default isolation, library namespacing, idempotent capture, persistence, rejected-admission cleanup and unknown-value fallback. Existing generic-tool, memory deletion, Bash classification and approval tests remain covered.
- `ConversationModelTests`: first-send capture, unsent draft scope, definitive admission rejection, independent second conversation, later default changes, page switching/eviction, stored preferences and pending-admission reconciliation after workgroup replacement. The latter retains the local selection despite a changed default.
- `BashWorkflowTests`: a guarded conversation remains undispatched without an observer even after the global default changes to Full access; a different explicitly authorized conversation executes exactly once. The existing ten approval/cancellation/reopen scenarios pass, including unchanged pending approval after a level change.
- Initial combined run: 129 Swift Testing host tests in 19 suites passed; 14 composition test functions in three suites passed, including the six memory-deletion scenarios. The host XCTest divider test `MiraWindowShellTests.testInspectorPreservesWindowSidebarAndPresentationState` failed its native mouse-tracking assertion. Its isolated rerun failed identically; no assertion, production guard or required CI check was bypassed.
- Final focused rerun after adding admission-rejection and retry assertions: 13 test functions in `ConversationModelTests` and `BashWorkflowTests` passed. Two intermediate method-name filters selected zero Swift Testing tests; they are not counted as verification and were replaced by the successful suite-level run.
- Debug app build succeeded. Source and extracted-string language checks pass with 2366 bilingual strings. `xcodegen generate` left the project consistent; `git diff --check` passes.

All Xcode commands used `-project Mira.xcodeproj -configuration Debug -destination 'platform=macOS' -derivedDataPath .build/xcode -onlyUsePackageVersionsFromResolvedFile CODE_SIGNING_ALLOWED=NO`:

```sh
xcodebuild <common arguments> -scheme Mira -only-testing:MiraHostTests -only-testing:MiraCompositionTests/ConversationModelTests -only-testing:MiraCompositionTests/BashWorkflowTests -only-testing:MiraCompositionTests/MemoryDeletionTests test
xcodebuild <common arguments> -scheme MiraCompositionTests -only-testing:MiraCompositionTests/ConversationModelTests -only-testing:MiraCompositionTests/BashWorkflowTests test
xcodebuild <common arguments> -scheme Mira build
python3 scripts/check_language_policy.py
python3 scripts/check_language_policy.py --extracted-dir .build/xcode/Build/Intermediates.noindex/Mira.build/Debug/Mira.build
```

## Native evidence

Used `--demo --verify-bash-tool`, a disposable library and the separate demo permission domain. This local model can emit only the fixed synthetic command; it cannot use a provider endpoint or Keychain. Launch arguments selected English/light and Chinese/dark. Native accessibility state and full-window screenshots were inspected in the task.

- At the minimum conversation window size (850 × 620), English/light and Chinese/dark menus show translated scope headings, fully wrapped explanations, the current checkmark and all three options without obscuring the model/send controls after dismissal.
- An English draft changed the default from Ask to Automatic. First send captured Automatic and showed the fixed Bash approval. Changing that existing conversation to Full access left the pending approval intact. Denial produced the fixture's not-executed reply.
- A new draft and General settings still showed Automatic. After quitting and reopening in Chinese/dark, the draft retained Automatic and the existing conversation retained Full access. Changing the new draft to Ask left that conversation at Full access; Settings reflected Ask.
- English/light and Chinese/dark settings screenshots show the complete new-conversation default explanation and retained restriction note. Escape dismisses the popover. The demo default was returned to Ask; the user's production preference was not changed by UI verification.

## Limits

The unrelated local divider automation failure remains recorded above; required repository CI is the merge gate. No local macOS 15 runtime, live provider, full VoiceOver traversal, Increase Contrast/Reduce Transparency or simultaneous inspector compression qualification is claimed. The accessibility snapshot can report Automatic as selected alongside the actual selection; the screenshots show exactly one correct checkmark. This pre-existing accessibility representation remains unqualified rather than being treated as a verified VoiceOver result. Simultaneous multiwindow interaction was not manually exercised; shared preference ownership and retained-page/runtime tests cover the relevant data flow.
