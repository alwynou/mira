# Settings layout verification

## Current behavior

Settings switches the current main window into settings mode. One native AppKit split shell remains in place; SwiftUI hosts render the settings sidebar and detail page without opening a second window. The settings detail has no history/title strip, and native corners, traffic-light placement, sidebar material, and sidebar width are shared with conversations.

All five category pages begin with the shared `MiraSettingsHeader`, using a 20 pt semibold category title and a concise 12 pt secondary description. The header follows existing page gutters and spacing, exposes the title as an accessibility heading, and resolves both English and Simplified Chinese copy through the string catalog. Providers retains its Add Provider action beside the header; provider detail screens retain their name and endpoint.

The sidebar provides Back to Mira followed by five categories, without a Settings heading. Settings always reveals the sidebar and disables collapse through divider gestures or sidebar commands; the toolbar has no sidebar toggle or return button. Returning restores the conversation's previous sidebar visibility. Providers and Models no longer show a persistent demo-mode footer; operation status and error feedback remain available. App menu and Command-comma use the focused window's `WindowNavigation`. Conversation observers and runtime executions continue while settings is visible. Composer text and route choice remain in the conversation model; reading intent and a numeric restoration target live in the window presentation model. The mounted transcript keeps its `ScrollPosition` binding local, restores one deferred offset after Markdown layout can accommodate it, and lets explicit scrolling override the pending restoration.

Only the visible settings category is mounted. `MemorySettingsModel` retains preference drafts, original policy revision, save/reload operations, and generation guards. `DataSettingsModel` retains diagnostics and maintenance progress. Page observation is canceled on disappearance while explicitly started operations can finish. Provider editors retain explicit Save, revision conflict checks, and clearing of secret input on disappearance. No schema, provider protocol, appearance preference, or new model purpose is introduced.

## Verification

Host: macOS 26.6.2, macOS 26.5 SDK, Debug build. Checks used isolated offline demo data and synthetic content; no credentials or paid provider requests were used.

- The final Debug build and `xcodegen generate` passed. Language policy passed with 1,127 bilingual strings. `MiraHostTests` passed 53 Swift Testing cases in 11 suites and 8 XCTest cases, including one intentionally skipped live-provider evaluation.
- Earlier settings-content checks passed in Chinese/dark and English/light. They covered provider search/detail, model menu/pool, memory/data navigation, unmounted inactive pages, composer preservation, and unsaved memory-budget preservation across categories and settings exits. They preceded final AppKit shell adoption and do not establish current window-chrome or appearance acceptance.
- The earlier `testReadingPositionAcrossSettings` passed in 26.516 seconds. It entered settings during an offline reply, returned, waited for completion, scrolled into history, and verified the native scroll-bar value after another settings round trip within 0.03.
- Deterministic reading-state checks cover teardown callbacks, waiting for sufficient Markdown layout, consuming a restoration target once, explicit user-scroll override, and returning a following reader to the latest content. The retained offset includes the scroll view's top inset and is frozen before switching to settings.

The shared root declares an 850 × 620 pt minimum. Final AppKit mode-switch, inspector preference, draft, and native-command checks are recorded in [window-shell verification](APPKIT_WINDOW_SHELL.md).

The post-cleanup English settings UI rerun started but did not finish: another application window interrupted automation, the run was stopped, and test-log finalization reported an Xcode error. No pass is claimed for that rerun. Logs are under `.build/ui-commit/ui-verification.log`; no second appearance matrix was attempted.

## Settings simplification (2026-09-08)

The current Debug build and all three `SettingsLayoutUITests` passed on macOS 26.6.2 using isolated offline libraries: Chinese/dark navigation (67.598 seconds), English/light navigation (61.344 seconds), and reading-position restoration (24.552 seconds). This completes the previously interrupted settings rerun above.

- Both navigation runs verify that the sidebar heading and toolbar buttons are absent, the category list follows Back to Mira without the old heading space, and Providers/Models have no demo-only footer. Provider detail/search, all five categories, disabled demo Save, unsaved memory settings, composer preservation, and repeated settings entry remain usable.
- Entering settings from a collapsed conversation reveals the category sidebar; returning restores the collapsed conversation and its working toggle. The native shell test additionally verifies that settings rejects the sidebar command and divider collapse, retains inspector preferences, and preserves the no-collapse-on-window-resize policy after return.
- Screenshots of provider detail and model defaults were visually inspected in English/light and Chinese/dark. Chinese/dark was explicitly resized to the 850 × 620 pt content minimum. Native window controls, the full-height sidebar material, category labels, and content padding remain intact; the removed footer leaves no reserved strip. Long model pages scroll normally below the viewport.
- `swift test --package-path Packages/MiraKit` passed 389 tests in 43 suites. `MiraHostTests` passed 53 Swift Testing cases and 8 XCTest cases with one expected opt-in live-provider skip. Language policy passed with 1,127 bilingual strings; `git diff --check` passed. No token or target changes required export or project regeneration.

