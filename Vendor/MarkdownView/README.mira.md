# Mira MarkdownView source dependency

Source: https://github.com/Lakr233/MarkdownView

Base revision: `757b6fcc4b3095e84f4c0613f4b98147f49dcd09`.
The upstream MIT license is retained in `LICENSE`. Sources and tests are copied
verbatim except for the macOS code viewport changes listed below. Upstream
comments and resources retain their original languages.

Mira uses this local dependency because code views are internal to MarkdownView;
the public integration surface previously offered no bounded code viewport.
No generated package checkout is patched by the build.

Local changes:

- `MarkdownTheme.swift`: configurable macOS code block maximum height.
- `CodeView.swift`: bounded intrinsic height and scroll hit testing, including
  the gutter; the original selectable code document and copy action are retained.
- `CodeViewConfiguration.swift`: two-axis scrolling, a stable accessibility
  identifier, scroller clearance, and a clipped gutter synchronized to the document's vertical offset.
- `HorizontalScrollView.swift`: opt-in vertical scrolling for code only; short
  blocks and tables continue forwarding vertical gestures to the transcript.

Mira's theme supplies the height token. The same bounded intrinsic height is used
for Markdown paragraph reservation and native block placement. Verification lives
in `Tests/MiraPlatformTests/MiraMarkdownViewTests.swift` and the focused code-scroll
cases in `Tests/MiraUITests/ConversationFlowUITests.swift`.
