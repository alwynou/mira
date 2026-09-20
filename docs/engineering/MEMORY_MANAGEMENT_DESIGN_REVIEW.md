# Memory management design review

Date: 2026-09-20. Baseline: `main` at `0b70e14`.

## Scope and status

The user requested a memory-management interface proposal based on the existing Mira UI, with native implementation deferred until they approve the design. `designs/mira-memory/Memory.html` is the review artifact; its asset status is now `approved`. The user approved native implementation on 2026-09-20. The browser findings below remain design evidence; native implementation and acceptance are recorded separately in [Memory management verification](MEMORY_MANAGEMENT_VERIFICATION.md).

Grounding: the current design-system and visual-identity documents, `MiraTheme.swift` and its existing token export, the conversation-shell source, the synthetic native conversation screenshot from 2026-09-14, and current memory product/service contracts. The proposal keeps the sidebar and adds a list/detail memory destination. It distinguishes wording edits, semantic replacement, archive, and forgetting. The latest automatic-capture contract does not introduce a review inbox.

## Browser verification

The local preview was served on loopback and exercised in the Codex in-app browser with synthetic records only. No personal library, credential, model endpoint, or native app instance was accessed.

- JavaScript syntax checked with `node --check`.
- All preview images loaded successfully; no browser warning/error logs were observed in the checked flows.
- Screenshot review covered the Chinese light 1240 × 780 layout, Chinese dark 850 × 620 detail, English dark minimum-size editing, and Chinese light minimum-size editing. Browser viewport was temporarily set to 1340 × 930 for these logical-window checks.
- Search with an unrelated query produced a clear zero-result state; clearing it restored the list. Selecting the Mira scope showed only the two synthetic Mira memories.
- Editing changed the memory content while preserving the source quotation. Source date/time was subsequently separated from the editable memory's update timestamp in the artifact.
- Replacement moved the previous memory to History. Forgetting the replacement did not reactivate its predecessor.
- Forgetting was revised during review to clear the synthetic body and excerpts while leaving a body-free forgotten history marker. The detail offered no restore action.
- Empty-state preview, manual addition, current/history navigation, source preview, and reset were exercised. A manually added memory defaulted to local-only.
- Minimum-size navigation showed the list first, opened details on selection, and exposed a back action. The edit dialog was constrained within the logical window and its action row made sticky for scrollable forms.

## Limits and follow-up

This is browser design evidence, not native macOS acceptance. The preview approximates the native material and window controls. No Swift build or package/host suite was run because production code and resources were not changed.

Keyboard and VoiceOver coverage is incomplete. Real native sheet geometry, focus restoration, retained list position, Reduce Transparency, Increase Contrast, macOS 15 runtime, and scale/performance still require native verification after implementation is authorized. The prototype does not model storage/revision errors, conflicting replacement proposals, source authorization changes, validity intervals, or provider allowlists. Those domain invariants remain required.

The Chinese prototype strings and synthetic quotations are intentional design content. Engineering notes and implementation identifiers remain English. This review does not approve a production localization change.
