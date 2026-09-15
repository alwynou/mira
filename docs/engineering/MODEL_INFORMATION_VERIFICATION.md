# Compact model menu and model information

Date: 2026-09-14. Scope: composer menu density, provider price presentation, and capability badge precedence.

## Findings and changes

The custom 300-point popover inherited sidebar font sizes, row heights, and spacing. It is replaced with a native `Menu` containing the shared `MiraModelPickerItems`, provider section headings, and checked model items. Native sizing, menu typography, keyboard handling, and dismissal replace the custom panel. The trigger retains the actual model name and has no extra indicator or popover arrow.

The settings price line reused the estimator's flat `ModelPricing`. The models.dev normalizer intentionally omits that tariff when reasoning-specific rates are present; DeepSeek therefore showed no prices. Its public catalog also omits peak/off-peak billing, and the observed Pro rates lag the official price table. `ModelPublishedPricing` now supplies a dated, display-only official range for exact DeepSeek model IDs and endpoints. The settings line shows input/output USD per million token ranges, labels their off-peak–peak order, links the source and check date, and exposes the UTC schedule in help text. Custom gateways and other selected invocation endpoints do not inherit official rates. No persisted schema or historical execution snapshot is changed. Unsupported time-dependent execution estimates remain unknown.

Saved-model badges previously read Vision and Thinking directly from catalog booleans, and OR-ed catalog Tools with the effective value. `ModelCapabilitySummary` now resolves saved modality facts and tool/thinking declarations with the core's source and invocation precedence. Explicit text-only or false declarations override catalog hints; conflicting facts fail closed. Catalog-only rows remain advisory.

## Source check

The [official DeepSeek pricing table](https://api-docs.deepseek.com/quick_start/pricing/) was checked on 2026-09-14. It identifies `deepseek-flash` as V4.1 Flash with vision, and states that legacy V4 Flash IDs route to that model. V4 Pro does not support vision. The bundled models.dev modality lists already agree with this distinction; removing Vision from Flash would be incorrect. The published tariff reference must be rechecked when prices change, and is visibly dated rather than presented as a live provider response.

## Focused evidence

- `deepSeekPublishedPricing`: exact model aliases, input/output/cache ranges, provenance, unknown models, custom gateways, and selected endpoint boundaries.
- `ModelCapabilitySummaryTests`: text-only and negative capability overrides, invocation scope, conflicts, and absent modality facts. These three focused package tests passed together. An earlier catalog/capability run passed 12 tests.
- Native model selection in English/light and Chinese/dark: 2 passed, including provider groups, checkmarks, actual model label, fixed/follow behavior and restart persistence.
- Native compact-menu screenshots in English/light and Chinese/dark: 2 passed at the 850-point conversation width. The evidence images crop the full-screen capture to the synthetic app and menu because native menus extend beyond the window.
- Native provider information: English/light and Chinese/dark screenshots use a disabled, credential-free DeepSeek connection. No discovery or model request is sent. The scrolled English screen displays all four models, their price ranges, and Pro without a Vision badge. An initial Chinese follow-up could not open the settings window; the targeted rerun passed using the native Settings keyboard shortcut.
- `MiraHostTests/LocalizationTests`: 5 passed. `scripts/check_language_policy.py`: 2037 bilingual strings passed.

Result bundles:

- Menu behavior: `.build/xcode/Logs/Test/Test-MiraUI-2026.09.14_20-20-17-+0800.xcresult`
- Complete menu captures: `.build/xcode/Logs/Test/Test-MiraUI-2026.09.14_20-23-41-+0800.xcresult`
- Initial provider screens: `.build/xcode/Logs/Test/Test-MiraUI-2026.09.14_20-22-44-+0800.xcresult`
- Scrolled English provider screen: `.build/xcode/Logs/Test/Test-MiraUI-2026.09.14_20-24-44-+0800.xcresult`
- Scrolled Chinese provider screen: `.build/xcode/Logs/Test/Test-MiraUI-2026.09.14_20-26-55-+0800.xcresult`
- Localization: `.build/xcode/Logs/Test/Test-MiraHostTests-2026.09.14_20-26-02-+0800.xcresult`

Visual evidence:

- [Compact English menu](evidence/2026-09-14-compact-model-menu-en.png)
- [Compact Chinese menu](evidence/2026-09-14-compact-model-menu-zh.png)
- [English provider model information](evidence/2026-09-14-model-information-en.png)
- [Chinese provider model information](evidence/2026-09-14-model-information-zh.png)

## Remaining limits

No live capability probe, paid generation, general billing-engine expansion, or unrelated conversation/knowledge/memory/task suite was required. Saved-fact precedence is covered by pure regression tests; the native provider screenshots cover catalog presentation. VoiceOver and every keyboard path were not independently exercised, and this is not a macOS 15 runtime certification.
