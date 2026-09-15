# Conversation pages and reading restoration

Date: 2026-09-12. Scope: window-local conversation pages, native transcript activation, targeted runtime updates and the unique unsent draft. Provider/settings evidence is separate.

## Current behavior

- `ConversationModel` owns navigation, library metadata and a bounded page cache. Each `ConversationPageState` owns messages, executions, stream presentation, composer text, explicit model selection, inspector selection, thinking expansion and reading geometry. Selecting the active or a loaded cached page performs no conversation snapshot read.
- The window retains three recent formal pages plus its optional unsent draft. Each mounted page has a stable SwiftUI identity and its own native list. Inactive pages cannot receive input or shortcuts; native geometry polling stops and content layout waits for activation. A page being enqueued is protected until that operation finishes, when the normal cache limit is reapplied.
- Eviction cancels stale loads and releases history snapshots, stream presentation, prepared documents and native rows. Lightweight page state retains the user's input, selected model, inspector selection, expansion and numeric reading measurements for the window session. Returning after eviction reloads authoritative history and restores the stable row anchor. Closing the window ends this session.
- Loads are serialized and versioned per page; sidebar/configuration reads are coalesced separately. Late results and errors cannot overwrite an invalidated page or another selected page. `conversationChanged(id)` refreshes the named retained page; draft/thinking events are routed by execution ID. Periodic checkpoint writes do not trigger full history reads. Background save failures belong to their originating page.
- Privacy invalidation clears all page history and stream owners before requesting fresh snapshots. Native coordinators clear prepared content, measurement views and every registered row, including hidden reuse pools, when the content generation changes. Numeric geometry and independent user-authored input drafts survive; they are not derived history caches. Deferred row and inspector callbacks check page identity/activity and generation before publishing.
- New Conversation activates one unsent draft per window. Repeated clicks never add database rows or erase the input. Selecting a workspace explicitly changes the draft's sending scope. First send validates input, capacity, workspace policy and route, then commits Conversation, User Message and queued Execution in one SQLite transaction. Success promotes the same page in place. Validation or storage failure leaves the draft intact and no empty conversation. A subsequent New action creates the next single draft.

The native virtualized list still has the complete history. First entry positions the latest turn before display, using a zero-height installation viewport and bounded native height corrections. Cached activation keeps the native viewport; a saved reading anchor also compensates for layout changes. User scrolling, source navigation and changed content cancel prior navigation corrections. Streaming continues independently of the selected page and does not enable automatic following. No schema or dependency change is required for this refactor.

## Verification

Package tests passed **393 tests in 43 suites**. Atomic first-send tests cover successful insertion, rollback after an enqueue failure, route/workspace rejection before persistence and origin-scoped failure events. Existing cancellation, recovery, interrupted-stream, thinking and privacy tests remain included.

MiraHostTests passed **77 Swift Testing tests in 15 suites and 20 XCTest cases** (one opt-in live-model case skipped). New presentation coverage verifies stable page identity, no read on cached activation, independent drafts/model choices/positions, LRU eviction and reload, unique New behavior, successful in-place promotion, failed first send without empty records, hidden-page privacy clearing and targeted refresh/error delivery. Existing stream-buffer, row measurement/display, text-selection and privacy tests remain included. Language policy and whitespace checks pass.

Native UI tests passed all **three cases**, using disposable demo libraries and no paid endpoints:

1. English/light at 1100 × 760 content size.
2. Chinese/dark at the 850 × 620 minimum.
3. Repeated New clicks, unchanged formal-row count before sending, first-send promotion, then another unique draft without further formal rows.

The switching fixture writes 100 and 120 synthetic messages through SQLite enqueue/finish APIs. It verifies distinct native lists for different pages and reuse of the original list on return. Both first entries sample bottom geometry; four return cycles compare stable row IDs and relative offsets. Cached returns, including repeated cycles, must leave the snapshot-read counter at two. UI tests then issue real wheel input and sidebar clicks, check the visible message and vertical position within 2 pt, and verify both history and unsent drafts. Fixture text is pasted independently of the input method, and all clipboard representations are restored.

The values below are from one Debug acceptance run, not averaged performance guarantees:

| Check | Chinese / dark / minimum | English / light / regular |
| --- | ---: | ---: |
| Same-selection call | 0.020 ms | 0.009 ms |
| First conversation: selection call / native ready | 353.0 / 353.0 ms | 356.0 / 356.1 ms |
| Second conversation: selection call / native ready | 108.3 / 297.5 ms | 318.2 / 318.3 ms |
| Cached return: activation call / native ready | 0.107 / 82.8 ms | 0.075 / 83.1 ms |
| Snapshot reads before / after all returns | 2 / 2 | 2 / 2 |
| Original native list reused / second list distinct | yes / yes | yes / yes |
| Maximum first-entry bottom error | 0 pt | 0 pt |
| Repeated anchor checks | 4 / 4 | 4 / 4 |
| History-return main-actor service delay: p95 / maximum | 71.5 / 324.5 ms | 67.5 / 340.7 ms |

