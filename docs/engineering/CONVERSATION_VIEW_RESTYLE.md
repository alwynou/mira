# Native shell and conversation restyle

Date: 2026-09-07

Scope: the application shell and conversation views only, following the portable SwiftUI mapping in `designs/mira-macos26/STYLE_GUIDE.md`. Visual acceptance is pending the user's review. Memory, knowledge, tasks, and settings content have not been restyled.

## Implementation

- Retain `NavigationSplitView` and native sidebar vibrancy. Use a plain Mira title, fixed primary destinations, a separator, expandable workspace folders, flat temporary conversations, and a Settings footer. Keep existing archive, workspace editing, navigation, and feature-sheet actions.
- Retain the on-demand `.inspector` with an opaque content background. The native sidebar toggle and window controls remain system-owned.
- Put the composer and existing memory extraction disclosure in a bottom safe-area inset. The composer uses native glass on macOS 26 and thin material on macOS 15, with no copied prototype shadows or alpha values. Keep model selection, send/cancel shortcuts, retry-save, unavailable-model warnings, and memory approval flows.
- Display a compact process disclosure and final answer per assistant execution. Derive the final suffix from the existing accumulated text and ordered trace. Thinking and tool results share a subtle surface; tool arguments and opaque continuation data are excluded from this view. Existing citations, invalidation tags, source navigation, text selection, and renderer animation remain available.
- Apply a neutral palette and compact reading typography through the Markdown renderer's public configuration. No vendor source changes.

No changes to presentation models, application runtime, provider adapters, persistence, or schemas. Tool progress is limited to facts available in existing snapshots; the view does not introduce an audit polling stream or fabricate results. Execution duration uses persisted creation and terminal timestamps.

## Verification

- Required Debug app build passed with the pinned dependency and macro-validation flags on macOS 26.6.2.
- `swift test --package-path Packages/MiraKit`: 389 tests in 43 suites passed.
- `MiraHostTests`: 67 tests in 14 suites passed, including five new display-projection tests covering multiple rounds, draft/trace timing, interrupted tool calls, thinking-only replies, and retained history after tool trace cleanup.
- Language policy, including compiler-extracted strings, passed with 1,283 bilingual catalog entries.
- `MiraUI`: all four existing native tests passed (128.825 seconds): cancellation restores input, English and Chinese conversations survive relaunch, and the task sheet's edit/complete/reopen workflow remains reachable. These use isolated offline fixtures.
- Native review confirmed folder expansion, neutral selection, editable composer state, completed-process reopening, individual thinking/tool disclosures, a single final answer, and an opaque inspector. At the bottom of the narrowed transcript with the inspector open, the final paragraph remained visible above the composer. The two review screenshots show the collapsed and expanded states.
- The screenshot transcript was seeded into a separate offline demo library. It is synthetic display evidence for multiple tool calls, not evidence that a live provider executed those tools. No paid model requests were made.

The visual pass found that Tahoe resolves both `textBackgroundColor` and `controlBackgroundColor` to white in light appearance. The system's alternating content background now provides the subtle bubble/output surface while retaining semantic colors and automatic appearance adaptation. Glass and shadows remain system-owned.

The final source review also moved tool-observation decoding behind the expanded disclosure; collapsed tools do not parse their historical output on each streaming snapshot. The app build and host projection tests were rerun after that change.

## Remaining acceptance

The user has requested a review checkpoint after this surface. macOS 15 runtime behavior, accessibility technologies, and full live-provider/tool timing remain separate acceptance work. Compiling with a macOS 15 deployment target does not constitute testing on macOS 15. Other feature surfaces remain outside this change.
