# Conversation scroll-edge titlebar

Date: 2026-09-15. Host: macOS 26.6.2, Apple Silicon, macOS 26.5 SDK. Deployment target remains macOS 15.

## Native scroll integration — 2026-09-15

The conversation uses one native scroll container for virtualization, progressive
header blur, and a floating composer. The isolated prototype, its launch scripts,
and generated artifacts have been removed; acceptance uses the production app.

- `Vendor/ListViewKit` contains the pinned virtualizer with a native `NSScrollView`
  backend. Its `NSClipView` owns scrolling and its flipped document hosts only
  virtual rows. The local fork and license are documented in `README.mira.md`.
- The conversation no longer has an outer SwiftUI ScrollView, host scroller
  suppression, or wheel forwarding. The existing key/selection monitor remains
  scoped to navigation keys and Litext selection; it does not handle wheel input.
- On macOS 26.1+, a real 52 pt split accessory contains `MiraConversationHeaderView`
  and selects AppKit's `.soft` scroll edge. The owned split root cancels the inherited
  titlebar inset. Sidebar and inspector content restore that clearance; their
  native glass ancestors and materials are untouched.
- Native controls and title occupy one row. Title layout uses public control frames
  and detail safe-area bounds on each layout pass and after window resizing. It
  does not depend on a binary sidebar-collapse inset or publish SwiftUI padding.
- Rows use effective clip viewport width. Virtual document size is `listContentSize`,
  leaving the native meaning of `NSScrollView.contentSize` intact. Height compensation
  applies after document size changes, and unchanged layouts leave native elastic
  offsets alone.
- Native gesture/scrollbar notifications cancel pending reading restoration.
  Programmatic scroll animation has explicit cancellation; native wheel motion
  remains AppKit-owned. First placement, cached-page identity, thinking, citations,
  composer clearance and execution ownership retain their existing contracts.
- macOS 15 through 26.0 retain the native window title and opaque canvas treatment;
  the soft split-accessory API is availability-gated.

### Integration corrections and verification

- The top native inset is explicit: AppKit automatic content adjustment must not
  overwrite the measured header clearance. The later floating-composer correction
  uses measured document-tail padding for its bottom clearance; see
  [floating composer](FLOATING_COMPOSER.md). A top-inset change retains the
  historical offset, or the top anchor if already at the beginning.
- Cancelling the root titlebar inset also requires restoring sidebar/inspector
  content clearance. This keeps the sidebar label below the native window buttons.
- The benchmark now waits for stable native geometry, chooses a real middle user
  row, and measures actual cached-list identity, draft and snapshot-load retention.
  It waits for history notices and rejects presentation errors before interaction.
- Acceptance exposed a pre-existing local-driver history error: a completed reply
  with no model route was incorrectly treated as dispatched model context.
  `historyContexts` validates its answer and plan, requires no attempts, and returns
  empty sources. Routed evidence remains strict. The owning contract is
  [memory history](../architecture/AGENT_MEMORY_HISTORY.md).
- The jump action is retained for its opacity transition and disabled at latest.
  XCTest's existence/hittability proxy does not describe that SwiftUI lifetime.
  The UI test checks enabled state, performs an actual click, and independently
  verifies the native scroller reaches the bottom, then checks re-enabling in history.

Focused results on macOS 26.6.2:

| Boundary | Evidence |
| --- | --- |
| Native scroll backend and virtual anchors | 16 tests passed after dynamic composer clearance; `/tmp/mira-composer-overlay-backend.log` |
| Header geometry and native sidebar motion | 2 window-shell tests passed; `/tmp/mira-native-header-host-final.log` |
| Header/composer inset and reading position | All 6 viewport tests passed after dynamic composer clearance; `/tmp/mira-composer-overlay-host.log` |
| Chinese dark/minimum and English light conversation switching | Both UI cases passed with real wheel, jump-to-latest, reading-anchor restoration and draft reuse; `/tmp/mira-composer-overlay-ui-settled.log` |
| Final Debug app build | Required resolved-package build passed; `/tmp/mira-composer-overlay-build.log` |
| Local and routed history notices | 2 `MemoryHistoryWorkflowTests` passed |
| Capped code scrolling and cancel/continue | Both native UI cases passed; `/tmp/mira-native-header-ui-tests.log` |

Native captures under `.build/native-header-qa/` show the actual conversation,
progressive text defocus below the header, one title row, native controls, and the
floating composer: `conversation-en-light.png` and
`conversation-zh-CN-dark-minimum.png`. The latter uses Chinese UI at the 850 pt
minimum width. Fixture text is intentionally synthetic English in both locales.
`conversation-zh-CN-light-collapsed.png` additionally verifies the collapsed
sidebar: the title stays in the native button row with visible progressive blur.
The header fixture used a fresh, isolated synthetic library;
`.build/native-header-qa/final/report.json` passed. Final floating-composer geometry
and native captures are recorded in [floating composer](FLOATING_COMPOSER.md).

Token export, bilingual language policy (2,037 strings) and `git diff --check` passed.
Unverified: physical trackpad momentum/rebound, VoiceOver, Reduce Transparency,
Increase Contrast, fullscreen/multiple displays, older macOS runtime, and rendered
frame timing with a realistic unique-content corpus. macOS 15 compilation is not
macOS 15 runtime evidence. No provider requests or credentials were used.

## Commit cleanup verification

The independent scroll prototype, its tooling and generated bundle were removed.
The source vendor omits obsolete tests for its replaced custom scroll backend and
an unused wheel-event counter. Production geometry and interaction fixtures remain.
After cleanup, the resolved-package Debug build passed
(`/tmp/mira-native-scroll-cleanup-build.log`) and all 16 native backend/anchor tests
passed (`/tmp/mira-native-scroll-cleanup-backend.log`). Project generation, token
export, language policy and whitespace checks passed. The accepted UI behavior was
unchanged; native visual acceptance remains the production evidence above.
