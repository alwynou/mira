# Knowledge management interface

Date: 2026-09-23. Status: **design approved for native implementation**. Design: [#57](https://github.com/alwynou/mira/issues/57). Implementation: [#59](https://github.com/alwynou/mira/issues/59).

The user selected a source list with a right-hand document preview and then requested native implementation. Knowledge is a main-pane destination following Memory's browsing pattern. The [interactive design](../../designs/mira-knowledge/Knowledge.html) and [browser review evidence](../engineering/KNOWLEDGE_MANAGEMENT_DESIGN_REVIEW.md) remain design references; [native acceptance](../engineering/KNOWLEDGE_MANAGEMENT_VERIFICATION.md) records the implemented behavior and verification limits. Further Memory work is paused at its current delivered state.

## Layout and navigation

Keep Mira's existing conversation-window sidebar, neutral canvas, system typography and 52 pt toolbar. Knowledge is a main-pane destination. Its toolbar owns the single import action. The source list contains title, a short current-content excerpt, scope, updated date and an explicit local-only or failure state. Search covers titles and current source text; scope and status filters stay above the list. Sorting offers recently updated and title order.

The source list is 320 pt wide. Below a 790 pt main pane, preserve the sidebar and use list-to-detail navigation. Return preserves filters. Native layout dimensions are exported from MiraTheme; runtime window evidence is recorded separately from the prototype’s 1280 × 800 and 850 × 620 review sizes.

The reader keeps the source title (the original imported filename), selected-version size, scope, model-use status and a compact more-actions control visible. The source stores no external path or live link, and an update preserves the original title. Document, Versions and Source info tabs progressively expose detail without crowding the reading surface. The document pane owns its scroll. Original text displays line numbers; rendered Markdown is the default reading view. A body search selects the returned current version and chunk, opening a bounded document page at that chunk and exposing the exact line range. Reading pages contain up to 16 chunks; Previous and Next replace the visible page. The version list shows at most 100 recent versions and explicitly indicates additional retained history; existing citations may still resolve older exact versions.

## Import and update

Import uses explicit Markdown selection, a target scope and an off-by-default model-use permission. Explain that import saves a copy, does not modify the original and does not create a live file link. Retain the existing 10 MiB/file, 100-file/batch, UTF-8 boundaries. Native import uses the macOS file picker. Cancellation stops before the next file and lets an admitted write settle; per-file results remain visible until the sheet closes.

Report each file independently: imported, reused duplicate, or failed with an actionable reason. Same-scope identical current content reuses its source without silently changing its existing permission. Same filenames alone never imply replacement.

Update is an explicit action on one source. Its name and scope stay fixed. A successful update selects the new current version while preserving older versions. A failed parse retains the failed version and original bytes, leaves the previous successful current version available, and appears under Needs attention. Initial parse failure has no readable current content. Do not offer a fake historical-version rollback action.

## Versions, citations and permissions

The current version is the ordinary search target. Selecting history shows its date and a historical banner. Previously generated citations resolve to the exact original version and line range. The existing citation sheet continues to require recorded journal evidence and current authorization before showing the referenced version and lines; management browsing grants no additional model access.

Model-use status is visible near the source title and editable through a confirmation sheet. Allowing use explains that relevant excerpts and the title can be sent to currently authorized providers within the source's scope. Scope is not permission to disclose.

Revoking model use retains local versions, original user messages, generated answers and thinking. The related citation becomes unavailable, and dependent content is excluded from future model requests. Source management remains locally readable. This follows the [knowledge implementation contract](../architecture/KNOWLEDGE_IMPLEMENTATION.md), rather than treating revoke as deletion.

Deletion requires a confirmation describing the exact source and all retained versions. It clears the source and derived content, including affected generated answers and thinking under the existing privacy contract; original user messages and the original external file remain. There is no undo offer. The native action uses revision-bound library maintenance and clears body-bearing presentation caches before rebinding.

## States and implementation boundary

Include populated, empty, no-results, local-only, failed import, failed update with an existing current version, historical reading, unavailable citation and destructive confirmation states. App labels support English and Simplified Chinese; source content remains verbatim. Preserve keyboard focus, list movement, visible controls and existing conversation drafts in the native implementation.

All scopes enumerates the local library for owner management. Inbox means only unscoped sources; a Workspace filter is exact. These queries are distinct from model-visible search, which retains its authorization rules. The list uses keyset pagination and bounded current-content excerpts. Document pages validate scope, version ownership and blob integrity. Import and permission changes use frozen source revisions; conflicts require refresh rather than implicit overwrite.

This increment includes no PDF import, folder watching, note editor, graph view, external sync or Tasks screen. English and Simplified Chinese labels surround verbatim source content. Native visual evidence, focused tests and unverified platform checks belong in the engineering verification document.
