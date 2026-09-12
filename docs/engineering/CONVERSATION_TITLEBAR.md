# Conversation scroll-edge titlebar

Date: 2026-09-11. Host: macOS 26.6.2, Apple Silicon, macOS 26.5 SDK. Deployment target remains macOS 15.

## Implementation

On macOS 26, `MiraScrollEdgeViewport` uses a finite SwiftUI `ScrollView`, a real title in `safeAreaBar`, and `.scrollEdgeEffectStyle(.soft, for: .top)`. This is the same system effect used by the native settings form. No private blur filter or native glass hierarchy manipulation is used.

ListViewKit's scrolling viewport is a custom `NSView`, not a SwiftUI scroll view. It still owns message virtualization, reading position, selection, and the transcript scrollbar. The enclosing SwiftUI viewport registers that content with the system edge effect and remains anchored to its bottom. The composer is outside this host so the host cannot shift it. Vertical transcript wheel events go directly to ListViewKit through the existing window-local event monitor; horizontal-dominant gestures keep their existing path for code and tables.

To prevent a second scrollbar during overpull, `MiraScrollEdgeHostConfiguration` suppresses the outer scrollers' drawing and accessibility and sets the outer scroll elasticity to `.none`, using the public `enclosingScrollView` and scroller properties. It leaves the transcript's own scroller intact. On this host, `.scrollIndicators(.hidden)`, `.scrollDisabled(true)`, removing the native scroller, or setting its `isHidden` also removed the progressive effect. The scroller views therefore remain installed with zero alpha. This OS-specific integration should be rechecked when upgrading the SDK/runtime.

The native top safe-area inset controls the title height and first-row clearance. AppKit still owns window controls, toolbar actions, split panes, and the native window name. macOS 26 removes only the duplicate native title; the SwiftUI title reserves space measured from the public native button views. Earlier systems retain the native title over the shared canvas. The transcript clips at the full window-height viewport, not at the toolbar's lower edge. Existing first-row spacing, page-key and selection-edge calculations account for the covered area; the composer retains its measured bottom clearance. Provider, storage, thinking, and execution behavior did not change.

## Focused verification — 2026-09-11

- The final Debug app build passed with the documented resolved-package build command. Log: `/tmp/mira-native-scroll-edge-build.log`.
- Earlier in this task, only `MiraHostTests/TranscriptViewportLayoutTests` ran: 6 passed. Log: `/tmp/mira-titlebar-viewport-tests.log`; result: `.build/xcode/Logs/Test/Test-Mira-2026.09.11_16-00-49-+0800.xcresult`. The inset calculations did not change after that run. The later scroller correction was checked in the native app rather than rerunning unrelated suites.
- Native checks used the existing offline synthetic conversation in `/tmp/Mira-Titlebar-QA`. Repeated upward scrolling at the top and subsequent downward scrolling exercised the affected path. Light-mode scrolling showed one transcript scrollbar, progressive blur behind the title, and the composer in its fixed position. Dark mode also showed progressive blur with the execution inspector open; the final response marker remained above the composer.
- Token export and whitespace validation passed. Self-contained light/dark titlebar previews were updated. No package-wide, full host, or full UI test suite and no paid endpoint was run for this correction.

Current native evidence is in `.build/native-titlebar-qa/scroll-edge-captures/`:

| File | Original capture | Evidence |
| --- | --- | --- |
| `conversation-zh-CN-light.png` | 16:59:48 | One visible transcript scrollbar, progressive blur over code behind the title, fixed composer |
| `conversation-en-dark-inspector.png` | 17:02:17 | Progressive dark blur, clear title, inspector open, final marker above composer |

The light capture predates only the subsequent accessibility-hidden flags on the outer scroller; the dark capture uses the final binary. English/dark used process arguments without changing saved preferences. The app was relaunched without those overrides after verification.

## Commit preparation — 2026-09-12

The final Debug build and full host suite passed after removing unused shell state and a redundant override. This includes all six viewport-layout cases, native split-window checks and appearance transitions. Result: `.build/xcode/Logs/Test/Run-Mira-2026.09.12_12-04-41-+0800.xcresult`. The package suite also passed all 389 cases. This cleanup preserves titlebar layout and scrolling behavior; conversation screenshot evidence remains the native captures above.

## Remaining checks

Physical trackpad momentum/elasticity can differ from the UI automation's scroll gestures. No macOS 15 runtime, exact minimum-size, fullscreen, multiple-display, Reduce Transparency, Increase Contrast, or VoiceOver acceptance is claimed for this final implementation. The final scrollbar fix was not subjected to a new performance benchmark, IME test, or quantitative streaming-position test. System blur and tint remain OS-dependent.
