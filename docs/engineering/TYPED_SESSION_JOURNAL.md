# Typed session event journal

Date: 2026-09-16. Replaces the v4 token-patch layout directly; no historical decoder or migration.

The v5 implementation uses semantic session and step boundaries. The canonical log records settled output; one replaceable sidecar preserves unfinished output for recovery.

## Problem and reference

The previous change moved payload files into `{checksum, record:{batch, payloads}}`, but retained a transaction-shaped line, UUID-to-string indirection and escaped JSON inside JSON. A prepared model request also stored both semantic input and the provider wire encoding of the same content.

A read-only inspection of local Codex session files found a clearer envelope: `timestamp`, `type`, and `payload`, with message/tool items stored inline. This is a local observation, not a claimed public Codex format contract. Codex also records overlapping response items and execution notifications; its logs are not a zero-duplication design. No private Codex contents were exported or committed.

The inspected Mira example was 80,512 bytes, with 33 events packed into 18 lines. Its two request payloads contained 32,304 UTF-8 bytes, including 11,858 bytes of wire JSON and 11,908 bytes of semantic input. These are shape/size measurements only; the personal conversation was not retained as a fixture.

## Current format

Every domain event occupies one line, with keys written in this order for human inspection:

```json
{"timestamp":"2026-09-16T10:00:00.000Z","type":"session","id":"...","sequence":1,"payload":{"title":{"id":"...","retention_group":"...","kind":"title","byte_count":9,"sha256":"...","text":"Synthetic"}}}
```

The example is abbreviated, not an importable transaction. The actual codec emits complete UUIDs and checksums.

| Event | Payload purpose |
|---|---|
| `session`, `model_selection`, `session_title` | Conversation metadata and model selection |
| `turn/start` | User message, frozen execution plan and queued execution admission |
| `request/start` | Request manifest, header and direct message-component references |
| `assistant/message`, `assistant/attempt` | Settled ordered model blocks, or an attempt without surface output |
| `tool/call`, `tool_prepared`, `tool_dispatched`, `tool/result` | Tool call and effect lifecycle |
| `turn/end` | Terminal outcome and accounting |
| `content_invalidated`, `retry_retired` | Explicit erasure authorization or logical retry retirement |

Bodies appear at the relevant semantic field, such as `payload.userBody.text`, `payload.request.json`, or `payload.answer.text`. Native JSON is used only when canonical decoding/re-encoding preserves the exact original bytes. User text, visible output, and titles remain strings, even when their contents happen to parse as JSON. Noncanonical or numerically lossy JSON remains verbatim text. Large and non-UTF-8 bodies still use managed external files.

Content nodes omit the redundant session/current-transaction IDs. References to earlier transactions carry `source_batch`; a repeated reference in the same transaction does not repeat its body. Retention groups remain independent: identical bytes in distinct privacy lifetimes are not merged.

Ordered model blocks use explicit `type` values (`text`, `thinking`, `tool_call`, `tool_result`) and named fields instead of Swift's synthesized `_0` representation. Provider continuation remains verbatim in its own field.

## Atomicity, recovery and erasure

An internal `SessionBatch` is one atomic transaction containing event lines followed by a `transaction_commit` line. Its fields are `format_version: 5`, transaction `id`, `session_id`, `expected_sequence`, `event_count`, and a SHA-256 `checksum` of the exact preceding event lines including their LF delimiters. A batch's internal API remains an atomic admission unit; it is no longer the serialized per-line layout.

Only a valid commit publishes the events. Recovery removes an unfinished final transaction, including complete event lines that lack a commit. A complete corrupt/unknown line or invalid commit fails closed. A valid final commit missing only LF is preserved and receives its delimiter. Read-only archive validation rejects all incomplete tails without changing the source. Reads are bounded to one transaction (8 MiB plus 256 bytes); the existing 2 MiB metadata, 256-event, 256 KiB inline-body and 2 MiB inline-budget limits remain.

