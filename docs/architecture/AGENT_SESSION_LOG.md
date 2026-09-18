# Canonical session log and derived conversation history

The current session format follows the DSH v3 shared event contract at `deepseek-harness` revision `0d1f50007f`. `SessionLogCodec` is the actual journal codec, not an export format. MiraCore owns semantic values and reconstruction; MiraData owns file framing, writer exclusion, durability and disposable caches.

## Shared records

The first line is `{type:"session",version:3,id,createdAt,isSeeded,delegationDepth}`. `createdAt` is Unix milliseconds. `cwd` is omitted when the session has no real directory. The header has no event sequence. Semantic events use `type`, contiguous zero-based `seq`, integer Unix-millisecond `time`, and `data`. Message events also carry `surfaceOp`. Unknown required events fail decoding; unknown explicitly ignorable events can be skipped.

DSH names and nesting are retained for `turn/start`, `step/start`, `system/message`, `user/message`, `request/header`, `request/context`, `assistant/message`, `assistant/attempt`, `tool/call`, `tool/result`, `step/end` and `turn/end`. Messages contain scalar `id`, `role`, ordered content blocks and a typed `source`. Tool arguments remain their original JSON string. Tool results use the user role with a `tool-result` block and `source.callId`.

Admission opens the turn and its first step, then writes the frozen system instructions before the original user message and the required Mira admission fact in one physical transaction. The writer and reader validate the same turn/step relations. A step cannot close while a tool call lacks its canonical result; every result cites the exact earlier call event sequence. Provider call IDs may repeat across turns, so call payload references use event sequences rather than a session-wide call-ID dictionary. A changed instruction value creates a new system message; identical instructions reuse the existing message. Request headers own `{name,description,parameters}` tool definitions. Retrieved context is explicit plugin input, collected once per turn. Request context describes the provider/model context limit; it is not a retrieval-body container.

Assistant records carry the actual normalized adapter stream, grouped into DSH `text-chunks`, `reasoning-chunks`, `tool-call-chunks` and raw `chunk` records. Grouping preserves delta boundaries and receipt times, including negative wall-clock gaps. No stream is synthesized from a completed answer. DSH usage input tokens exclude separately reported cache tokens; Mira retains the provider's original usage accounting alongside attempt settlement.

## Content ownership and requests

`SessionContent` is immutable inline data with an identity and kind. It has no external file path, batch-owned blob, retention group, stored digest or erasure state. Ordinary text and structured values are readable in the journal. There is no model draft content, patch format or checkpoint writer. Credentials remain outside this content in Keychain; routes persist only credential references and versions.

Frozen routes retain the resolved model identity, limits, capabilities and adapter configuration. Model metadata provenance belongs to the configuration store; no `route.metadataEvidence` array is serialized into the journal.

Content already owned by a shared message is referenced by message/block position or text projection. Frozen plans refer to the system message and route definition. Identical plan/content values reuse the first definition. A model output refers to its assistant message plus block identities, original usage and finish metadata. Completion refers to existing output text where it is identical. Multi-step visible thinking uses an ordered list of reasoning block references selected from that execution's attempts, including when tool events separate the assistant messages. Deterministic local completions remain Mira completion facts with inline content; they never invent a model source or a stream.

Every tool outcome, including denial, invalid input, cancellation, timeout and interruption without a returned payload, has a canonical `tool/result` before its step ends. Its message owns the exact model-facing observation envelope (`authority`, `status`, `content`, and an optional structured `error`). Requests reference this message directly. Business result references extract the original canonical JSON `content` bytes, preserving receipt binding without another durable copy. Tool observations cannot fall back to plugin user messages.

`mira/request-start` records the turn, step, attempt, execution identity and inclusive `throughSeq` input watermark. Its inline `AgentSessionRequest` evidence contains:

- Request identity, provenance, omissions and estimated token metadata.
- References to the frozen route, system message and tool header.
- References to the original admitted user message and this turn's context contributions. A contribution is stored once as plugin input; subsequent steps reuse it.

The journal does not contain full request snapshots, selected historical message arrays, provider wire templates, JSON-path bindings or references into earlier wire requests. `AgentContextBuild` is a non-Codable process-local value. The loop derives conversation history and tool continuation from committed user, assistant and tool records, applies replay rules and budgets, then prepares the selected adapter's request in memory. A bounded transport retry reuses that same frozen prepared value and committed evidence. The inspector displays request metadata and added context; it does not claim to reconstruct the exact historical HTTP body. References cannot target a future event.

During streaming, accumulated blocks, continuation, usage and stream records remain process-local. Completion and ordinary failure commit the attempt's output and stream once. Orderly cancellation or application shutdown drains the producer and hands the last consumed prefix to terminal settlement, subject to source authorization. A hard crash loses that unresolved prefix by design. Restart settles existing attempts and business receipts without model/tool redispatch; earlier committed steps remain available. Incomplete continuation may be retained for inspection after orderly settlement, but cannot bypass adapter replay rules. A retry selects a new execution for the original user identity; the journal retains prior attempts while the disposable conversation projection replaces their assistant presentation.

## Mira execution facts

Required `mira/*` records carry only current execution/recovery requirements: session lifecycle, model selection, frozen route, admission, request evidence, attempt settlement, tool intent/approval/dispatch/receipt, completion, retry selection and registered domain extensions. Their payloads are decoded explicitly.

Internal command reduction still has a one-based `internalSequence`, independent from the expanded zero-based DSH event sequence. `SessionCursor.sequence` and SQLite/checkpoint cursors use that command sequence. `throughSeq`, message surface operations and shared event references use DSH `seq`. They must not be interchanged. Runtime event identity and exact command time are carried in Mira facts so uncertain immutable commands can be reconciled exactly; they are not added to shared DSH event fields.

Business effect receipts still bind to the exact canonical proposal/result bytes. Content SHA-256 is computed for this binding, not stored as an external-body lifetime mechanism. Business/domain authorization and library maintenance remain separate from session content retention. There is no session erasure plan, transitive content invalidation, retry deletion pass or obsolete-format decoder.

## Physical transactions and caches

Each committed physical frame consists of one or more top-level header/semantic JSON lines followed by a separate `mira/commit` line. The marker contains `version:1`, `batchId`, `expectedSequence`, `sequence`, `firstSeq`, `nextSeq`, `recordCount` and `checksum`. SHA-256 covers the exact preceding frame bytes, including each line feed. The marker has no semantic `seq`, no content and no embedded batch. This framing is a Mira durability requirement, not a DSH event.

The writer appends the whole frame, synchronizes the file and directory, then acknowledges it. An uncertain append fences further writes and can only reconcile the original immutable command. Recovery truncates an uncommitted tail. A complete valid commit missing only its final line feed is preserved and completed. A committed checksum or semantic failure is rejected. Strict archive inspection never repairs its source.

The writer lock, serialized admission and journal reducer enforce one active execution and unique terminal settlement. Queries and SQLite projections never admit work. Indexes/checkpoints are disposable authenticated derivations tied to the exact source bytes. Indexed reads verify the selected physical frame and decode it using checked canonical definitions plus the validated execution trace at that frame's start. They do not validate an old frame against the final turn/step state. Archives contain session journals, business data and domain attachments; they contain no session body directory. Development data is recreated at the configured path when changing this format, without compatibility or backup copies.

Verification evidence and remaining gaps belong in `docs/engineering/AGENT_SESSION_REFACTOR_VERIFICATION.md`.
