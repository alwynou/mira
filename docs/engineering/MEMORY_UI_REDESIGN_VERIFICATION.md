# Memory management UI redesign verification

Date: 2026-09-21. Issue: [#38](https://github.com/alwynou/mira/issues/38).
Branch: `codex/memory-ui-redesign`.

## Scope

The Memories management screen is rebuilt to match the approved [design prototype](../../designs/mira-memory/README.md) (2026-09-20). The hero header ("Keep what matters." title, subtitle, and duplicated add button) is removed; search, scope filter, the Current/History segmented control, a result-count caption, and the sort menu now live in the list column. The bare `List` is replaced by a custom `ScrollView` + `LazyVStack` row layout: two-line statement truncation, a single meta line (scope, kind, local-only pill, date), inset rounded selection with hover, and hairline separators that hide next to the selected row. Compact widths below the 790 pt breakpoint keep the list ↔ detail navigation with a Back action.

The detail pane gains a header row (status pill, brain kicker with scope and kind, trailing date), a large reading title, bordered secondary actions from the new `MiraSecondaryButtonStyle`, a fixed-label-width metadata grid, a restructured source card (title row, excerpt, trailing "View original message"), a timeline-style History section, and a hairline footer with the red Forget action and its right-aligned explanation. Detail content is centered in a 580 pt reading column.

All existing accessibility identifiers are preserved except the toolbar add button, which moved from an in-content `memory.add` to the native toolbar item `memory.new` (already declared in `MiraWindowShell`). Editor sheets, citation views, source navigation, forget confirmation, empty states, pagination, and error alerts keep their previous behavior. Two dead localization keys ("Keep what matters." and the hero subtitle) are removed; the result-count caption reuses the existing bilingual `Memories: %lld` entry. Demo runs now size each window once to 1100 × 760 pt (overridable with `--window-size WxH`) so UI tests do not depend on Stage Manager window placement.

## Verification

Local environment: Apple Silicon, macOS 27.0, Xcode 27.0, Stage Manager enabled on a 1728 × 1117 pt display. CI independently targets macOS 15 package execution and macOS 26 app/host execution. Local checks do not establish macOS 15 or macOS 26 runtime acceptance.

- Application Debug build passed with existing unrelated warnings.
- `python3 scripts/check_language_policy.py` passed: 2,238 bilingual strings.
- `MiraUI` / `MemoryManagementUITests` passed both complete flows after the redesign: Chinese/dark at 848 × 618 pt via `--window-size` (72.8 s) and English/light wide (76.7 s). The fixtures exercise creation, search, scope filter, section switch, sorting, editing, replacement, forget confirmation, body-free forgetting, and compact list/detail navigation. Result bundle: `.build/xcode/Logs/Test/Test-MiraUI-2026.09.21_16-25-00-+0800.xcresult`.
- Complete `MiraCompositionTests` suite passed.
- Manual demo run (`--demo --data-directory /tmp/Mira-Vis-EN`, three authored memories) verified keyboard navigation: clicking a row focuses the list and Up/Down arrows move the selection across rows with the detail pane following.

### Native interaction evidence

Final-run UI test captures: [English/light list](evidence/memory-ui-redesign/en-light-list.png), [detail](evidence/memory-ui-redesign/en-light-detail.png), [editor](evidence/memory-ui-redesign/en-light-editor.png), [edit wording](evidence/memory-ui-redesign/en-light-edit-wording.png), [forget confirmation](evidence/memory-ui-redesign/en-light-forget-confirmation.png), [forgotten detail](evidence/memory-ui-redesign/en-light-forgotten.png); Chinese/dark at compact width: [empty list](evidence/memory-ui-redesign/zh-dark-compact-list-empty.png), [detail with back navigation](evidence/memory-ui-redesign/zh-dark-compact-detail.png), [editor](evidence/memory-ui-redesign/zh-dark-compact-editor.png), [edit wording](evidence/memory-ui-redesign/zh-dark-compact-edit-wording.png), [forget confirmation](evidence/memory-ui-redesign/zh-dark-compact-forget-confirmation.png), [forgotten detail](evidence/memory-ui-redesign/zh-dark-compact-forgotten.png).

Manual capture with a populated list: [English/light 1100 × 760 with keyboard-driven selection](evidence/memory-ui-redesign/en-light-populated-keyboard-nav.png).

The earlier test failure mode is environmental: with Stage Manager enabled, freshly opened demo windows tiled to the full stage and corner-drag resizing in XCUITest was unreliable, and the test runner process lacks accessibility permission to size windows directly. The demo window-sizing anchor resolves this without touching production behavior; tests assert the settled frame instead of performing the drag.

## Limits

Hover styling is exercised only through manual pointer use, not automation; selection/hover carry no animation by design. VoiceOver, Reduce Transparency, and Increase Contrast remain unverified for the new row and detail layouts. Native macOS 15 runtime acceptance remains separate work. The demo window-sizing hook is demo-only (`container.isDemo`) and does not affect regular launches.