Normal writes and retries preserve prior bytes. Explicit, durably authorized privacy erasure is the physical rewrite exception: remove the selected inline content, retain event/transaction identities, recompute commit checksums, and rebuild source-bound indexes/checkpoints. Retired history remains physically present until explicit erasure. Archive proof reads can inspect retained historical tool content while ordinary reads deny retired content.

Index/checkpoint formats advance to v5. Index offsets span complete transactions, including internal newlines. Event construction normalizes timestamps to milliseconds so ISO8601 persistence and reconciliation agree exactly. Active drafts use a replaceable sidecar with request, execution, attempt, authorization epoch, revision, ordered blocks, continuation and usage; they are retired after settled output is durable.

## Semantic request persistence

`AgentContextBuild` is ephemeral. Each persisted request is a bounded manifest with frozen route/adapter metadata, context-selection evidence, a header reference and ordered message references. Original user messages, settled model output and tool results are reused from their originating events. The manifest preserves block identities and the tool-observation wrapper, so materialization reproduces the exact `AgentModelInput`. Headers and synthetic context components can be reused within an execution; reference ownership preserves independent privacy lifetimes.

Foreground dispatch and automatic retry retain the frozen in-memory prepared request. Production adapters reconstruct and compare prepared input before sending. Disk recovery does not restart model calls. Audit, history, source authorization, tool resolution, privacy maintenance, background memory prefix retrieval and the native request inspector resolve the manifest through the payload port. Frozen-route budget checks remain in place.

Execution replay uses references to settled model messages and tool results. Local responses and tool denials without a prior result body are stored as small local replay items. Visible final answer/thinking summaries retain a separate privacy lifetime from hidden model output and continuation for `.retainVisibleHistory`. This remaining summary duplication is intentional. Background memory job storage is a separate contract.

The earlier **42,379 → 21,577 byte** measurement concerned v4 removal of the copied provider wire request. It is historical evidence, not a measurement of v5 or whole-library compression.

## Verification

Focused checks passed for semantic ordering, request materialization, active drafts,
privacy, archive restoration, parallel tool settlement and all 16 process-termination
scenarios. Native composition/recovery passed 20 tests; localization passed 5 tests
and the language policy check. The app build and offline native multi-step/reopen
check passed. Exact commands, logs and limitations are recorded in
[semantic journal verification](SEMANTIC_SESSION_JOURNAL_VERIFICATION.md).

Two forged-context fixtures were adapted to corrupt persisted semantic records after valid construction, retaining executor/resolver rejection tests. One source-dispatch expectation was stale since `08e2083`: task source authorization reads immutable historical revisions. The test now verifies completion and retained historical task/tool replay after an update, matching `AGENT_SOURCE_AUTHORIZATION.md`; production task authorization was not changed in this increment.

No full package suite, paid model endpoint, unrelated UI matrix, macOS 15 runtime, large-library benchmark or physical power-loss test was run.

## Development library

The app was stopped before clearing obsolete conversation/domain data and recreating `Sessions`, `Knowledge`, and `Projections` at `/Users/alwyn/Library/Application Support/Mira`. Associated memory/extraction/vector, tool receipt, consumer checkpoint and task/knowledge development records were cleared in a foreign-key-checked transaction. The database was vacuumed and its WAL truncated. No backup or compatibility library was created.

Provider/model settings were retained and their complete row digest matched before and after cleanup (1 connection, 2 model descriptors, 2 presets, 1 binding). Library identity, Keychain credentials and the shared local embedding model are separate resources and were retained. The final app reopened against this same development path after build verification. The reset also restored the privacy store schema marker and rebuilt empty full-text indexes; see the linked verification note.

Reopening exposed a root-directory validation bug: inspecting the library in Finder could leave `.DS_Store`, which was treated as an unsupported library file. Runtime composition now tolerates an ordinary single-link `.DS_Store` without reading or archiving it; linked files and other unknown entries remain rejected. The final native check reached the empty conversation screen with the existing DeepSeek model selected and no library error. No provider request was sent.
