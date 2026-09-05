# Language and localization

Mira's implementation language is English. Identifiers, comments, internal diagnostics, tool descriptions, and built-in model prompts use English. The interface supports English (`en`) and Simplified Chinese (`zh-CN`, stored in Apple's `zh-Hans` resource locale).

## Presentation and preferences

Settings → General → Display Language switches Mira-owned views immediately, including open windows and sheets. The selection is persisted in the app's `app.language` preference. On first launch, Mira chooses the first supported preferred system language, falling back to English. Unsupported or corrupt saved values use the same fallback. macOS controls the language of system-owned menu items and file dialogs; the app does not change system preferences.

The app injects the selected locale into each scene without recreating conversation models, cancelling requests, clearing drafts, or changing selection. Pass the locale explicitly into native sheets and inspector content; macOS presentation boundaries must not fall back to the process language. Native SwiftUI literal labels use the English string catalog keys. Dynamic app-owned messages use `L10n` with the view's current locale; never resolve and retain a translated message in business state.

## Resource ownership

- `Apps/MiraMac/Resources/Localizable.xcstrings`: English source strings and complete `en` / `zh-Hans` translations, including accessibility labels and app-owned validation messages.
- `Apps/MiraMac/Localization`: language selection and resource lookup; Core, Data, and Providers remain independent of UI preferences.

Use whole messages with localized interpolation or typed format placeholders. Never concatenate translated sentence fragments. Preserve placeholders in translations. Keep dates and numbers locale-aware; protocol IDs and raw JSON remain verbatim.

The static case-label coverage scan can identify symbol or protocol identifiers as display copy. For such case-returned identifiers, add an inline `// i18n-verbatim:` explanation; this exempts only that line from case-label catalog coverage, not the English source policy or explicit localization lookups.

## Content boundaries

User messages, model replies, workspace names/backgrounds, conversation titles derived from user input, tool observations, and request snapshots are content, not localization keys. Changing display language must not translate or rewrite them. An empty conversation title represents an untitled conversation; the UI supplies its localized placeholder. Empty titles are stored directly. The first user message supplies the title; subsequent messages do not rename it. No historical title adapter is maintained.

Built-in prompts stay English. The conversational prompt instructs the model to follow an explicit user language request, otherwise match the user's language. Synthetic capability probes retain their exact protocol instructions. Neither path depends on the UI locale.

Non-English source exceptions require an English explanation and a narrow allowlist: translation resources, original third-party notices, Unicode or language-specific test fixtures. Existing product and design documents are not translated as part of implementation cleanup.

The vendored SwiftStreamingMarkdown source retains its upstream identity and license. Its small locale patch makes code-copy controls and list/table accessibility labels use the current SwiftUI locale instead of the process language. See its `UPSTREAM.md` for the exact scope; original third-party source and fixtures are excluded from Mira's first-party source-language scan. Third-party locale tests are included in Mira's hostless Xcode test target so the actual compiled string catalogs are tested.

## Verification

Run `python3 scripts/check_language_policy.py`, the MiraKit package suite, and `xcodebuild ... -scheme Mira test` for the hostless `MiraHostTests` target. Tests use isolated preferences and bundled localization resources. Manually verify switching in Settings, a conversation with user-authored content and an unsent draft, an editor sheet, an error, and after relaunch. Do not use real credentials or paid endpoints for localization checks.

## Early development policy

Backward compatibility is not required in this phase. Change contracts and schemas directly instead of maintaining historical formats. This increment uses a fresh version 3 library, rejects older development libraries without deleting them, and restores only current-schema backups. There are no old-language error aliases or text-based audit-message parsers. Context omissions are typed records localized only in the inspector. Request snapshots are stored only on model attempts, and tool capability uses an explicit `unknown` initial state.
