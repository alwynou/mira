# Knowledge management design review evidence

Date: 2026-09-23. Scope: [#57](https://github.com/alwynou/mira/issues/57). Status: browser prototype verified for design review; user approval and native implementation remain pending.

## Artifact and environment

The artifact is `designs/mira-knowledge/Knowledge.html`, with local CSS, JavaScript, bilingual resources and SF Symbol previews. It was served on loopback using Python's HTTP server and inspected in the Codex in-app browser. The browser viewport was 1280 × 720. The standard 1280 × 800 logical app frame was proportionally fitted to that viewport; compact checks used a measured 850 × 620 logical frame. Browser scaling is not a macOS window-size measurement.

No production application source, catalog, design token or runtime data changed. No native app or paid model was launched. All mutations below affected only the prototype's authored sample data and were reset afterward.

## Observed checks

| Check | Observed result |
| --- | --- |
| Initial browse | Six sample sources, scope/status/sort controls, selected document and readable current-version metadata. |
| Search and scope | `原文件` returned the expected one current source with a highlighted excerpt. An absent phrase showed no results. Field Notes restricted the list to its one sample. Failed file error copy did not count as searchable document content. |
| History | Version 1 opened with a historical notice; the selector retained version 2 as current. |
| Citation | The historical-citation scenario opened version 1 and highlighted exactly lines 14–16 with the expected source text. |
| Revoke | Confirmation distinguished local retention from remote context use. Confirming replaced cited content with an unavailable state. |
| Import | Model-use permission started off. Sample selection enabled import. The default Mira batch produced one import, one duplicate reuse and one actionable UTF-8 failure. The new source was locally readable and marked local only. |
| Update | Failed version 2 preserved current version 1 and its body. A subsequent valid update created version 3 while retaining both previous versions. |
| Delete | Confirmation disclosed affected generated answers/thinking and retention of original user messages/external file. Cancel retained the selected source; confirm removed the sample. |
| Compact navigation | The frame measured 850 × 620. List was visible and reader hidden initially; selecting opened the reader, and Back returned to the list. |
| Language and appearance | Visually inspected all four Chinese/English × light/dark compact reading combinations, plus Chinese/light and English/dark standard browsing. Source content stayed Chinese while app labels switched to English. |
| Empty and initial failure | English/light empty library and English/dark parse failure showed appropriate actions and guidance. |
| Browser diagnostics | No error/warning console entries at inspection. No missing loaded images. Inspected reader tabs, top row, footer, toolbar and filter row had no horizontal DOM overflow in the compact English/light reading state. |

Screenshots are retained under [`designs/mira-knowledge/evidence/`](../../designs/mira-knowledge/evidence/): `browse-zh-light.png`, `browse-en-dark.png`, all four `compact-{zh,en}-{light,dark}.png` combinations, `citation-zh-light.png`, `import-zh-light.png`, `delete-zh-light.png`, `empty-en-light.png`, and `failure-en-dark.png`.

During review, the prototype was adjusted to classify failed updates as Needs attention even when a prior current version remains searchable, use natural bilingual version-count copy, and bring scenario-selected rows fully into view. These are prototype refinements, not native behavior changes.

## Verification boundary

JavaScript syntax, parity of all 153 bilingual resource keys, local asset references and whitespace passed. The repository language-policy check passed with 2,255 existing bilingual catalog strings. The existing repository language-policy check is independent of this prototype's translation resources. App/package/host suites were not run because the change contains design artifacts and documentation only. Required repository CI still applies to the PR.

The HTML Markdown reader only implements the authored examples. It does not establish real Markdown parsing, remote-content safety, full keyboard/VoiceOver semantics, Reduce Transparency, Increase Contrast, native glass, asynchronous progress/cancellation, filesystem access, source authorization, maintenance recovery, performance at scale or macOS 15 runtime acceptance. Native production integration must use the existing domain and rendering contracts. This proposal does not close M3 or M4 release gates.