Local evidence is under `.build/settings-sidebar/`: `build-host.log`, `package.log`, `ui.log`, `settings-ui.xcresult`, and six exported screenshots with their mapping in `captures/manifest.json`. The tests remove their temporary libraries on termination. No credentials or network requests were used.

## Category headers (2026-09-08)

The Debug app build and `MiraHostTests` passed after adding the shared header and five bilingual descriptions: 53 Swift Testing cases plus 8 XCTest cases with the expected opt-in live-provider skip. Language policy passed with 1,132 bilingual strings. `git diff --check` passed. Tokens and targets did not change, so neither token export nor project regeneration was needed.

Both existing navigation workflows passed again in Chinese/dark and English/light (2 tests, 133.030 seconds total). They retained provider search/detail, model selection, all category navigation, unsaved memory-budget drafts, conversation drafts, fixed-sidebar entry, and return-state checks. The Chinese/dark run explicitly resized to the 850 × 620 pt content minimum.

Ten category-page screenshots were visually inspected, covering General, Providers, Models, Memory, and Data & Privacy in both runs. Each page starts with its category title and a smaller, single-line localized description. Text is unclipped, header placement and spacing are consistent, and the provider action remains aligned alongside its title. English/light and Chinese/dark self-contained component previews were updated too.

Evidence is under `.build/settings-headers/`: `build-host.log`, `ui.log`, `settings-ui.xcresult`, and `captures/manifest.json` mapping the 12 exported screenshots (ten category pages plus two provider details). Tests used isolated offline libraries and removed them afterward. Core/package behavior did not change; the earlier package run and reading-position check above were not repeated for this visual increment. The platform and accessibility limitations below still apply.

## Limits

The later 48 pt page-top adjustment rebuilt successfully with the Debug build command; its log is `.build/settings-top-inset/build.log`. The shared page now replaces the native top safe-area offset with `Layout.settingsPageTopInset = 48` measured from the window top. The token export and narrow component previews were updated. Tests and the appearance matrix were intentionally not rerun at the user's request; earlier test results above predate this spacing change.

The subsequent Back to Mira adjustment reuses `MiraSidebarRow` and `MiraRowButtonStyle` for the category-row hover/pressed background and uses the same 48 pt top inset for the settings sidebar. Debug rebuilding succeeded; the log is `.build/settings-return-row/build.log`. Automated tests and manual interaction checks were skipped at the user's request, with the rebuilt settings page reopened for their review.

Back to Mira's label and arrow were then changed to the shared `secondaryText` color. Debug rebuilding succeeded (`.build/settings-return-color/build.log`); tests and manual interaction checks remained skipped for user review.

On 2026-09-09, settings spacing changed to a 24 pt sidebar top inset and a 64 pt page top inset, with the 8 pt title/subtitle gap retained and a 32 pt gap below the subtitle. Later content groups retain their 24 pt spacing. The token export, previews, and design contract were updated. Debug rebuilding succeeded (`.build/settings-spacing/build.log`); automated and manual checks remained skipped at the user's request, and the rebuilt app was reopened for review. This supersedes the earlier 48 pt spacing values above.

The sidebar was then returned to native top safe-area handling: Back to Mira starts immediately below the titlebar/traffic-light region with no extra top padding. The fixed sidebar-top token was removed and its export regenerated; the detail page remains at 64 pt. Debug rebuilding succeeded (`.build/settings-native-top/build.log`). Tests and manual interaction checks remained skipped for user review.

Current deterministic state checks, native shell checks, and the complete settings UI rerun passed. The appearance evidence covers English/light and Chinese/dark, not every language/appearance combination. The host runs macOS 26.6.2; building for macOS 15 does not verify macOS 15 runtime behavior. Real provider saves, activation, capability probes, destructive data operations, full VoiceOver/accessibility preference audits, and a controlled Release sidebar-animation comparison remain unverified. Unmounting inactive pages reduces retained layout work but does not establish a sidebar-animation performance improvement.
