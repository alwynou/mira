# Bounded code block scrolling

Date: 2026-09-14. Branch: `codex/agent-core`. Host: macOS 26, Apple Silicon.

## Investigation and behavior

The reported final code block could not reveal its obscured tail. The existing
MarkdownView code view disabled vertical scrolling and forwarded vertical gestures;
the transcript event monitor intercepted vertical wheel events except over tool
input/output. A standalone mixed-script terminal-code geometry probe did not
recreate the exact reported clipping, so no height-estimation root cause is claimed.
The user's follow-up explicitly requires a maximum height for every code block.

Code blocks now grow up to `MiraTheme.Markdown.maximumCodeBlockHeight` (320 pt,
including the fixed language/copy toolbar). Taller text keeps its full natural
height inside a vertically and horizontally scrolling native viewport. The same
capped intrinsic size reserves the Markdown attachment paragraph and places the
block. The gutter scrolls with the text. The transcript yields the dominant wheel
axis to code that overflows on that axis; short blocks preserve outer scrolling.
Copying and selecting still operate on the original complete code text.

Native screenshot review caught a second problem: the overlay horizontal scrollbar
covered the last line immediately after scrolling. The viewport now reserves the
native scroller thickness in its document's bottom/right padding, including that clearance in
natural block height and gutter geometry. The terminal-line regression asserts
clearance above the scrollbar, not only a scrollbar value of 1.

The pinned MarkdownView revision is now a local source dependency under
`Vendor/MarkdownView`. Its internal code view had no public bounded-height hook.
Only four upstream implementation files differ; the source revision, MIT license,
and local changes are documented in `README.mira.md`. Transitive dependency
versions are unchanged. No generated package checkout is modified by the build.

## Focused verification

- `MiraMarkdownViewTests.terminalCodeBlockFits(dark:)`: passes both appearances,
  streaming open/closed fences, short-to-long growth, widths 320/760 pt, final
  blocks and following prose. Checks capped height, complete document ranges,
  vertical/horizontal end reachability, gutter alignment, and scrollbar clearance.
  Final host result: `.build/xcode/Logs/Test/Test-MiraHostTests-2026.09.14_22-14-31-+0800.xcresult`.
- `streamedAttachmentsKeepTheirReservedHeight(reduceMotion:)`: both cases passed
  after the capped viewport integration, covering code/table/following-text layout.
  Result: `.build/xcode/Logs/Test/Test-MiraHostTests-2026.09.14_22-07-13-+0800.xcresult`.
- Native UI cases use `--demo --verify-code-scrolling` with an isolated disposable
  library and deterministic local streaming. The fixture has a short code block,
  45 wide code lines, and `CODE BLOCK END` inside the final fence. They check the
  vertical scrollbar reaches 1 and the horizontal scrollbar moves. Screenshots
  separately establish that the final line is visible above the composer.
- XcodeGen and token export regenerated the project and design token JSON.
  Language policy and whitespace checks passed. No unrelated package suite ran.

## Evidence and limits

Both native UI cases passed. Final app build/UI result:
`.build/xcode/Logs/Test/Test-MiraUI-2026.09.14_22-14-59-+0800.xcresult`.
Screenshots: [light/English](evidence/2026-09-14-code-scrolling-en.png) and
[dark/Chinese](evidence/2026-09-14-code-scrolling-zh.png). The requested narrow resize targets 850×620; the native shell constrains
the observed window to 850×672 on this host. This change does not alter window
minimum sizing. Verification is confined to code rendering and scrolling; it does
not cover provider calls, caches, model metadata, or other application workflows.
No personal conversation was exported into fixtures. macOS 15 runtime and physical
trackpad momentum are unverified.
