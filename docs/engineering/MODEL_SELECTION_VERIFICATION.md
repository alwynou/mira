# Conversation model selection verification

Date: 2026-09-14. Scope: automatic conversation defaults, fixed/follow-last policy, and the provider-grouped composer model picker.

The later [compact-menu and model-information correction](MODEL_INFORMATION_VERIFICATION.md) replaces this initial popover presentation; the default-policy behavior below remains current.

## Behavior

- The first enabled canonical pool model on an active provider creates the missing global conversation binding in the same settings transaction. Activating a provider considers its enabled models in saved order. Existing bindings remain unchanged; memory extraction is never configured automatically.
- New conversations resolve the configured fixed model or the latest explicit conversation model choice. Explicit switches affect the current conversation; fixed defaults remain unchanged. The concrete route is committed with first-message admission or an existing session model-selection command.
- Follow-last preferences survive app restart, are scoped to the local library identity, and are host preferences rather than library archive or execution-authority data. An unavailable remembered route does not silently select another model.
- The composer displays the actual model name. Its native menu lists models under small provider headings and marks the current choice. The default-policy option lives in model settings.

## Automated evidence

Only affected test suites were run; no paid endpoints or personal conversations were used.

| Check | Result |
| --- | --- |
| `swift test --package-path Packages/MiraKit --filter SQLiteAgentModelSettingsTests` | 18 passed; automatic initialization, activation order, existing bindings, rollback, and related settings invariants |
| `MiraCompositionTests/ConversationModelChoiceTests` and `MiraCompositionTests/PurposeRoutingModelTests` | 6 passed; fixed/follow behavior, explicit journal selections, preference reload, disabled selection rejection, and settings save behavior |
| `MiraHostTests/LocalizationTests` | 5 passed |
| `python3 scripts/check_language_policy.py` | Passed, 2031 bilingual strings |
| `MiraUITests/ConversationFlowUITests/testModelSelectionPolicyEnglishLight` and `testModelSelectionGroupsChineseDark` | 2 passed using disposable synthetic libraries and offline demo providers |

Host result bundle: `.build/xcode/Logs/Test/Test-MiraHostTests-2026.09.14_20-05-07-+0800.xcresult`.
UI result bundle: `.build/xcode/Logs/Test/Test-MiraUI-2026.09.14_20-02-42-+0800.xcresult`.
Both Xcode test runs built the affected app/host targets successfully with signing disabled.

The native UI scenarios cover the 850-point conversation window, provider groups, selected checkmark, actual composer label, fixed-default isolation, follow-last new conversations, and English restart persistence followed by switching back to a fixed default. Settings changes use the actual selection and save controls. Default initialization occurs before settings subscriptions start, avoiding self-triggered reload writes.

## Native visual evidence

Screenshots were inspected for layout, model/provider grouping, current selection, and localized policy labels:

- [English/light grouped picker](evidence/2026-09-14-compact-model-menu-en.png)
- [Chinese/dark grouped picker](evidence/2026-09-14-compact-model-menu-zh.png)
- [English/light default settings](evidence/2026-09-14-model-default-en-light.png)
- [Chinese/dark default settings](evidence/2026-09-14-model-default-zh-dark.png)

## Limits

This verifies the current development machine, not a macOS 15 runtime. VoiceOver, increased contrast, and every keyboard-navigation path were not separately exercised for this change. Real provider response quality and unrelated transcript, recovery, memory, and task flows were not rerun.
