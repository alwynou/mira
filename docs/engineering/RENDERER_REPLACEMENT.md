# Native conversation renderer replacement

Historical verification: the current composer styling, typography, and streaming scroll policy are described in [floating composer](FLOATING_COMPOSER.md).

Date: 2026-09-09. Branch: `dev`. The user approved direct replacement after the [isolated comparison](RENDERER_COMPARISON.md).

MiraMac now renders assistant answers and expanded thinking with MarkdownView/Litext inside a clipped ListViewKit AppKit transcript. The vendored SwiftStreamingMarkdown source, its renderer tests, old SwiftUI transcript/follow animation, comparison source harness, and obsolete renderer-only dependencies have been removed. There is one production renderer path. MiraCore, persistence, provider execution, cancellation, recovery, and credential storage are unchanged.

## Implementation

- MarkdownView `757b6fcc4b3095e84f4c0613f4b98147f49dcd09`, ListViewKit `c6a067ba837758a50612f88dd1d6bb025175df6c`, and Litext `130b4eef642d76a3d2dcf07ab966f32f08e14b90` are pinned in the project and lockfile. Full upstream license texts and bundled font/highlight.js notices are included in the app.
- Immutable snapshot diffs update only changed list items. A draft and its terminal reply retain execution identity. Visible rows own native text views; a shared measurement row and bounded 64-entry prepared-content cache serve history. Collapsed thinking is not joined or parsed.
- Row reuse clears selection and transient content; a mounted same-message append preserves a stable prefix selection. Removal and privacy clearing release prepared content, measurement content, and pooled rows. Thinking expansion survives recycling and settings navigation within the conversation.
- Reading intent is independent of geometry. Row-ID/relative-offset restoration preserves paused reading through settings. Viewport resizing alone does not count as user scrolling. The original replacement supported live following; the current policy positions only for initial display, new user messages, or explicit navigation, and preserves position during streaming (see the floating composer record).
- Appended prose uses bounded display-only fades: 500 ms duration, up to 100 ms staggering, 128 spans, a 2,048 UTF-16-unit tail, and 600 ms lifetime. Syntax transitions that do not preserve the rendered prefix render immediately. Links, attachments, and existing math/quote drawing callbacks keep their normal drawing. Terminal, selection, reuse, and off-window transitions finish fades. The synthetic paragraph-ending newline is excluded from append detection. Fade drawing resets the Core Text cursor before placing glyphs; completion removes fade markers from the current document without restoring stale attachment reservations (see [streaming layout correction](MARKDOWN_LAYOUT_VERIFICATION.md)). Mixed-script wrapped output is compared against independently prepared nonanimated bitmaps both at full opacity before the timer fires and after repeated settled redraws; the initial faded bitmap must differ.
- User bubbles and existing memory/source citation controls retain their SwiftUI implementations within native rows. Markdown links are underlined and restricted to HTTP(S), including nested table labels; remote images are not fetched. Copy labels/tooltips follow Mira's selected locale. Native system text-selection menus continue to use the OS language. Code syntax colors use MarkdownView's built-in Xcode palette.

## Automated evidence

Local host: macOS 26.6.2, Apple Silicon M1 Pro, Xcode 26.6 / Swift 6.3.3. Deployment target remains macOS 15.

| Check | Result |
| --- | --- |
| `swift test --package-path Packages/MiraKit` | 389 tests in 43 suites passed |
| Debug app build with resolved dependencies | Passed |
| `MiraHostTests` | 43 Swift Testing tests and 9 XCTest tests passed; 1 opt-in live-provider XCTest skipped |
| Release app build with resolved dependencies | Passed |
| `python3 -m unittest discover -s scripts/tests` | 14 passed |
| Language policy | 1,139 complete bilingual keys passed |
| `git diff --check` | Passed |

Host coverage includes unchanged-row diffing, draft-to-terminal identity, privacy purge and deletion/reinsert, narrow/wide row measurement, selection/reuse, unsafe main/table links, localized code controls, canonical final bitmap parity, Reduce Motion, reading state, scroll intent, and deferred follow cancellation. Existing package tests retain persistence/cancellation/recovery/privacy boundaries. Tests use synthetic data and isolated stores; no paid provider calls were made.

## Native observations

