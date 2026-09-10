# Floating conversation composer

Current implementation; verification captured on 2026-09-09, consolidated on 2026-09-10.

## Behavior

The input, context shelf, sending hint, and model/send controls share one floating surface above the full-height native transcript. `MiraComposerBackdropView` uses `NSVisualEffectView` with `.headerView`, `.withinWindow`, `.active`, and 100% material opacity in both appearances. There is no additional surface-color overlay. Reduce Transparency or Increase Contrast selects an opaque shared surface. The input and controls retain full opacity.

Shared tokens define a 22 pt corner radius, a constant 1 pt border at 70% opacity, and a 6% black shadow with 4 pt radius and 2 pt vertical offset. Focus does not strengthen the border or shadow. The container sits 14 pt above the window content bottom. The centered sending hint is 10 pt; the secondary 11 pt model label is capped at 160 pt and sits 8 pt from Send. The full model label remains available in help/accessibility and the native selection menu.

`TranscriptViewportLayout` uses the measured overlay footprint as the native list's bottom content inset. Messages scroll beneath the composer, while the final row can be positioned entirely above it. All input lines and notices participate in that measurement. Streaming growth and terminal replacement preserve the current reading position. Initial display, new user messages, and Jump to latest position once; deferred measurements may settle that operation for 500 ms. Content changes or user scrolling cancel it immediately. Composer/window resizing preserves bottom clearance when already at latest and retains historical reading otherwise.

Reply/table body is 14 pt, code is 12 pt, headings are 20/24 pt, and paragraph line spacing is 2 pt. Paragraph/final-block gaps are 8 pt, list/general gaps 4 pt, and row bottom spacing 24 pt. Metrics are configured before measurement; the [Markdown layout correction](MARKDOWN_LAYOUT_VERIFICATION.md) records the attachment/fade fix and regression coverage. Internal table cell padding and minimum row heights remain owned by the pinned renderer.

The conversation's memory-extraction disclosure, expansion state, unused navigation callback, and now-unreferenced `MemoryExtractionStatusView` are removed. Background extraction, persisted outcomes, settings, explicit-save approvals, and historical citations remain. Replacement extraction feedback is deferred in the product contract.

## Native evidence

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

Remaining checks: macOS 15 runtime, full VoiceOver/IME and physical trackpad/drag-selection sessions, and system accessibility preference switching. A later reported first-focus flash near the window bottom remains unresolved; an isolated field-editor probe did not reproduce it and no fix is claimed. These layout checks do not establish FPS or throughput.

Superseded Liquid Glass/tint/transparency experiments and their intermediate captures were removed during consolidation. The retained files describe the accepted implementation and its verification limits.
