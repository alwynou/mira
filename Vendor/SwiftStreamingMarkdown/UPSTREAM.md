# SwiftStreamingMarkdown vendor

This directory vendors the runtime source of [Microsoft/SwiftStreamingMarkdown](https://github.com/microsoft/SwiftStreamingMarkdown) at commit `5f7c04e0558df6146f90d482edb62cb456986bda` (tag `v0.7.0`). The checkout contributed 152 source files and 11,442 source lines. Upstream `Tests/` and `Examples/` were intentionally not copied.

The package manifest keeps the upstream runtime dependencies and exact versions. It removes the upstream snapshot-testing dependency and snapshot test target because their fixtures are not vendored, then adds `SwiftStreamingMarkdownLocaleTests` for the focused locale helper tests in this directory.

Runtime changes are:

- `Utilities/String+.swift` adds an explicit locale-to-resource-bundle resolver and optional `Locale` parameters for table, list, code-copy, and text-selection labels. Explicit English and Chinese locales are supported; unsupported locales select the English resource bundle. Calls that omit the locale retain the existing package-default behavior.
- `UI/CodeBlockView.swift`, `UI/OrderedListView.swift`, `UI/UnorderedListView.swift`, `UI/TableView.swift`, and `UI/TextSelection/TextSelectionView.swift` read `@Environment(\.locale)` and pass it to those helpers.
- `Models/MarkdownRenderConfig.swift` and the AppKit/UIKit paragraph adapters pass the selected locale to the built-in text-selection menu.
- `Resources/Localizable.xcstrings` adds the missing `zh-Hans` translations for checked and unchecked task-list accessibility suffixes.

- `UI/Paragraph/AppKit/ParagraphNSView.swift` avoids unconditional intrinsic-size invalidation and caches measurements by content revision and constrained width. This addresses layout churn during long replies and scrolling.
- `UI/BlockView.swift` uses explicit renderable equality to skip updates of unchanged Markdown blocks during streaming.
- `UI/TableView.swift` derives column widths from the viewport only; measured table-content width no longer feeds back into its own column sizing. Empty layouts are guarded.
- `MarkdownView.swift` checks cancellation before parsing and again before publishing, so superseded view tasks cannot publish stale rendered content. Its `animatesTextUpdates` parameter enables appended macOS paragraph fades after the first parsed snapshot and can finish them immediately without recreating the renderer.
- `UI/Paragraph/AppKit/StreamingFade.swift` supplies a bounded tail animation state and an `NSLayoutManager` subclass. It precomputes word/glyph spans on text updates, excludes attachments, and applies alpha only during drawing. It preserves upstream's 500 ms duration, ease curve, and 100 ms word-stagger window, while bounding each paragraph to eight batches, 2,048 UTF-16 units, and 128 drawing spans. The AppKit paragraph bridge replaces upstream per-frame text-storage color edits with this display-only fade, honors Reduce Motion, and stops the weak-target display link when its view is removed or the fade finishes. The host keeps upstream whole-view/table entrance transitions disabled. Measurements are independent of animation progress.

No process-global language state or swizzling is introduced. Image and citation localization remains outside Mira's enabled renderer surface. Focused AppKit measurement and deterministic animation/bitmap regression tests live beside the locale tests. `BlockRetentionTests` additionally verifies native view/selection identity across appends, finite heights after resizing/replacement, and environment propagation through equal content wrappers. Native scrolling evidence is recorded in `docs/engineering/STREAMING_PERFORMANCE.md` and `docs/engineering/LONG_CONVERSATION_PERFORMANCE.md`.
