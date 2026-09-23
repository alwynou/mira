# Knowledge management interface proposal

Date: 2026-09-23. Status: **proposed, awaiting user design review**. Scope: [#57](https://github.com/alwynou/mira/issues/57).

The user selected a source list with a right-hand document preview, following Memory's browsing pattern. This document describes the proposed management presentation; it does not mark the native Knowledge destination implemented. The [interactive proposal](../../designs/mira-knowledge/Knowledge.html) and [browser review evidence](../engineering/KNOWLEDGE_MANAGEMENT_DESIGN_REVIEW.md) are separate from native acceptance. Further Memory work is paused at its current delivered state.

## Layout and navigation

Keep Mira's existing conversation-window sidebar, neutral canvas, system typography and 52 pt toolbar. Knowledge becomes a main-pane destination when implemented. Its toolbar owns the single import action. The source list contains title, a short current-content excerpt, scope, updated date and an explicit local-only or failure state. Search covers titles and current source text; scope and status filters stay above the list. Sorting offers recently updated and title order.

The default proposal uses a 320 pt source list and a flexible document pane within a 1280 × 800 review window. At 850 × 620, preserve the sidebar and use list-to-detail navigation. Return preserves list filters and scroll position. These are proposed screen dimensions, not changes to shared native layout tokens or a claim of macOS minimum-frame acceptance.

The reader keeps source title, original filename, size, scope, model-use status and a compact more-actions control visible. Document, Versions and Source info tabs progressively expose detail without crowding the reading surface. The document pane owns its scroll. Original text displays line numbers; rendered Markdown is the default reading view. Search results in the prototype display a matching excerpt; complete production chunk navigation must use the returned version and line range.

## Import and update

Import uses explicit Markdown selection, a target scope and an off-by-default model-use permission. Explain that import saves a copy, does not modify the original and does not create a live file link. Retain the existing 10 MiB/file, 100-file/batch, UTF-8 boundaries. The browser uses sample-file selection, clearly identified as a review control.

Report each file independently: imported, reused duplicate, or failed with an actionable reason. Same-scope identical current content reuses its source without silently changing its existing permission. Same filenames alone never imply replacement.

Update is an explicit action on one source. Its name and scope stay fixed. A successful update selects the new current version while preserving older versions. A failed parse retains the failed version and original bytes, leaves the previous successful current version available, and appears under Needs attention. Initial parse failure has no readable current content. Do not offer a fake historical-version rollback action.

## Versions, citations and permissions

The current version is the ordinary search target. Selecting history shows its date and a historical banner. Previously generated citations resolve to the exact original version and line range. The review scenario demonstrates an answer referencing version 1, lines 14–16 after version 2 exists. Production resolution still requires recorded journal evidence and current authorization.

Model-use status is visible near the source title and editable through a confirmation sheet. Allowing use explains that relevant excerpts and the title can be sent to currently authorized providers within the source's scope. Scope is not permission to disclose.

Revoking model use retains local versions, original user messages, generated answers and thinking. The related citation becomes unavailable, and dependent content is excluded from future model requests. Source management remains locally readable. This follows the [knowledge implementation contract](../architecture/KNOWLEDGE_IMPLEMENTATION.md), rather than treating revoke as deletion.

Deletion requires a confirmation describing the exact source and all retained versions. It clears the source and derived content, including affected generated answers and thinking under the existing privacy contract; original user messages and the original external file remain. There is no undo offer. The HTML action affects only temporary sample state.

## States and implementation boundary

Include populated, empty, no-results, local-only, failed import, failed update with an existing current version, historical reading, unavailable citation and destructive confirmation states. App labels support English and Simplified Chinese; source content remains verbatim. Preserve keyboard focus, list movement, visible controls and existing conversation drafts in the native implementation.

The prototype's All scopes selector combines a finite synthetic corpus for management review. Native reads must enumerate only host-authorized scopes and remain separate from model-visible search authorization. Management pagination, actual filesystem selection, asynchronous progress/cancellation, revision-conflict recovery, large documents, journal provenance, blob integrity and durable privacy maintenance still require implementation-specific work. The small sample parser is not a replacement for MarkdownView.

This increment proposes no PDF import, folder watching, note editor, graph view, external sync or Tasks screen. Native UI behavior, production localization, component previews, token exports and platform acceptance are unchanged.
