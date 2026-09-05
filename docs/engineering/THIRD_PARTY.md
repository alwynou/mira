# Third-party notices

MiraMac embeds SwiftStreamingMarkdown v0.7.0 (MIT), vendored from commit `5f7c04e0558df6146f90d482edb62cb456986bda` with a small patch to honor the selected UI locale. Source provenance and changed files are listed in [UPSTREAM.md](../../Vendor/SwiftStreamingMarkdown/UPSTREAM.md). Runtime dependency versions remain locked; upstream examples and snapshot fixtures are excluded.

MiraKit also uses GRDB.swift 7.11.1 (MIT); its license is included in the same resource.

The renderer package graph includes these source packages:

- Equatable 1.4.1 — MIT
- HighlightSwift (locked revision) — MIT
- iosMath (locked revision) — MIT
- swift-markdown 0.7.3 — Apache-2.0
- SwiftUI-Shimmer 1.5.1 — MIT
- swift-syntax 603.0.2 — Apache-2.0
- swift-cmark 0.8.0 — BSD-style

The exact license texts remain in the corresponding locked SwiftPM checkouts and are included in the app's third-party notices resource.
The resource also includes the bundled highlight.js license, iosMath font license, and swift-markdown notices.
