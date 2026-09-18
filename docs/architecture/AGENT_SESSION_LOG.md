# Canonical session log and derived conversation history

The session format follows the DSH v3 shared event contract. `SessionLogCodec`
is Mira's journal codec, not an export format. MiraCore owns semantic values and
reconstruction; MiraData owns file framing, writer exclusion, durability, and
disposable caches. This document is the authoritative session contract. Other
documents may describe callers or historical implementation work, but cannot
reintroduce a second session body store or a second request history.

## Shared records

The first line is `{type:"session",version:3,id,createdAt,isSeeded,delegationDepth}`.
Semantic events carry `type`, contiguous zero-based `seq`, integer Unix-
millisecond `time`, and `data`. Message events also carry `surfaceOp`. Unknown
required events fail decoding; explicitly ignorable events may be skipped.

DSH names and nesting are retained for `turn/start`, `step/start`,
`system/message`, `user/message`, `request/header`, `request/context`,
`assistant/message`, `assistant/attempt`, `tool/call`, `tool/result`,
`step/end`, and `turn/end`. Messages contain a scalar `id`, `role`, ordered
content blocks, and a typed `source`. Tool arguments retain their original JSON
string. Tool results use the user role with a `tool-result` block and
`source.callId`.

Admission opens the turn and first step, then writes the frozen system
instructions before the original user message and the required Mira admission
fact in one physical transaction. A step cannot close while a tool call lacks
its canonical result. Provider call IDs may repeat across turns, so call
references use event sequences rather than a session-wide call-ID dictionary.
Request headers own `{name,description,parameters}` tool definitions. Retrieved
context is explicit plugin input, collected once per turn. Request context
describes the provider/model limit; it is not a retrieval-body container.

## Inline content and request evidence

`SessionContent` is immutable inline data with an identity and kind. It has no
external path, batch-owned blob, retention group, stored digest, or erasure
state. Ordinary text and structured values are readable in the journal. There
is no model draft content, patch format, or checkpoint writer. Credentials stay
in Keychain, while routes persist only credential references and versions.

Frozen routes retain resolved model identity, limits, capabilities, and adapter
configuration. Model metadata provenance belongs to the configuration store;
it is not duplicated in the journal.

`mira/request-start` records the turn, step, attempt, execution identity, and
inclusive `throughSeq` input watermark. Its inline `AgentSessionRequest` evidence
contains request identity, provenance, omissions and estimates, plus references
to the frozen route, system message, tool header, admitted user message, and
this turn's context contributions. A contribution is stored once as plugin
input and reused by later steps.

The journal does not contain full request snapshots, selected historical message
arrays, provider wire templates, JSON-path bindings, complete stored HTTP
requests, or duplicate full-history logs. `AgentContextBuild` is process-local.
The loop derives history and tool continuation from committed user, assistant,
and tool records, applies replay rules and budgets, and prepares the selected
adapter request in memory. The inspector may display request metadata and added
context; it must not claim to reconstruct an exact historical HTTP body when it
is unavailable.

## Streams, settlement, and recovery

Assistant records carry the normalized adapter stream, grouped into text,
reasoning, tool-call, and raw chunk records. Grouping preserves delta boundaries
and receipt times; no stream is synthesized from a completed answer. DSH usage
accounting, including separately reported cache tokens, remains available at
attempt settlement.

Accumulated blocks, continuation, usage, and stream records remain process-local
until attempt settlement. Completion and ordinary failure commit the attempt's
output and stream once. Orderly cancellation or shutdown drains the producer and
settles the last consumed prefix, subject to source authorization. A hard crash
loses unresolved output by design. Restart settles existing attempts and
business receipts without model/tool redispatch; earlier committed steps remain
available. An orderly incomplete continuation may be retained for inspection,
but cannot bypass adapter replay rules.

A retry selects a new execution for the original user identity. The journal
retains prior attempts while the disposable conversation projection replaces
their assistant presentation.

## Mira facts and physical frames

Required `mira/*` records carry current execution and recovery requirements:
session lifecycle, model selection, frozen route, admission, request evidence,
attempt settlement, tool intent/approval/dispatch/receipt, completion, retry
selection, and registered domain extensions. Internal command sequence numbers
remain distinct from DSH event `seq`; they must not be interchanged.

Business effect receipts bind to canonical proposal/result bytes. Business/domain
authorization and library maintenance remain separate from session content
retention. There is no session erasure plan, transitive content invalidation,
retry deletion pass, or obsolete-format decoder.

Each committed physical frame contains one or more top-level semantic JSON
lines followed by a `mira/commit` line. The marker records the frame range and
checksum but has no semantic `seq`, content, or embedded batch. The writer
appends, synchronizes, and acknowledges the whole frame. An uncertain append
fences further writes and can reconcile only the original immutable command;
recovery truncates an uncommitted tail. Indexes and checkpoints are disposable
authenticated derivations tied to exact source bytes, never active model
checkpoints.

Archives contain session journals, business data, and declared domain
attachments. They contain no session body directory, active-draft sidecar,
request manifest, or full HTTP history. Development data is recreated at the
configured path when changing this format; no compatibility decoder or backup
copy is retained.
