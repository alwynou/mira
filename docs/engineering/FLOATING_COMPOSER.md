# Floating conversation composer

Current implementation; verification captured on 2026-09-09, consolidated on 2026-09-10.

## Behavior

The input, context shelf, sending hint, and model/send controls share one floating surface above the full-height native transcript. `MiraComposerBackdropView` uses `NSVisualEffectView` with `.headerView`, `.withinWindow`, `.active`, and 100% material opacity in both appearances. There is no additional surface-color overlay. Reduce Transparency or Increase Contrast selects an opaque shared surface. The input and controls retain full opacity.

Shared tokens define a 22 pt corner radius, a constant 1 pt border at 70% opacity, and a 6% black shadow with 4 pt radius and 2 pt vertical offset. Focus does not strengthen the border or shadow. The container sits 14 pt above the window content bottom. The centered sending hint is 10 pt; the secondary 11 pt model label is capped at 160 pt and sits 8 pt from Send. The full model label remains available in help/accessibility and the native selection menu.

`TranscriptViewportLayout` uses the measured overlay footprint as blank space at the end of the native document (`bottomContentPadding`). The native bottom `contentInsets` stays zero, and the composer is a SwiftUI bottom overlay of the full-height transcript. Messages scroll beneath the composer, while the final row can be positioned entirely above it. All input lines and notices participate in that measurement. Streaming growth and terminal replacement preserve the current reading position. Initial display, new user messages, and Jump to latest position once; deferred measurements may settle that operation for 500 ms. Content changes or user scrolling cancel it immediately. Composer/window resizing preserves bottom clearance when already at latest and retains historical reading otherwise.

Reply/table body is 14 pt, code is 12 pt, headings are 20/24 pt, and paragraph line spacing is 2 pt. Paragraph/final-block gaps are 8 pt, list/general gaps 4 pt, and row bottom spacing 24 pt. Metrics are configured before measurement; the [Markdown layout correction](MARKDOWN_LAYOUT_VERIFICATION.md) records the attachment/fade fix and regression coverage. Internal table cell padding and minimum row heights remain owned by the pinned renderer.

The conversation's memory-extraction disclosure, expansion state, unused navigation callback, and now-unreferenced `MemoryExtractionStatusView` are removed. Background extraction, persisted outcomes, settings, explicit-save approvals, and historical citations remain. Replacement extraction feedback is deferred in the product contract.

## Native scroll integration correction — 2026-09-15

The input surface is a bottom overlay on the conversation, so it does not divide
or size the native scroll viewport. `onGeometryChange` measures the entire
`bottomOverlay`; its current height includes input wrapping, banners and spacing.
No fixed input height is used for scroll clearance. `bottomContentPadding` adds
that measured height after the virtual content. `listContentSize` still describes
virtual content, while the native document frame includes the blank tail.

Native bottom content inset stays zero: the floating panel does not become native
scroll chrome or shorten the scrollbar track. Virtual rows remain mounted across
the full viewport behind it. Row navigation and reading-state calculations account
for the measured covered area. At latest, height changes move the endpoint; in
history they retain the reading offset unless the new document bounds require
clamping. The existing top native scroll-edge titlebar remains independent.

Focused checks:

- All 6 `TranscriptViewportLayoutTests` passed, including growth, shrinkage,
  historical offsets, short content and resize; `/tmp/mira-composer-overlay-host.log`.
- All 16 backend/anchor tests passed; `/tmp/mira-composer-overlay-backend.log`.
  The added case varies overlay height, checks rows remain mounted behind it,
  and scrolls a target row above the covered area.
- Both Chinese/dark/minimum and English/light native UI switching cases passed;
  `/tmp/mira-composer-overlay-ui-settled.log`. The checks use actual wheel input,
  cached reading positions, jump-to-latest and draft retention. Availability is
  synchronized after AppKit wheel transactions before querying SwiftUI controls.
- The UI fixture additionally requires the native scroll viewport to contain the
  input field. The material fixture checks the actual AppKit backdrop frame and
  last row in window coordinates, using short, eight-line, shrinking and minimum
  window scenarios. It requests latest only once before these height changes.

The final native material report (`.build/composer-overlay-qa/geometry-final.json`)
passed all four scenarios. Measured overlay heights were 180 → 265 → 180 → 265 pt;
all kept the full clip viewport, a zero native bottom inset, and a 9 pt clearance
from the last row boundary to the actual surface. These values are observations,
not layout constants.

The final Debug build passed (`/tmp/mira-composer-overlay-build.log`), along with
`git diff --check` and the bilingual language policy. Current captures/reports live
under `.build/composer-overlay-qa/`; `multiline-latest.png` shows the eight-line
input at minimum width with the final response fully above it.
`multiline-history.png` shows content continuing beneath the stationary panel
after native scrolling. Earlier physical
trackpad, accessibility-preference and older-system limitations still apply.

## Earlier native evidence

The offline fixture used an isolated disposable app/library with synthetic messages and no provider requests. The [material report](evidence/2026-09-09-composer-material.json) records the current material at alpha 1, a 14 pt bottom gap, and all five geometry cases passing:

| Scenario | Viewport height | Overlay height | Final row / unobscured bottom |
| --- | ---: | ---: | ---: |
| English/light, short | 708 pt | 180 pt | 528 / 528 pt |
| English/light, eight lines | 708 pt | 265 pt | 443 / 443 pt |
| English/light, shrink | 708 pt | 180 pt | 528 / 528 pt |
| Chinese/dark, minimum, eight lines | 620 pt | 265 pt | 355 / 355 pt |
| Chinese/dark, minimum, short | 620 pt | 180 pt | 440 / 440 pt |

Row bounds include normal bottom padding, leaving the final text additional clearance. Streaming and terminal replacement retained the same 27,868 pt scroll offset while the maximum grew to 28,335 pt; the accepted run observed zero wheel events. Native [dark](evidence/2026-09-09-composer-material-dark.png) and [light](evidence/2026-09-09-composer-material-light.png) captures were inspected. Focus, select-all, synthetic paste, multiline shrinking, appearance switching, and manual transcript scrolling worked. The light capture shows conversation content beneath the material with legible foreground input.

That revision passed Debug host tests (52 Swift Testing tests, 9 XCTest passes, one opt-in live-provider skip), a Release build, 14 script tests, language policy (1,139 bilingual keys), token export, and whitespace checks. Evidence predates the final opacity toggle back to 100%, which restores the same measured material configuration; screenshots were not repeated for that numeric restoration. [Appearance transition verification](APPEARANCE_TRANSITIONS.md) records subsequent Dark-to-System checks.

Reproduce with a Debug disposable bundle using `--demo --native-rendering-benchmark --verify-floating-composer --data-directory <new-absolute-fixture-directory> --benchmark-report <new-absolute-report-path>`. Stop its process before deleting the fixture. The normal library must not be used for this fixture.

Remaining checks: macOS 15 runtime, full VoiceOver/IME and physical trackpad/drag-selection sessions, and system accessibility preference switching. The first-focus flash was later reproduced as the macOS one-time-code AutoFill panel and corrected with the documented app opt-in requirement; see [first-focus verification](COMPOSER_FIRST_FOCUS_VERIFICATION.md). These layout checks do not establish FPS or throughput.

Superseded Liquid Glass/tint/transparency experiments and their intermediate captures were removed during consolidation. The retained files describe the accepted implementation and its verification limits.
