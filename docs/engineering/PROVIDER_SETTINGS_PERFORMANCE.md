# Provider settings responsiveness

Date: 2026-09-12. Host: Apple Silicon, macOS 26.6.2. Debug build; deployment target remains macOS 15.

## Implementation and boundaries

- Providers share a continuous borderless rail with explicit padded hit areas and distinct hover/selection backgrounds. The selected detail editor, compact native menus and leading text fields retain native control semantics.
- The provider page uses one ScrollView/LazyVStack. Collection sections preserve their typed ForEach and construct model rows lazily. The scrolling header owns connection editors above the lazy rows. Cached adaptive layout reflows one model name/identifier pair without duplicate candidate hierarchies.
- Visited settings pages retain their hierarchy, scroll position, selected providers and drafts for the open window session. Hidden page observations pause. Closing resets transient state and cancels provider requests; active library maintenance retains its owner and duplicate-action guard.
- Saved and replacement keys populate the same native SecureField. Keychain remains the only persistent credential store. Unchanged values are reused without rotation, and deactivation preserves unsaved endpoint/key edits. Closing releases editor key values.
- The immutable catalog indexes normalized protocol/endpoint keys and model IDs without changing exact matching, regional metadata or catalog order. Providers reads configuration without enumerating routing scopes; Models still loads them. Identical editor inputs reuse prepared candidates. Test/save/activation/send validation remains unchanged.
- Native NSMenu items survive selection-only updates. Popup width follows the selected title, with explicit caps for long identifiers. Test feedback stays with its control, model actions sit in the section header, and successful discovery adds no footer.

## Measured work

The production shared page/section fixture at 552 × 560 pt realizes **7 rows** at initial layout for both 40-row and 1,000-row model collections. Increasing collection size therefore does not trigger full offscreen layout. Ten fresh OpenRouter editor preparations took **5.99–8.97 ms**; unchanged updates preserve candidate route identities with full eligibility validation enabled.

The scrolling fixture uses the production model row with 100 synthetic varied names/identifiers, context/pricing, capability icons and native switches. A 760 × 560 pt native window performs 504 steps of 30 pt down/up scrolling and immediate layout. Both versions realize 98 rows over the round trip with monotonic offsets.

| Production row layout | P95 layout (ms) | Maximum layout (ms) |
| --- | ---: | ---: |
| Duplicate candidate hierarchies | 11.70 | 15.65 |
| Cached adaptive layout | 7.83 | 12.17 |
| Adaptive layout, full host suite repeat | 8.29 | 11.43 |

These are synchronous native layout measurements, not display FPS. Paired P95 improved about 33%; the suite repeat remained about 29% below baseline. Logs: `/tmp/mira-actual-row-baseline.log`, `/tmp/mira-actual-row-optimized.log`, `/tmp/mira-session-host-accepted.log`.

Earlier opening/switching acceptance, before the scrolling/session follow-up, measured the following action-to-initial-layout intervals. They establish the native-menu optimization's result at that stage, not final hardware input latency:

| Interval | Samples | Range (ms) | Median (ms) |
| --- | ---: | ---: | ---: |
| Enter Providers | 2 | 232.72–237.38 | 235.05 |
| First OpenRouter selection | 2 | 175.77–176.56 | 176.17 |
| Consecutive DeepSeek/OpenRouter switches | 12 | 42.53–96.28 | 80.92 |

The same UI script measured 443.57–449.39 ms for first OpenRouter selection before replacing the SwiftUI option hierarchy with native menu items. Earlier accepted stdout is in `.build/provider-performance-qa/accepted-diagnostics`. Debug-only `--demo --profile-provider-settings` records phase and duration from the navigation action to the editor's first `onAppear` callback; it records no configuration or credentials.

A pre-layout-change Instruments trace, `.build/provider-scroll-profile.trace`, helped identify repeated sizing. Most string-table CPU came from XCTest accessibility snapshots and must not be attributed to ordinary scrolling. Excluding those stacks in an 11-second exercise interval left 1.39 seconds of sampled main-thread CPU, including 234.6 ms in layout sizing and 125.2 ms in size-fitting layout. Analysis: `.build/provider-scroll-profile-analysis.md`.

## Acceptance and evidence

- Package: 389 tests in 43 suites passed; `/tmp/mira-provider-performance-package-final.log`.
- The final combined host suite passed 70 Swift Testing cases and 20 XCTest cases (one opt-in live evaluation skipped). Result: `.build/xcode/Logs/Test/Test-Mira-2026.09.12_15-18-12-+0800.xcresult`. This includes the subsequent conversation tests documented in [Conversation switching](CONVERSATION_SWITCHING.md).
- Native controls cover selected-title sizing, width caps, reselection, locale changes, unchanged 400-option menu identity and synthetic stored/replacement secure values. Provider model tests cover saved-key reuse, draft testing, cancellation, conflict boundaries and deactivation preserving drafts.
- Both settings UI paths pass with disposable demo libraries, English/light and Chinese/dark, at minimum window size. They exercise hover, padded provider clicks, selected endpoints, repeated switches, synthetic key retention, category/scroll retention, memory drafts and close/reopen reset. No provider test/save/activation or paid endpoint is invoked.
- Final settings UI result: `.build/xcode/Logs/Test/Test-MiraUI-2026.09.12_14-16-38-+0800.xcresult` (2 passed); log `/tmp/mira-session-ui-final.log`; 20 screenshot attachments in `.build/provider-session-qa/final/manifest.json`. Reviewed captures show compact selectors, leading fields, masked synthetic values, borderless choices and wrapping. Both final hover captures distinguish neutral hover from selected accent and group backgrounds.
- The app build after clearing stale maintenance results on close passed; `/tmp/mira-session-build-final.log`. An in-flight operation can still deliver its new result. Language policy passes for 1,179 bilingual strings; design tokens and the Xcode project were regenerated; whitespace checks pass.

Reproduction commands:

```sh
swift test --package-path Packages/MiraKit
xcodebuild -project Mira.xcodeproj -scheme Mira -configuration Debug -destination 'platform=macOS' -derivedDataPath .build/xcode -onlyUsePackageVersionsFromResolvedFile CODE_SIGNING_ALLOWED=NO -only-testing:MiraHostTests build test
xcodebuild -project Mira.xcodeproj -scheme MiraUI -configuration Debug -destination 'platform=macOS' -derivedDataPath .build/xcode -onlyUsePackageVersionsFromResolvedFile CODE_SIGNING_ALLOWED=NO -only-testing:MiraUITests/SettingsLayoutUITests test
python3 scripts/check_language_policy.py
```

## Limits

The fixtures establish bounded layout work and native interaction behavior on this host. They do not establish display-frame rate, worst-case hitches, physical trackpad behavior, real Keychain latency or responsiveness under live conversation streaming. macOS 15 runtime, VoiceOver, Reduce Transparency and Increase Contrast remain separate platform checks. No live provider endpoint or real credential was used by these tests.
