# Bash and global tool permissions verification

Date: 2026-09-28. Scope: [issue #67](https://github.com/alwynou/mira/issues/67), including the user's clarification that the permission selector governs all risky tools and belongs in both General settings and the composer's lower-left corner. Contract: [Bash and tool permissions](../architecture/BASH_AND_TOOL_PERMISSIONS.md).

## Automated evidence

Local environment: Apple silicon, macOS 27.0, Xcode 27.0 (27A266a), Swift 6. Production deployment remains macOS 15+. All command fixtures, libraries, routes and preferences were synthetic and temporary; no paid provider endpoint or credentials were used.

- `MacBashRunnerTests`: nine tests cover separate stdout/stderr, cwd, nonzero exit, stdin EOF, controlled environment keys, large concurrent output, invalid UTF-8, bounded JSON, timeout, cancellation, cancellation before launch, background pipe holders, child cleanup and invalid input.
- `ToolPermissionTests`: five test functions, including 34 uncertain-syntax cases, cover all three modes, persistence, unknown stored values, generic non-Bash read/write capabilities, memory deletion, routine memory/task behavior, executable pinning, canonical stability, option/operator/expansion/PATH bypasses and oversized reviews.
- `BashWorkflowTests`: ten runtime scenarios cover default approval, denial, absent observer, pending cancellation, running cancellation, library close, Full access without an observer, automatic read-only execution without an observer, automatic-mode review of a write, and switching levels during a pending review. Reopen preserves settlement without executing the command again.
- `MemoryDeletionTests`: six scenarios exercise actual global approval for a non-Bash local-write tool, exact target review, denial without deletion, successful deletion, stale target failure and interrupted maintenance/reopen behavior. Existing Task execution and reopen also pass.
- Complete `MiraHostTests` hostless target: 128 tests in 19 suites passed. Focused composition rerun: three parameterized test functions (17 cases) in three suites passed. The first combined acceptance run had one test-only cwd assertion mismatch between macOS `/var` and `/private/var`; the assertion now uses `realpath` and the focused rerun passes. No production guard was relaxed.
- Debug app build succeeded. `xcodegen generate` regenerated the checked-in project. Source and extracted-string language checks pass with 2361 bilingual strings. `git diff --check` passes.

Commands (all Xcode invocations use `-project Mira.xcodeproj -configuration Debug -destination 'platform=macOS' -derivedDataPath .build/xcode -onlyUsePackageVersionsFromResolvedFile CODE_SIGNING_ALLOWED=NO`):

```sh
xcodebuild <common arguments> -scheme Mira -only-testing:MiraHostTests -only-testing:MiraCompositionTests/BashWorkflowTests -only-testing:MiraCompositionTests/MemoryDeletionTests -only-testing:MiraCompositionTests/LibraryExecutionTests test
xcodebuild <common arguments> -scheme MiraCompositionTests -only-testing:MiraCompositionTests/BashWorkflowTests -only-testing:MiraCompositionTests/MemoryDeletionTests -only-testing:MiraCompositionTests/LibraryExecutionTests test
xcodebuild <common arguments> -scheme Mira build
python3 scripts/check_language_policy.py
python3 scripts/check_language_policy.py --extracted-dir .build/xcode/Build/Intermediates.noindex/Mira.build/Debug/Mira.build
```

## Native evidence

Used explicit `--demo --verify-bash-tool`, a disposable library, and the separate demo permission preference domain. The local model emits a fixed printf/pwd command and a reply determined by the actual settled observation. It cannot use Keychain or a provider endpoint. Appearance/language overrides were launch arguments, not changes to the user's preferences.

- English/light and Chinese/dark: all three translated options, explanations, selected checkmark and current composer label are present. General settings and composer selections update each other. A new conversation inherits the choice; quitting and reopening preserves Full access. The demo preference was restored to Ask afterwards.
- Default Ask shows exact command, cwd and timeout. Deny yields the fixture's not-executed reply. A new Full access conversation completes the real synthetic command without a review panel.
- The 850 × 620 minimum conversation frame retains both permission and model/send controls. Screenshots cover both composer appearances and Chinese/dark settings. English settings inspection found a truncated note; the final build adds vertical fixed sizing to wrap both notes. The final English settings capture was unavailable, so that last pixel check remains unqualified.
- Initial native inspection found the popover did not inherit the app's selected locale; the popover now explicitly receives locale and color scheme. Bilingual accessibility inspection confirms the corrected labels. Escape closes the popover.
- Computer-use captures intermittently returned Stage Manager thumbnails; OS window captures supplied the full-size evidence below. A separate popover-window capture was blank and is not retained as visual proof. Popover interaction/translation is verified by native accessibility state; exact dark popover pixels, full VoiceOver traversal, Increased Contrast/Reduce Transparency and simultaneous inspector compression remain unqualified.

| Appearance | Conversation | Settings |
| --- | --- | --- |
| English/light | [Composer](evidence/tool-permissions/en-light-composer.png) | Native interaction/AX verified; final capture unavailable |
| Chinese/dark | [Composer](evidence/tool-permissions/zh-dark-composer.png) | [Settings](evidence/tool-permissions/zh-dark-settings.png) |

## Limits

No macOS 15 runtime or live-provider behavior was exercised locally. Required repository CI remains the merge gate. The recognizer is intentionally conservative, not a general shell-risk analyzer. Full access does not create filesystem confinement; escaped descendants and abrupt host death are outside process-group cleanup guarantees. Ordinary domain privacy and tool-specific constraints remain independent of the chosen level. This increment does not claim broad agent safety, interactive terminal support or automatic crash replay.
