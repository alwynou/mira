# Streaming performance verification

Date: 2026-09-06. Scope: M1 conversation rendering, streaming follow behavior, and the reported native app hang.

## Evidence and repair

A five-second sample of the frozen app on macOS 26.6.2 showed 2,400 of 2,404 main-thread samples in SwiftUI transaction flushing. Lazy stack placement and repeated child measurements dominated; the process consumed approximately one CPU core. The current development database passed SQLite `quick_check`, with all four executions completed. The process was terminated after sampling; the library and credentials were preserved.

The fix separates composer and transcript observation, coalesces cumulative text/thinking snapshots at 100 ms, and immediately replaces pending snapshots on authoritative reload or selection changes. The transcript uses stable eager rows so asynchronous Markdown heights are retained instead of repeatedly evicted and measured. Text entrance animations are disabled, collapsed thinking is not parsed, and unchanged answer/citation views skip recomputation.

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

## Limits

Interactive native verification used macOS 26.6.2. macOS 15 coverage is CI hostless testing, not a manual scrolling session. Paid model endpoints were not exercised. Automated timing/frame-hitch budgets, hundreds of retained messages, and multi-megabyte Markdown still need separate scale profiling. The stable eager transcript trades lazy row eviction for retained views; do not claim unbounded history performance. The exact reported interaction should also be checked with the user's normal trackpad usage.

Reproduction and launch flags are in [Development](DEVELOPMENT.md). User-visible behavior belongs to [Workspace and conversation](../product/WORKSPACE_AND_CONVERSATION.md).
