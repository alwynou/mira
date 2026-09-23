# Knowledge management design proposal

Status: **needs user review**. Created 2026-09-23 for [issue #57](https://github.com/alwynou/mira/issues/57), from `main` at `67d83e7`. The user selected **source list with a right-hand document preview**, consistent with Memory. Further Memory work is paused by the user's instruction.

## Preview

Run `python3 -m http.server 4311 --bind 127.0.0.1 --directory designs` from the repository root, then open `http://localhost:4311/mira-knowledge/Knowledge.html`.

The page fits a 1280 × 800 logical window into the available browser panel. The `850 × 620` control switches to a compact list-to-detail layout. Appearance, interface language, empty library, historical citation and failed-import controls live outside the proposed app window. Reset restores sample state. Design notes can be shown or hidden.

All source content, names, sizes, timestamps and interactions are authored synthetic fixtures. File selection uses built-in samples. No personal files, credentials, native services or model endpoints are accessed. State lasts only until reset or reload. All scripts, styles and symbol assets are local; there are no runtime dependencies or third-party network requests.

## Review scope

- Search titles/current document text, filter by scope and availability, sort and select sources.
- Read Markdown or line-numbered original text; inspect source information and historical versions.
- Import sample files with local-only default, explicit model-use choice and separate imported/duplicate/failed results.
- Explicitly update a source. A failed new version does not replace the previous searchable version.
- Allow or revoke model use with distinct consequences. Source management can read a local-only source; a revoked conversational citation cannot display its body.
- Inspect a historical citation at version 1, lines 14–16. This demonstration is separate from real journal-backed citation authorization.
- Cancel or confirm synthetic deletion with the actual domain contract's impact on dependent generated answers and thinking.

The owning proposal is [Knowledge management design](../../docs/product/KNOWLEDGE_MANAGEMENT_DESIGN.md). Browser evidence and limitations are in [design verification](../../docs/engineering/KNOWLEDGE_MANAGEMENT_DESIGN_REVIEW.md). No application implementation or domain contract changed. M4 native management remains pending.

## Visual references

- `docs/product/DESIGN_SYSTEM.md` and `docs/product/VISUAL_IDENTITY.md`.
- `Apps/MiraMac/DesignSystem/MiraTheme.swift` via `designs/mira-ui/tokens.json`.
- Existing `designs/mira-memory/Memory.html`, its shell and interaction conventions, and `Apps/MiraMac/Features/Memory/MemoryManagementView.swift`.
- macOS window anatomy from the baoyu-design `macos-window.jsx` reference. Native material and window behavior remain owned by macOS in any future implementation.

This repository has no compiled baoyu `_ds_manifest.json`. The existing Swift token export is a binding visual reference, without introducing another authoritative token file. `_d_meta.json` records the proposal as `needs-review`; merging its files does not approve the design or implement the app screen.

## Assets and language

`assets/*.png` are monochrome SF Symbols rendered from the installed macOS AppKit catalog for local Apple-platform design review. Existing relevant previews were copied from `designs/mira-memory/assets`; additional document/import symbols were rendered using AppKit. Native implementation continues to use system symbols directly. Screenshots in `evidence/` contain only this prototype's synthetic content.

Chinese in `content.js` is limited to prototype translation resources and authored Unicode/search fixtures. Source documents and synthetic conversation titles remain verbatim across language changes. Identifiers, comments and engineering documentation are English. The prototype does not alter the production localization catalog.
