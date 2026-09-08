# Settings layout verification

## Current behavior

Settings switches the current main window into settings mode. One native AppKit split shell remains in place; SwiftUI hosts render the settings sidebar and detail page without opening a second window. The settings detail has no history/title strip, and native corners, traffic-light placement, sidebar material, and sidebar width are shared with conversations.

The sidebar provides Back to Mira and five categories. When collapsed, the native toolbar exposes a return action. App menu and Command-comma use the focused window's `WindowNavigation`. Conversation observers and runtime executions continue while settings is visible. Composer text and route choice remain in the conversation model; reading intent and a numeric restoration target live in the window presentation model. The mounted transcript keeps its `ScrollPosition` binding local, restores one deferred offset after Markdown layout can accommodate it, and lets explicit scrolling override the pending restoration.

Only the visible settings category is mounted. `MemorySettingsModel` retains preference drafts, original policy revision, save/reload operations, and generation guards. `DataSettingsModel` retains diagnostics and maintenance progress. Page observation is canceled on disappearance while explicitly started operations can finish. Provider editors retain explicit Save, revision conflict checks, and clearing of secret input on disappearance. No schema, provider protocol, appearance preference, or new model purpose is introduced.

## Verification

Host: macOS 26.6.2, macOS 26.5 SDK, Debug build. Checks used isolated offline demo data and synthetic content; no credentials or paid provider requests were used.

- The final Debug build and `xcodegen generate` passed. Language policy passed with 1,127 bilingual strings. `MiraHostTests` passed 53 Swift Testing cases in 11 suites and 8 XCTest cases, including one intentionally skipped live-provider evaluation.
- Earlier settings-content checks passed in Chinese/dark and English/light. They covered provider search/detail, model menu/pool, memory/data navigation, unmounted inactive pages, composer preservation, and unsaved memory-budget preservation across categories and settings exits. They preceded final AppKit shell adoption and do not establish current window-chrome or appearance acceptance.
- The earlier `testReadingPositionAcrossSettings` passed in 26.516 seconds. It entered settings during an offline reply, returned, waited for completion, scrolled into history, and verified the native scroll-bar value after another settings round trip within 0.03.
- Deterministic reading-state checks cover teardown callbacks, waiting for sufficient Markdown layout, consuming a restoration target once, explicit user-scroll override, and returning a following reader to the latest content. The retained offset includes the scroll view's top inset and is frozen before switching to settings.

The shared root declares an 850 × 620 pt minimum. Final AppKit mode-switch, inspector preference, draft, and native-command checks are recorded in [window-shell verification](APPKIT_WINDOW_SHELL.md).

The post-cleanup English settings UI rerun started but did not finish: another application window interrupted automation, the run was stopped, and test-log finalization reported an Xcode error. No pass is claimed for that rerun. Logs are under `.build/ui-commit/ui-verification.log`; no second appearance matrix was attempted.

## Limits

Current deterministic state checks and the focused native shell checks passed; a complete settings UI rerun remains outstanding. The host runs macOS 26.6.2; building for macOS 15 does not verify macOS 15 runtime behavior. Real provider saves, activation, capability probes, destructive data operations, full VoiceOver/accessibility preference audits, package/provider tests, and a controlled Release sidebar-animation comparison remain unverified. Unmounting inactive pages reduces retained layout work but does not establish a sidebar-animation performance improvement.
