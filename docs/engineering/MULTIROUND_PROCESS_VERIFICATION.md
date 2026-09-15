# Multiround conversation process verification

Date: 2026-09-14. Host: macOS 26.6.2, Apple Silicon, Xcode 26.6.
Scope: ordered activity, process disclosures, tool payloads, and completion rendering.

## Final behavior

Session queries assemble ordered model-attempt blocks and correlate each tool call
with its arguments, lifecycle, and full returned content. Live blocks overlay only
their own attempt; reopening reads the same journal-backed sequence. Reads remain
budgeted and privacy-bound. Opaque continuation and request bodies are not rendered.

The presentation follows [DeepSeek Harness at c291e796](https://github.com/deepseek-ai/deepseek-harness/tree/c291e7961a515f6d7af9304e7fd1d257929aef26),
particularly `turn-process.ts`, `ReasoningRow.tsx`, `TurnProcessNodeView.tsx`,
`DisclosureRow.tsx`, and `ToolRow.tsx`/`ToolRow.module.css`.

- Running ordered turns have no duplicate turn-level disclosure header. Collapsed
  reasoning shows the latest line while running and the first line when settled;
  expansion shows the full text and hides the duplicate summary.
- Completed process groups include the final reasoning block. Only the trailing
  final answer remains outside. Reasoning and tools expand independently.
- Generic tool rows show their lifecycle icon and an argument-derived summary, or
  a failure summary. Expanded cards retain selectable Input/Output sections.
  Unavailable and purged content are explicit; stored arguments remain verbatim.
- JSON removes whitespace only outside strings, preserving number and escape
  spellings, and uses one horizontally scrolling line. Non-JSON retains line breaks
  and bounded vertical scrolling. Overflowing tool sections receive wheel input;
  vertical gestures over single-line JSON continue scrolling the transcript.
- Font-sized, aspect-preserving SF Symbols use `chevron.right` when collapsed,
  `chevron.down` when expanded, `wrench.fill` for tools, and `xmark.circle.fill`
  for failures. Chevrons appear after the label on hover or keyboard focus. Overflow
  places the chevron over a transparent-to-canvas trailing gradient without reflow.
  Failed trigger text and the leading icon are tinted; the chevron stays neutral.
- Completion preserves final Markdown view identity and selection. Folding earlier
  process content can move the answer, but does not clear or recreate its renderer.

## Focused evidence

- Core: 19 tests in `SessionActivityTests`, `AgentLiveOutputIntegrationTests`, and
  `SessionOutputTests` passed. Coverage includes nine tool rounds plus a final
  answer, complete argument/results, retained drafts, byte budgets, privacy
  invalidation, and live block delivery. Log: `/tmp/mira-multiround-core.log`.
- Native row/state, page-state, and localization checks: 25 passed in
  `.build/xcode/Logs/Test/Test-MiraHostTests-2026.09.14_16-43-32-+0800.xcresult`.
  These cover final reasoning folding, interleaving, independent expansion, final
  view/selection identity, and preceding results surviving a live overlay.
- Multiround English/light and Chinese/dark reopening cases passed in
  `.build/xcode/Logs/Test/Test-MiraUI-2026.09.14_16-43-56-+0800.xcresult`.
- DSH reasoning/tool-card refinement: 12 row tests and focused localization passed
  in `.build/xcode/Logs/Test/Test-MiraHostTests-2026.09.14_17-04-04-+0800.xcresult`.
- Hover/compact JSON: 14 row tests passed in
  `.build/xcode/Logs/Test/Test-MiraHostTests-2026.09.14_17-27-37-+0800.xcresult`.
  Coverage includes hover geometry, expansion, compact JSON preservation, and
  bounded non-JSON content. Both native appearance cases also passed.
- SF rendering passed both appearance cases in
  `.build/xcode/Logs/Test/Test-MiraUI-2026.09.14_18-00-44-+0800.xcresult`.
  The final right/down direction and neutral failure-chevron correction passed
  English/light in `.build/xcode/Logs/Test/Test-MiraUI-2026.09.14_18-02-25-+0800.xcresult`.
  That last visual correction was not separately rerun in dark mode.

The fixture uses `--demo --verify-multiround-flow`, optionally
`--verify-tool-presentation`, with isolated temporary libraries and deterministic
source reads. DEBUG authorization requires the exact fixture descriptor, demo
route/connection, valid schema, read-only effect, and empty sources/targets.
Production tool registration is unchanged. No paid endpoint or personal library
is used. Native windows measured 850 × 672 pt.

## Retained visual evidence

Intermediate icon/card screenshots were removed during commit preparation; result
bundle references above retain the verification history. Retained captures cover
the distinct reasoning states and final SF presentation:

- [One initial reasoning summary](evidence/2026-09-14-dsh-initial-thinking.png)
- [Expanded reasoning without duplicate summary](evidence/2026-09-14-dsh-thinking-expanded.png)
- [Collapsed right arrow and overflow](evidence/2026-09-14-sf-en-overflow-hover.png)
- [Expanded down arrow](evidence/2026-09-14-sf-en-expanded-hover.png)
- [Failed trigger with neutral arrow](evidence/2026-09-14-sf-en-failed-hover.png)
- [Expanded failed trigger](evidence/2026-09-14-sf-en-failed-expanded.png)
- [SF wrench and compact tool card](evidence/2026-09-14-sf-en-compact-json.png)

## Limits

The failed fixture has no retained result body and shows the localized unavailable
placeholder. Larger activity reads can exceed the bounded payload budget; pagination
was not expanded. Specialized terminal/image/diff/web tool cards are outside scope.
Live provider variation, VoiceOver, accessibility appearance variants, physical
trackpad momentum, macOS 15 runtime, and Intel hardware remain unverified. These
focused checks do not claim unrelated feature or full-suite acceptance.
