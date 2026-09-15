# Streaming Markdown layout correction

Date: 2026-09-09. Branch: `dev`. Host: macOS 26.6.2, Apple Silicon.

## Defect and correction

The reported symptom was earlier reply content moving during streaming and code/table blocks covering subsequent text after completion. Incremental list updates only limit which message is invalidated; Markdown parsing, syntax transitions, and asynchronous code highlighting can still rebuild that message's attributed document.

A synthetic 48-character stream reproduced a table overlapping following text with both normal motion and Reduce Motion. At 420 pt width, a 118 pt table at y=854 intersected a following line beginning at y=960.46. Disabling animation did not fix the failure.

The integration applied paragraph metrics after MarkdownView had positioned native blocks, including changing nested code/table label metrics after their enclosing height was reserved. Mira now normalizes the main prose document before native block placement and leaves nested native controls' measured metrics intact. Post-layout traversal retains link safety and localized copy controls only. Attributed-text changes explicitly mark the containing Markdown view for layout.

Fade completion also restored an entire older attributed snapshot, which could overwrite a newer document produced by asynchronous highlighting. Completion now removes its drawing markers from the current document and preserves current block reservations. It never replays the saved document. Fade bitmap parity, selection, reuse, link policy, and Reduce Motion coverage continue to pass.

## Verification

- The new `streamedAttachmentsKeepTheirReservedHeight` test failed before the correction in both motion configurations, and passes afterward. It streams three code/table sections, checks native block rectangles against following text, waits for asynchronous work and fades, commits the reply, and checks final layout at 420, 720, 320, and 420 pt widths.
- `MiraHostTests`: 52 Swift Testing tests in 11 suites passed; 9 XCTest tests passed and one opt-in live-provider test was skipped.
- Debug and Release app builds passed; the normal Release app was relaunched. Language policy passed with 1,139 bilingual strings; `git diff --check` passed.
- `swift test --package-path Packages/MiraKit`: 389 tests in 43 suites passed; the opt-in M5 benchmark remained skipped.
- The [native geometry report](evidence/2026-09-09-markdown-layout.json) uses the actual list, 100 synthetic history messages, and a draft that grows into three mixed-script code/table sections. Light/English at 1100×760 and dark/Chinese at the minimum 850×620 content size each recorded 23 samples, zero block/text intersections, zero movement of the first eight completed font runs, and zero scroll-offset drift, including fade settling and terminal replacement.
- Native screenshots were inspected in [dark Chinese](evidence/2026-09-09-markdown-layout-dark.png) and [light English](evidence/2026-09-09-markdown-layout-light.png). Code, following headings, tables, and trailing prose are separated; the completed bottom line clears the floating composer. The light screenshot followed native settings changes and return to the conversation.

The Debug fixture is opt-in with `--demo --native-rendering-benchmark --verify-markdown-layout --data-directory <absolute disposable library> --benchmark-report <new absolute JSON path>`. It bypasses providers and persistence for conversation presentation, uses no paid endpoints, and writes geometry only. Its escaped CJK scalars are documented synthetic wrapping content, not UI translations. A uniquely identified app/library was used and removed after preserving synthetic evidence. View cache images were discarded because they omitted composited native layers; durable screenshots use window capture.

This is a reproduced layout-correctness fix, not an FPS or speedup benchmark. It does not establish that every unfinished Markdown construct can avoid reflow. The user's actual conversation was not exported or replayed; larger real-provider streams, hardware scroll momentum, Instruments frame timing, and macOS 15 runtime remain unverified in this increment. No provider, memory, persistence, or cancellation implementation changed.
