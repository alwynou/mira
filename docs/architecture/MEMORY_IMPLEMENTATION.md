# Memory implementation contract

**Status:** implementation contract for the current manual memory increment. This document describes the intended Core boundary; the increment is not accepted until its persistence, privacy, and quality evidence is recorded.

The manual increment provides a local, user-reviewed Memory path. It does not silently add automatic extraction or claim real-model quality. The broader product semantics remain in [Memory and Knowledge](MEMORY_AND_KNOWLEDGE.md).

## Core objects and scope

The first supported scopes are `global` and `workspace(workspaceID)`. A global Memory belongs to the user and has no workspace identity. A workspace Memory has a valid workspace identity and is visible only in that workspace. The supported subjects are `user` and `workspace`; a workspace subject requires a workspace scope. Store methods validate these relationships rather than trusting a caller-supplied scope.

Memory states are `active`, `candidate`, `archived`, `rejected`, and `removed`. A manually reviewed explicit save creates an active Memory after its transaction commits. Candidate, archived, rejected, removed, superseded, deleted, forgotten, and expired Memories are excluded from ordinary recall.

Memory drafts validate non-empty content, an 8 KiB UTF-8 limit, compatible scope and subject, and a strictly increasing validity interval. The persisted model also retains sensitivity, remote-use permission, connection restrictions, and temporal bounds so local storage and remote disclosure remain separate decisions.

## Evidence and write intent

Evidence is either an exact committed user `Message` or an explicit `manualEntry`. A manual entry has its own stable source identity, revision, hash, actor, and timestamp; it is never represented as a synthetic Message. Message evidence is resolved by the Store from the committed message ID and revision, so a caller-provided excerpt cannot establish authorship. Evidence metadata may survive body redaction, while excerpts and hashes that disclose forgotten content are removed or redacted.

Manual creation is an explicit reviewed operation. Its durable `operationID` makes retries idempotent: reusing an operation ID with a different payload fails. The operation ID is separate from the business deduplication key, which combines the source identity and revision with subject, scope, and a normalized assertion fingerprint. A retry identity answers “is this the same operation attempt?”; the business key answers “is this the same assertion?”

The `memory.remember` tool is a bounded write path for this increment. Every tool-created draft sets `allowsRemoteUse` to `false`, including drafts whose sensitivity flag is `standard`; the model cannot turn a missing or false sensitivity flag into permission to disclose the memory remotely. The user may make a separate, visible disclosure choice in the Memory editor. Direct authorization is limited to an anchored, complete explicit remember prefix with current scope, an exact quote, and no sensitive capture; all other proposals use host approval. The broader remote-reuse confirmation policy remains deferred pending a user decision.

When source/assertion deduplication reuses an existing memory, it preserves that memory's reviewed disclosure policy. The tool's `allows_remote_use` receipt reports the committed memory's actual policy; it must not describe a reused, remote-enabled memory as local-only.

Automatic extraction is a later increment. When enabled, it requires explicit settings, a selected extraction route, a budget, source and scope validation, and the documented triage rules. Clear stable user statements may become active with undo feedback; inferred, sensitive, conflicting, ambiguous, or low-confidence results remain candidates or are rejected. No background extraction runs while the setting is disabled, and no model response claims a Memory exists before the committed receipt.

## Revisions and replacement

Text or metadata corrections preserve the Memory ID and increment its revision using an expected-revision check. A semantic change creates a new Memory ID and a durable replacement relation. The relation, current projection, and retrieval visibility change commit atomically. A competing replacement remains proposed and leaves the previous current projection unchanged until the user resolves it. Replacement validation requires compatible subject, scope, and time semantics, and rejects self-reference or cycles. Forgetting the newer Memory never resurrects the previous one automatically.

Competing replacement review displays the proposed body and the actual current successor. Confirmation includes both displayed revisions and the reviewed successor ID. The transaction verifies that the successor belongs to the proposed chain, rejects the old proposal, confirms the new relation, and updates both projections. Stale revisions require an explicit reload and review. Rejecting a candidate also resolves its pending proposal as rejected.

## Store and recall boundary

The Core `MemoryStore` owns bounded atomic operations for listing, detail, explicit creation, revision, state changes, forgetting, recall, usage recording, and usage validation. The application actor is the UI entry point; views do not access persistence directly. The same recall port is used by prefetch and Memory tools.

