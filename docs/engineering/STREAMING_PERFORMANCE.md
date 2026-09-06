# Streaming performance verification

Date: 2026-09-06. Scope: M1 conversation rendering, streaming follow behavior, and the reported native app hang.

## Evidence and repair

A five-second sample of the frozen app on macOS 26.6.2 showed 2,400 of 2,404 main-thread samples in SwiftUI transaction flushing. Lazy stack placement and repeated child measurements dominated; the process consumed approximately one CPU core. The current development database passed SQLite `quick_check`, with all four executions completed. The process was terminated after sampling; the library and credentials were preserved.

The fix separates composer and transcript observation, coalesces cumulative text/thinking snapshots at 100 ms, and immediately replaces pending snapshots on authoritative reload or selection changes. The transcript uses stable eager rows so asynchronous Markdown heights are retained instead of repeatedly evicted and measured. The initial hang repair disabled text entrance animations; the follow-up below restores appended-text fades. Collapsed thinking is not parsed, and unchanged answer/citation views skip recomputation.

The vendored renderer now caches exact-width paragraph measurements with a bounded four-entry cache, invalidates intrinsic size only when the actual layout width changes, and derives table column widths from one viewport source. Cancelled parsing tasks cannot publish superseded content. Source provenance and patch boundaries are in `Vendor/SwiftStreamingMarkdown/UPSTREAM.md`.

Follow intent is separate from geometry: user scrolling or a source jump pauses following; returning to the bottom or the localized jump button resumes it. Only rounded content/container size changes can request a follow scroll, and a view already at the bottom does not issue another scroll. A second long-response check caught residual layout activity before this final guard was added.

## Verification

- `swift test --package-path Packages/MiraKit --disable-automatic-resolution`: 306 tests in 34 suites passed (the existing opt-in scale gate remains skipped).
- Debug app build and `MiraHostTests`: passed, including 5 XCTest localization cases and 26 Swift Testing cases. New cases cover cumulative Unicode/empty snapshots, timer invalidation after authoritative clears, thinking-only output, execution isolation, scroll intent, repeated paragraph proposals, width/content changes, and empty/Unicode layout.
- GitHub CI passed on implementation commit `16eb28fb742581832cd166fc6e3d61d233bc9835`: [Swift checks run](https://github.com/alwynou/mira/actions/runs/34019446699), including package tests, catalog generator tests, app/host tests, and extracted UI coverage on the macOS 15 runner with Xcode 26.3.
- Language policy and compiler-extracted string checks: 1,130 bilingual catalog entries passed.
- Native local provider fixture: 19,866-byte response with 24 sections, code blocks, tables, nested lists, quotes, and a separate visible thinking trace. Verified growing output at the bottom, typing into the composer during generation, explicit jump to latest, repeated rapid up/down scrolling, thinking expansion, reopening saved replies, cancellation, and retry. The cancelled reply was marked incomplete, its partial text remained visible, and the unsent composer draft was retained.
- The fixture also reached the existing explicit context-budget error after repeated large replies; it did not call a network provider or silently compact history.
- After the final guard, a three-second sample after a long retry with thinking expanded showed all 2,569 main-thread samples waiting normally in the event loop. A process snapshot reported 0.0% CPU at rest. These are responsiveness observations, not a frame-rate benchmark.
- The original development library was reopened, its existing conversation loaded, and rapid scrolling checked. Only the isolated fixture library created for this verification was removed. Stack/build/test logs stay ignored under `.build/run`; real conversation contents are not included in this record.

## Appended-text animation follow-up

The first follow-up used a fast 240 ms whole-packet fade. The user correctly reported that its visual effect was too weak; it is not the accepted animation behavior. The implementation now follows [Microsoft's paragraph animation timing](https://github.com/microsoft/SwiftStreamingMarkdown/blob/main/Sources/MarkdownText/UI/Paragraph/ParagraphAnimation.swift): a 500 ms fade using the upstream curve, with words staggered over a 100 ms window. The [upstream streaming guide](https://github.com/microsoft/SwiftStreamingMarkdown#streaming-usage) also confirms that the parser consumes cumulative snapshots. Mira keeps its existing snapshot coalescing and renderer identity.

On macOS, `StreamingFadeLayoutManager` applies alpha only in glyph drawing. It resolves word and glyph ranges on content updates, excludes attachments, and normalizes overlapping ligatures. Animation frames never edit attributed text or invalidate paragraph measurement. Each paragraph retains at most eight recent batches within the last 2,048 UTF-16 units, expires them within 600 ms, and caps drawing at 128 spans. Large packets group adjacent words. A weak display-link target avoids a view/target ownership cycle. Initial/history snapshots render immediately; terminal updates, Reduce Motion, selection, and dismantling finish pending fades. Unchanged Markdown blocks use explicit equality to avoid rebuilding their views on every snapshot.

Local evidence:

- App build and host checks pass: 5 XCTest localization cases and 40 Swift Testing cases. New bitmap tests prove stable prefix pixels, progressively different start/middle/end frames, staggered words within one packet, unchanged attachments, and final parity with native TextKit for ligatures, combining marks, ZWJ emoji, Arabic, and CJK. Additional checks cover bounded bursts, replacement/disabled states, unchanged text/measurement on display ticks, first snapshot/cancelled parse gating, and dismantling.
- Package regression checks pass: 306 tests in 34 suites. Language/extracted UI checks pass with 1,130 bilingual strings.
- The native 19,866-byte mixed Markdown fixture was exercised with automatic following, input during generation, rapid long-distance scrolling, cancellation, and retry. A captured eight-second video of the final word-stagger implementation shows the real window's new paragraph/list text fading progressively while completed text stays stable. Only synthetic fixture content was recorded; the video is a temporary local artifact, not committed.
- A five-second sample of the final word-stagger implementation during a second long reply measured 4.68 CPU seconds over 6.03 wall seconds in Debug. Layout work remains substantial in this table-heavy fixture; bounded animation is not a complete history-scaling solution. This is not a claim of 60 FPS or zero-cost streaming.
- After two long replies, cancellation/retry, and rapid scrolling, the three-second resting sample had all 2,594 main-thread samples waiting in the event loop and reported 0.0% CPU. The final word-stagger implementation was checked again after its second long reply: all 2,603 main-thread samples were in the normal event-loop wait and CPU returned to 0.0%.

## Limits

Interactive native verification used macOS 26.6.2. macOS 15 coverage is CI hostless testing, not a manual scrolling session. Paid model endpoints were not exercised. Automated timing/frame-hitch budgets, hundreds of retained messages, and multi-megabyte Markdown still need separate scale profiling. The stable eager transcript trades lazy row eviction for retained views; do not claim unbounded history performance. The exact reported interaction should also be checked with the user's normal trackpad usage.

Reproduction and launch flags are in [Development](DEVELOPMENT.md). User-visible behavior belongs to [Workspace and conversation](../product/WORKSPACE_AND_CONVERSATION.md).