A separately identified Debug app and disposable demo library were used, then removed. The native screenshots and accessibility observations in the task covered:

- Chinese/light and English/dark presentation, wide and minimum-width windows (approximately 850 pt wide; the captured narrow outer window includes native titlebar chrome).
- A complete 24-section reply with nested lists, quotes, code, tables, inline math, and the final stream marker. Content stayed within the transcript above the composer; wide tables remained horizontally scrollable in the narrow column.
- Streaming with Thinking expanded, manual scrolling that exposed Jump to latest, and explicit return to the bottom.
- Command-period cancellation, Incomplete/Generation was stopped/Retry last turn, and a subsequent app restart that retained both the completed reply and interrupted output.
- A Chinese user message persisted verbatim in the synthetic library. Mixed ASCII/CJK rendered wrapping is additionally covered by bitmap tests.
- Home navigation from focused native text moved to conversation history. Returning from settings restored the same visible Section 6 code/quote position while paused. The final viewport-resize fix kept following active after cancellation changed the composer/error area.
- English Copy labels on the reopened app; app-owned controls and dark appearance persisted across restart.

The UI fixture did not exercise a valid knowledge/memory citation sheet, source-message reveal, physical trackpad momentum, full drag-selection autoscroll, or a full VoiceOver session. Those controls remain wired to the existing application models, but this record does not claim their complete native acceptance. macOS 15 runtime verification and Instruments frame-hitch/GPU measurements are also outstanding. A successful build and queue-delay probe do not establish an FPS result or leak freedom.

## Final native-app performance probe

The opt-in `scripts/run_rendering_benchmark.py` fixture uses the actual Debug transcript and composer with 100 historical messages and expanded Thinking. It performs 30 programmatic top/bottom scrolls. This is an integration health check; its fixture, pacing, typography, and Debug configuration differ from the earlier Release comparison and its numbers must not be used to calculate a replacement speedup.

The [final synthetic report](evidence/2026-09-09-native-renderer.json) contains all samples and measured-source hashes. The run completed in 74.25 s with all 30 scroll probes. Peak sampled process RSS was 216.1 MiB.

| Phase | Queue P95 | Maximum queue sample | Samples |
| --- | ---: | ---: | ---: |
| warmup | 3.24 ms | 446.74 ms | 70 |
| streaming | 14.25 ms | 53.65 ms | 417 |
| scrolling | 64.61 ms | 169.91 ms | 135 |
| settled | 0.16 ms | 100.51 ms | 47 |

Parsing and immutable content preparation currently occur on the main actor; exceptionally large single messages and first-time history measurements can still produce queue spikes. Further optimization should be driven by production Instruments traces rather than assuming that virtualization removes every hitch.

## Submission cleanup and verification

Date: 2026-09-10. Consolidated the accepted composer behavior and evidence in [Floating composer](FLOATING_COMPOSER.md), removed four superseded iteration records and 15 intermediate captures/reports, and deleted the unreferenced extraction-status view. Retained six synthetic/settings screenshots and five JSON evidence files; they contain no real conversation content or credentials. Removed the temporary first-focus probe without claiming a fix for the reported flash. The cancelled full-AppKit conversation migration is not included: SwiftUI composition and native transcript rendering remain mixed.

Regenerated the Xcode project and design-token export. Current dependencies contain no third-party macro targets, so CI, packaging, developer instructions, and the verified build command no longer bypass macro validation.

Fresh checks on macOS 26.6.2 / Xcode 26.6:

- `swift test --package-path Packages/MiraKit`: 389 tests in 43 suites passed.
- Debug app/host build and `MiraHostTests`: 52 Swift Testing tests in 11 suites passed; 10 XCTest tests passed and one opt-in live-provider test was skipped on the full rerun.
- The first host run failed the unchanged window-shell test's assertion that native divider mouse tracking started. The same full command passed on rerun without code changes. The intermittent tracking failure is recorded, not treated as a repaired product bug.
- 14 Python script tests, language policy and compiler-extracted UI string coverage (1,139 bilingual keys), local Markdown link checks, and `git diff --check` passed.

No new visual behavior was introduced by cleanup. The earlier native evidence and its platform/accessibility gaps remain as recorded above and in the linked documents. No paid provider requests, runtime database changes, or credential changes were made during this cleanup.