Opening a memory from an extraction result clears the management search and selects all states. The requested detail is authorized independently of the first 100 list results, and a selected memory outside that page receives a supplementary row. A workspace change invalidates both list and detail loads; deep links never expand the caller's scope.

Every recall path applies the same hard filters: authorized user and workspace scope, matching subject, `active` state, current projection, non-deleted and non-forgotten status, valid time interval, remote-use permission, and the selected provider connection restriction. Candidate, rejected, removed, archived, superseded, and expired records never enter ordinary context. Direct detail and history access enforce authorization and redaction as well as search. Results are bounded and deterministically ordered; a truncation indicator is retained when the limit is reached.

A Memory derived from a workspace message also inherits that original workspace's current outbound permission and connection allowlist, including when the Memory itself is global. Recall applies this intersection before limiting search candidates and rechecks it before dispatch. Moving a derived fact to global scope does not override its source's disclosure restriction. Local evidence inspection remains available within the authorized library.

Recording a recall usage binds a Memory ID and revision to the execution before dispatch. The Store validates the current Memory state, revision, scope, and disclosure policy. Capture links connect an explicit source or successful tool save to its originating execution for cleanup; they do not grant remote recall permission. Recall takes precedence when an execution has both kinds of usage. Historical backup validation resolves the recorded revision and does not require it to remain the current revision. Live recall dispatch does require the current revision.

The exact citation format is `[memory:<UUID>@<revision>]`. The transcript exposes reference buttons below the Markdown reply; the request inspector exposes the same resolver. A syntactically valid model reference is insufficient: local resolution requires recorded usage by that execution, the correct conversation and scope, an available exact revision, and no purge marker. Older revisions are loaded directly rather than relying on the bounded management history list. Unknown, forged, and forgotten references do not open content. Editing a Memory does not silently retarget an old reply's citation.

Forgetting or policy changes invalidate queued requests that contain the Memory and require context rebuilding. Already sent provider data cannot be withdrawn.

## Forget and late-writer protection

Forget is one transaction that marks the Memory unavailable, removes its body and evidence excerpts, invalidates search and derived projections, records durable source suppression, and identifies affected execution bodies. It retains body-free suppression metadata, evidence identity and disposition, replacement facts, deletion reason, and terminal audit state. The original user message remains available to explicit local history unless the user separately requests source deletion; its source identity is suppressed from automatic history and extraction.

Execution history dependencies retain body-free links between a request and the earlier turns included in its history. These links exist before any Memory is created. Therefore an explicit save from an older user message, followed by forgetting, can identify the original reply and later replies whose requests included that history. Cleanup traverses these dependencies and clears the affected generated replies, drafts, request/output snapshots, steps, and tool arguments/results. Original user messages remain locally visible. Unrelated executions are retained.

Mixed generated text and model request bodies cannot reliably be partitioned after paraphrasing. For affected executions, the implementation purges the complete body and records a marker; it does not claim word-level redaction. Provider receipt and post-send withdrawal are outside Mira’s control.

The Store records `bodyPurgedAt` (or the equivalent payload state) for every body-bearing object it redacts. It retains stable IDs, roles, names, revisions, status, timing, route metadata, and a body-free deletion reason. Every writer—message, draft, request snapshot, model output, tool arguments/results, usage, and terminal update—checks the purged execution or attempt inside the same transaction. After the synchronous transaction commits, the application actor clears live drafts and cancels affected tasks before returning to asynchronous work. The durable write guard protects against other store instances and late provider events.

Suppression is source-wide and durable. Restoring an archived, rejected, or removed Memory does not authorize automatic extraction from the whole original source. An explicit new user-reviewed save may create a new Memory after forgetting; replaying the old operation cannot. A manual entry ID is bound to one statement, so a new explicit manual entry after purge requires a fresh source ID. Shared-source suppression only becomes stronger (`forgotten` over `rejected` over `removed`).

## Acceptance boundary

This contract is ready for focused Core tests covering draft limits and invariants, scope and subject visibility, temporal and connection filters, local-only Memories, excluded states, stable citations, idempotent operation IDs, replacement projection, suppression, purge redaction, and late-write rejection. Human-reviewed Q04–Q06 datasets, actual model evaluation, native host behavior, and real provider evidence remain separate deferred acceptance work; synthetic agent fixtures cannot satisfy the human labeling gate.
