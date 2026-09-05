# SwiftStreamingMarkdown vendor

This directory vendors the runtime source of [Microsoft/SwiftStreamingMarkdown](https://github.com/microsoft/SwiftStreamingMarkdown) at commit `5f7c04e0558df6146f90d482edb62cb456986bda` (tag `v0.7.0`). The checkout contributed 152 source files and 11,442 source lines. Upstream `Tests/` and `Examples/` were intentionally not copied.

The package manifest keeps the upstream runtime dependencies and exact versions. It removes the upstream snapshot-testing dependency and snapshot test target because their fixtures are not vendored, then adds `SwiftStreamingMarkdownLocaleTests` for the focused locale helper tests in this directory.

The only runtime changes are:

- `Utilities/String+.swift` adds an explicit locale-to-resource-bundle resolver and optional `Locale` parameters for table, list, code-copy, and text-selection labels. Explicit English and Chinese locales are supported; unsupported locales select the English resource bundle. Calls that omit the locale retain the existing package-default behavior.
- `UI/CodeBlockView.swift`, `UI/OrderedListView.swift`, `UI/UnorderedListView.swift`, `UI/TableView.swift`, and `UI/TextSelection/TextSelectionView.swift` read `@Environment(\.locale)` and pass it to those helpers.
- `Models/MarkdownRenderConfig.swift` and the AppKit/UIKit paragraph adapters pass the selected locale to the built-in text-selection menu.
- `Resources/Localizable.xcstrings` adds the missing `zh-Hans` translations for checked and unchecked task-list accessibility suffixes.

No process-global language state, swizzling, image/citation behavior, or upstream rendering logic was changed. Image and citation localization remains outside Mira's enabled renderer surface.
