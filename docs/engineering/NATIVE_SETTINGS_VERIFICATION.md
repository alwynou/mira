# Native settings verification

## Category icon clearance, 2026-09-21

Issue [#30](https://github.com/alwynou/mira/issues/30) bounds each category symbol independently of its colored well. The shared component aspect-fits the symbol into 14 × 14 pt and centers it inside the existing 20 × 20 pt well. The fixed-sidebar previews now use this production component for all five categories.

Native synthetic captures on macOS 27.0 (26A428), Apple Silicon, show visible clearance for all five symbols, including the wide cloud and brain. The General row is selected; the other rows are unselected. English/light and Chinese/dark screenshots were inspected at their original 2× resolution:

- [English/light](evidence/settings-icon-insets/en-light.png)
- [Chinese/dark](evidence/settings-icon-insets/zh-dark.png)

The existing `SettingsLayoutUITests` built successfully but both cases failed before reaching category traversal: the drag-based resize left the window at 840 pt instead of 760 pt, and the expected Toolbar accessibility element was absent on this host. Result: `.build/settings-icon-insets.xcresult`; log: `/tmp/mira-settings-icon-tests.log`. These failures are recorded, not suppressed or represented as passing. The tests and window code were left unchanged. Minimum-size verification and the rest of these automated flows remain unverified for this run.

The standalone Debug build passed with the documented `Mira` scheme, locked package versions and `CODE_SIGNING_ALLOWED=NO`; log: `/tmp/mira-settings-icon-build.log`. Token export and `git diff --check` also passed.

A separate native accessibility check against `/tmp/mira-settings-icon-qa-20260921`, launched with `--demo`, confirmed that General, Providers, Models, Memory and Data & Privacy remain named, selectable rows and update the selected state and page title. No provider requests or real credentials were used. The change preserves native selection and icon-label spacing. Active accent selection, minimum-size rendering, macOS 15 runtime and VoiceOver remain unverified for this change.

Date: 2026-09-12. Host: macOS 26.6.2 (25G83), Apple Silicon. Deployment target: macOS 15. This record supersedes the [same-window settings evidence](SETTINGS_LAYOUT_VERIFICATION.md). Product behavior and reference measurements belong to [Settings design](../product/SETTINGS_DESIGN.md).

## Current implementation

Settings uses a singleton SwiftUI `Window` scene and `NavigationSplitView`, with a fixed 200 pt sidebar and no sidebar toggle. The scene uses the associated window-manager role, is suppressed at launch and does not restore across app launches. Conversation hosts remain mounted. One app-owned `SettingsModel` retains category and preference drafts; typed `OpenWindowAction` values cross the conversation's AppKit hosting boundary.

Grouped Forms provide surfaces, controls and scrolling. Shared sections insert measured separators because native grouped Form ignored `listRowSeparatorTint` on this host. Fields use center-aligned labels; Save/Discard stays within its configuration group. On macOS 26, `safeAreaBar` and a soft scroll-edge effect keep the category title legible over scrolling content. Native chrome determines its height. Earlier systems retain the native title and clipped content.

## Automated acceptance

The commit preparation removed obsolete window state, passthrough text-field styling and reference-only Swift constants. Reference observations remain in the product document; the export contains runtime tokens. One-off screenshot analysis and superseded implementation notes were removed.

- `swift test --package-path Packages/MiraKit`: 389 tests in 43 suites passed. Log: `/tmp/mira-commit-package-tests.log`.
- Debug app build and full host tests passed using `xcodebuild -project Mira.xcodeproj -scheme Mira -configuration Debug -destination 'platform=macOS' -derivedDataPath .build/xcode -onlyUsePackageVersionsFromResolvedFile CODE_SIGNING_ALLOWED=NO -only-testing:MiraHostTests build test`. There were 57 Swift Testing cases and 17 XCTest cases, with one opt-in live evaluation skipped and no failures. Result: `.build/xcode/Logs/Test/Run-Mira-2026.09.12_12-04-41-+0800.xcresult`; log: `/tmp/mira-commit-host-tests-final.log`.
- Both `SettingsLayoutUITests` passed in 79.614 seconds, using the same build flags with `-scheme MiraUI -only-testing:MiraUITests/SettingsLayoutUITests test`. Result: `.build/xcode/Logs/Test/Test-MiraUI-2026.09.12_12-03-02-+0800.xcresult`; log: `/tmp/mira-commit-ui-tests-final.log`.
- Token export, the 1,179-string language policy check, changed-document relative links and whitespace checks passed. `xcodegen generate` left the generated project unchanged.

The UI suite uses isolated offline libraries and process-local English/light or Chinese/dark preferences. It checks independent windows, unchanged conversation geometry and composer draft, singleton reuse, Picker Escape dismissal, all five categories, provider field access, memory draft retention and reopening settings with no conversation window. No provider endpoint or real credential is used.

The initial rerun exposed the previous shell's obsolete 600 pt outer-frame limit and an input-method popup interrupting a redundant Tab event. The test now measures content height below the native toolbar and closes directly after verifying the edited value. The final run above passed both languages.

## Native visual evidence

Fourteen screenshots and their attachment mapping are retained locally in `.build/commit-settings-qa/final/`; `screenshots.json` maps category names to files. Minimum-size General, Providers, Models, Memory and Data & Privacy pages were visually reviewed in both languages/appearances. Text wraps without horizontal clipping, controls remain reachable, and grouped surfaces and field alignment are intact. Scrolled provider captures show separators between individual model rows, one native scrollbar and content fading beneath a clear title.

The minimum outer frame is 760 × 612 pt on this host, comprising 560 pt of content height plus a 52 pt native toolbar. The updated UI assertion measures both, instead of applying the previous AppKit shell's outer-frame limit. Native sidebar content remains 200 pt, with the disabled divider at 208 pt including the outer rim.

Earlier native checks on 2026-09-11 verified immediate language and appearance changes, return to Follow System, and associated Stage Manager grouping with the conversation still full size. Evidence: `.build/native-settings-qa/swiftui-window-final-captures/`. Those checks used a disposable demo library and restored Simplified Chinese and Follow System afterward.

Separator pixel evidence from 2026-09-11 remains in `.build/native-settings-qa/separator-final-captures/separator-pixels.json`: four sampled lines in 2× provider captures were exactly two pixels high and uniformly `#EBEBEB` / `#3A3C3C`, against `#F7F7F7` / `#303232` surfaces. Raw and profile-converted neutral samples agreed. The commit cleanup preserves those runtime sRGB values; the current screenshots were visually reviewed without repeating the pixel measurement.

## Limits

macOS 15 runtime, physical trackpad behavior, fullscreen/multiple displays, VoiceOver, Reduce Transparency and Increase Contrast remain unverified for the final scene. Runtime evidence on macOS 26 does not close those checks. End-to-end streaming/reading-position behavior and credential cleanup on close were not re-exercised after the scene migration. Live provider connectivity and stored-key interactions were not tested with real credentials. Native material and accent rendering remain system-owned.

## Provider navigation and scrolling, 2026-09-12

The final follow-up adds continuous borderless provider choices, selected-title popup sizing, leading field content, populated native secure fields, inline test feedback and model actions in the section header. Provider model rows use a shared lazy scroll surface and cached adaptive layout. Visited pages retain selection, drafts and scroll positions until settings closes; an active library-maintenance operation retains its owner.

English/light and Chinese/dark native UI runs pass at minimum window size, including padded provider clicks, repeated switching, synthetic key retention, scrolling, category changes and close/reopen reset. Synthetic native-field and presentation tests verify saved/replacement values and unchanged-key reuse without credential rotation. Final hover screenshots were reviewed. Detailed measurements, result bundles and remaining platform checks are recorded in [Provider settings responsiveness](PROVIDER_SETTINGS_PERFORMANCE.md).
