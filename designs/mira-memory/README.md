# Memory management design proposal

Status: **approved for native implementation** on 2026-09-20. Created 2026-09-20 against `main` at `0b70e14`.

This is a browser-based, interactive design proposal. The user requested visual review before any native implementation. This artifact remains a browser proposal; native implementation and verification are tracked separately in `docs/engineering/MEMORY_MANAGEMENT_VERIFICATION.md`.

## Preview

Run `python3 -m http.server 4311 --bind 127.0.0.1 --directory designs` from the repository root, then open `http://localhost:4311/mira-memory/Memory.html`.

The preview fits a 1240 × 780 logical window into the available browser panel. The `850 × 620` control shows the minimum-size proposal. All mutations affect temporary synthetic state only. Reload or Reset restores the samples. No network requests are made beyond loading this local artifact.

## Design decisions

- Keep the existing conversation-window navigation, neutral palette, system typography, subdued sidebar, and compact native-style controls. Use a memory list and reading/detail pane within that shell.
- Put content first in the list. Show scope and kind as secondary information, with an explicit local-only exception. Search is a literal prototype filter, not a demonstration of production semantic search quality.
- Default to current memories. History contains superseded, archived, and body-free forgotten records. Automatic extraction does not create a review inbox.
- Keep the original quotation, conversation title, scope, and remote-use permission visible in details. The source button opens a synthetic source preview; the eventual native implementation should navigate to the identified committed message while preserving the memory browsing state.
- Separate wording edits from a changed fact or preference. Replacement creates a new current record and leaves the previous one superseded. Forgetting its replacement never revives an older record.
- Existing scope stays read-only when editing or replacing. New manual memories choose Global or a workspace. Remote-use consent is separate from scope and sensitivity. Marking a record sensitive defaults it to local-only.
- Forget requires a precise confirmation. Clear the memory body and source excerpts, retain a body-free forgotten marker, and explain that original conversation messages remain locally readable. Do not offer an undo action for forgetting.
- At minimum width, switch the content area to list-to-detail navigation with a back action. Keep the application sidebar. Detail content scrolls independently.

The simplified preview does not model competing replacement proposals, revision conflicts, invalid/expired memories, source permission revocation, large libraries, storage errors, provider allowlists, or validity-date editing. These are native implementation requirements to resolve after design selection, not claims that those existing contracts can be removed. The current Global/Mira filter enumerates synthetic scopes; production management must query only scopes the host authorizes.

## Visual references

- `docs/product/DESIGN_SYSTEM.md`, `docs/product/VISUAL_IDENTITY.md`.
- `Apps/MiraMac/DesignSystem/MiraTheme.swift` and its export `designs/mira-ui/tokens.json`.
- Existing conversation shell in `Apps/MiraMac/Features/Conversation/ConversationView.swift`.
- Native synthetic acceptance screenshot `docs/engineering/evidence/2026-09-14-settlement-en-light-completed.png`.
- macOS window-chrome structure adapted from the baoyu-design `macos-window.jsx` reference. Actual native glass, controls, accessibility, and rendering remain system-owned in the future implementation.

There is no compiled baoyu design-system manifest in this repository. The prototype consumes the existing Swift token export as a visual reference without creating a competing token source or changing the export. The HTML, CSS, and JavaScript are a design artifact, not an app implementation.

## Assets and language

`assets/*.png` are monochrome SF Symbols rendered from the installed macOS AppKit symbol catalog for this local Apple-platform design review. Production continues to use system symbols directly; these raster previews are not a new product icon library.

Chinese in `Memory.html` and `memory.js` is intentionally limited to localized prototype copy and synthetic user-authored quotations. Switching to English translates app-owned labels while preserving the example user's original Chinese content. Identifiers, comments, and engineering documentation are English.

Verification evidence and unverified native checks are recorded in `docs/engineering/MEMORY_MANAGEMENT_DESIGN_REVIEW.md`.