Native screenshots were inspected in both appearances and sizes. They show the retained middle-of-history position, the floating composer with its original draft, and the complete unsent draft after navigation. The prior shared-list implementation measured 99.2 / 113.1 ms to return to history in its final acceptance run and still read a snapshot. The current run establishes direct cached activation and stable positioning; cold-entry rendering and occasional main-actor delays still warrant separate profiling if stricter latency targets are introduced.

Commands:

```sh
swift test --package-path Packages/MiraKit
xcodebuild -project Mira.xcodeproj -scheme Mira -configuration Debug -destination 'platform=macOS' -derivedDataPath .build/xcode -onlyUsePackageVersionsFromResolvedFile CODE_SIGNING_ALLOWED=NO -only-testing:MiraHostTests test
xcodebuild -project Mira.xcodeproj -scheme MiraUI -configuration Debug -destination 'platform=macOS' -derivedDataPath .build/xcode -onlyUsePackageVersionsFromResolvedFile CODE_SIGNING_ALLOWED=NO -only-testing:MiraUITests/ConversationSwitchUITests test
python3 scripts/check_language_policy.py
git diff --check
```

Evidence (generated locally, excluded from Git):

- Package output: `/tmp/mira-page-cache-package-final.log`.
- Host output: `/tmp/mira-page-cache-host-verified.log`; the final result bundle path appears in that log.
- Native UI report, JSON samples and screenshots: `.build/xcode/Logs/Test/Test-MiraUI-2026.09.12_16-19-55-+0800.xcresult`.
- Exported UI attachments: `/tmp/mira-page-cache-acceptance`.
- Prior shared-list native acceptance: `.build/xcode/Logs/Test/Test-MiraUI-2026.09.12_15-41-35-+0800.xcresult`.

## Limits

Selection timings end when the selection call returns. Cold entry awaits its snapshot and can include native work scheduled on the main actor; cached activation reads no snapshot. Native readiness is measured separately. Main-actor queue service and sampled geometry are responsiveness/position proxies, not display-frame measurements, hardware input latency or proof of zero hitches.

Tests run in Debug on macOS 26.6.2. macOS 15 runtime, larger real histories, paid-model streaming during navigation, and source-citation navigation are not covered by this native fixture. Runtime and host tests cover synthetic background events, thinking, failures and cache invalidation; they do not replace native IME composition or frame-rate profiling. This task preserves committed composer drafts; uncommitted input-method candidates follow native focus behavior.

## Centered glass Jump to latest follow-up

The floating navigation action is now a 36 pt circle centered above the composer, with only the down-arrow symbol. `MiraGlassCircleButtonStyle` uses interactive native Liquid Glass on macOS 26, regular material on earlier versions and an opaque outlined surface for Reduce Transparency / Increase Contrast. Its size comes from the shared theme; the component preview and portable token export were updated together.

The old view condition hid the button whenever a scroll gesture became active and recreated it after an idle callback. The new visibility state is independent of gesture activity and bottom-alignment intent. Geometry shows it at an 8 pt distance and hides it within 2 pt of the bottom; the narrow gap filters rounding noise without requiring the user to stop scrolling. The button stays mounted, fading opacity over 160 ms (no animation with Reduce Motion), with hit testing, keyboard focus eligibility and accessibility disabled while hidden. Its separate view observes visibility so those changes do not rebuild transcript message snapshots or alter content insets.

Verification:

- Host tests passed 81 Swift Testing tests in 15 suites and 20 XCTest cases, with the one opt-in live case skipped. New cases cover gesture/idle independence, noise around both bottom thresholds, invalid geometry and explicit-jump hiding.
- All three conversation UI workflows passed against the updated component, including light/English, dark/Chinese at minimum size, and the unique unsent draft workflow. The tests verify a 36 pt square button centered on the input, four wheel bursts with the action still hittable, hiding after Jump, and reappearance after scrolling back into history. Both appearance screenshots were inspected: the symbol is legible, the circle clears the composer and the transcript continues behind its material.
- A focused English/light follow-up also waits for the geometry monitor to become idle, clicks Jump and checks the native scrollbar reaches its bottom value. It passed; evidence: `/tmp/mira-jump-button-idle.xcresult`.
- Build-for-testing, language policy (1,179 bilingual strings) and whitespace checks passed.
- Native acceptance bundle: `/tmp/mira-jump-button-ui-final.xcresult`; exported screenshots: `/tmp/mira-jump-button-accepted-images`.
- Host bundle: `.build/xcode/Logs/Test/Test-Mira-2026.09.12_16-50-59-+0800.xcresult`.

Native UI checks used a disposable copy of the built app with bundle ID `com.alwynou.mira.jump-qa`, a separately signed test runner and synthetic libraries.

This evidence addresses visibility-state flicker and the verified native interaction paths. Per-frame video analysis, macOS 15 material rendering and native accessibility preference changes were not part of this run; the existing platform/runtime limits above remain.
