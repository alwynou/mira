# AppKit window shell verification

## Current implementation

`MiraWindowShell` is the production conversation window shell. An `NSSplitViewController` owns the sidebar, conversation, and execution-inspector columns; SwiftUI hosting controllers render their content and retain the existing presentation models. Settings now has a separate SwiftUI scene; the older same-window settings checks below are historical. The conversation's [native scroll-edge titlebar](CONVERSATION_TITLEBAR.md) supersedes the earlier clipping description for the detail pane. Sidebar and inspector remain clipped by their hosting roots; the transcript's native viewport clips the conversation, including content beneath the toolbar.

- Sidebar bounds follow `MiraTheme`; the execution inspector is bounded to 180–480 pt and the conversation has no minimum width. Holding priorities are 250 for the sidebar and inspector and 249 for the conversation, below AppKit's divider-drag priority, so the conversation absorbs resizing first.
- Hosted views use `sizingOptions = []` and clip to their allocated frame. `MiraWindowShell.sizeThatFits` returns the finite proposed parent viewport size, preventing live inspector dragging beyond 480 pt from shrinking or shifting the outer shell. Unspecified or infinite proposals retain default sizing.
- The sidebar disables `canCollapseFromWindowResize`; its native toggle and divider-collapse interaction remain available in conversation mode. Settings reveals the sidebar, disables `canCollapse` and the sidebar command, and restores conversation visibility on return. Because changing `canCollapse` resets AppKit's resize policy, each mode transition explicitly retains `canCollapseFromWindowResize = false`. The inspector uses `NSSplitViewItem(inspectorWithViewController:)`, native system material, and AppKit safe-area handling on macOS 26. SwiftUI pane roots remain clear; no glass ancestor inspection, custom backdrop, fixed drag handler, or app-owned inspector material is used.
- A stable native `NSToolbar` owns the conversation sidebar toggle, tracking separator, native title, and three adjacent right-side actions. Command-N invokes the existing new-conversation action. Settings keeps only the tracking separator and flexible space; Back to Mira stays in its always-visible sidebar.
- Native inspector collapse synchronizes to the SwiftUI binding. Settings temporarily hides the inspector without discarding the conversation visibility preference. Window navigation, locale, design-system foreground/tint, conversation reading state, sheets, errors, and runtime tasks keep their existing ownership.

## Verification

Host: macOS 26.6.2, macOS 26.5 SDK, Debug build. Checks used isolated offline demo data and synthetic content; no credentials or paid provider requests were used.

`MiraWindowShellTests/testInspectorPreservesWindowSidebarAndPresentationState` passed. It hosts the actual representable with oversized synthetic SwiftUI content, opens the inspector at 850 × 700 pt, verifies stable window/sidebar geometry, switches to settings and back, and checks native collapse/binding synchronization followed by reopening. It requests widths of 180, 380, 480, 560, and 700 pt, verifying the 180 pt minimum and 480 pt maximum. A tracking-loop regression samples geometry before mouse-up: without the viewport sizing fix the shell narrowed to 847 pt and shifted 1.5 pt inward; with the fix it fills the 850 pt viewport while the sidebar remains stationary.

Native checks passed at 850 × 700 pt: Command-N kept one window; the exact draft `1234567890` survived settings entry, sidebar collapse, return, and inspector presentation; Command-Return started the offline stream and Command-period retained partial Markdown and a cancellation receipt; the native inspector displayed synthetic execution details while the sidebar remained visible; settings return restored the inspector and conversation state; and the native traffic lights, title, three right-side actions, sidebar toggle, and composer remained usable.

The window uses the existing `canvas` token as its container background with a transparent titlebar and hidden detail titlebar separator. Native sidebar material remains near-opaque over that canvas, and the inspector retains system material. Native checks used synthetic Chinese content. The latest 180 pt minimum was verified by the native split test; a separate visual capture at that exact width was not completed.

After final cleanup, project generation, the Debug app build, all `MiraHostTests` (53 Swift Testing cases and 8 XCTest cases, including one skipped opt-in live evaluation), design-token export, language policy validation (1,127 bilingual strings), and `git diff --check` passed. Logs remain under `.build/ui-commit/host-verification.log`. The export records the native sidebar owner. No new frame-time or main-run-loop performance result is claimed for the sizing fix.

## Limits

The subsequent [settings simplification verification](SETTINGS_LAYOUT_VERIFICATION.md#settings-simplification-2026-09-08) covers the fixed settings sidebar, restoration of a previously collapsed conversation sidebar, command/divider collapse rejection, and English/light plus Chinese/dark settings screenshots. It supersedes the earlier collapsible-settings behavior described in the historical checks above.

This evidence covers the current light Chinese interface and focused native split interactions on macOS 26.6.2. Dark and English matrices, full accessibility preference variants, provider/network and package tests, macOS 15 runtime, long-conversation profiling, and a controlled Release performance comparison remain unverified. Building for macOS 15 does not verify macOS 15 runtime behavior.
