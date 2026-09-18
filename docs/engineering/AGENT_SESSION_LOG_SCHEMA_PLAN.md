# Session log field alignment with DSH

Date: 2026-09-17. Status: approved and implemented; the current contract is [Agent session log](../architecture/AGENT_SESSION_LOG.md), with acceptance tracked in [verification](AGENT_SESSION_REFACTOR_VERIFICATION.md).
Companion plan: [Agent session flow refactor](AGENT_SESSION_FLOW_REFACTOR_PLAN.md).

## Decision and authority

Use DSH's existing field names, JSON types, nesting, optional-field rules, and semantics for shared session concepts. Port the values into Swift with explicit encoding. A readable export over the old runtime schema does not satisfy this decision.

Reference: `/Users/alwyn/repos/deepseek-harness`, commit `0d1f50007f`:

- `packages/core/session/src/types.ts`: file metadata, event envelope, boundaries, message events, request header/context, and surface placement.
- `packages/session/session-persistence-jsonl/src/format.ts`: actual first JSONL line, including required `delegationDepth`.
- `packages/llm/llm/src/message.ts`: stable message identity, roles, sources, and replay state.
- `packages/llm/llm/src/types.ts`: content blocks, token accounting, tool schemas, and stream chunks.
- `packages/llm/llm/src/assistant-stream.ts`: lossless compact stream records and timing.
- `packages/core/session/src/request-header.ts`: canonical optional fields and header equality.

The supplied DSH log confirms these shapes. Its content is not copied into fixtures or repository documentation. The examples below are synthetic.

Shared fields must match DSH in meaning, not only spelling. Mira-specific required facts use separately identified `mira/...` events. This is schema alignment, not a promise that an unmodified DSH reader can execute or fully reconstruct a Mira session. Do not implement old Mira decoders or a DSH import/migration feature. Mira's format version remains independently owned; do not select `3` merely because the inspected DSH release uses version 3.

Session text is inline. No external session-body references, retention groups, privacy epochs, or erasure graph are part of this schema. Credentials remain outside the content-bearing log.

## File header and event envelope

The first physical line is a file header, outside the event sequence:

```json
{"type":"session","version":3,"id":"session-demo","createdAt":1800144000000,"cwd":"/tmp/mira-demo","isSeeded":false,"delegationDepth":0}
```

This header demonstrates DSH's current generation. The new Mira writer must choose its own format generation at cutover and use the same header field layout.

| Field | JSON type and meaning | Mira decision |
|---|---|---|
| `type` | Literal `session` | Same; no `data`, `seq`, or `time` wrapper on this line |
| `version` | Integer logical format generation | Independently version Mira; reject unsupported generations |
| `id` | String session identity | Existing conversation identity encodes directly as a string |
| `createdAt` | Integer Unix epoch milliseconds | Never Swift's reference-date seconds or an ISO string under this key |
| `cwd` | Optional absolute working-directory string | Emit only for an actual associated directory; a Mira workspace ID is not a directory |
| `isSeeded` | Boolean inherited-prefix indicator | `false` for current Mira sessions; does not add fork support |
| `delegationDepth` | Nonnegative integer, physically required in DSH | `0` for current top-level sessions; does not add delegation support |
| `parentSession`, `origin`, `agentPreset` | Optional provenance/composition metadata | Use the same meaning if supported; omit fields without a real value |

Mira-specific workspace identity and mutable title/model-selection state remain explicit metadata facts, rather than being disguised as `cwd` or silently changing this immutable header. Product configuration UI remains deferred.

Every logical event uses this envelope:

```json
{"type":"turn/start","seq":0,"time":1800144000010,"data":{"turn":1}}
```

| Field | Required contract |
|---|---|
| `type` | Slash-separated event name, exactly as in DSH for shared events |
| `seq` | Contiguous zero-based safe integer within one session; independent of physical line number |
| `time` | Integer Unix epoch milliseconds; wall-clock time need not increase, event order comes from `seq` |
| `data` | The typed payload for this particular event; never another encoded JSON string |
| `surfaceOp` | Required for shared message-producing events: `"append"` or `{ "op":"replace", "startSeq":n, "endSeq":m }`; absent on control events |
| `sourceEventSeqs` | Optional nonempty list of earlier contributing event positions on system/user/tool-result events; never a substitute for message identity; absent on assistant events |
| `ignorable` | Optional literal `true` only when an unknown reader can safely skip the event; absent means unknown types must block reconstruction |

Do not add a second UUID to every event; `(session.id, seq)` identifies the event. Message IDs and provider tool-call IDs retain their independent purposes. Persisted integers stay within JSON's safe integer range. An internal count/offset is not interchangeable with an inclusive `seq` watermark; update journal cursors explicitly when moving from Mira's current one-based events.

Optional fields are omitted, not encoded as `null`, empty objects, or placeholder strings. Empty arrays remain meaningful where DSH requires them, including an empty message `content` or an attempt `stream`; the omission rule is field-specific. Unknown required message content or reconstruction events fail explicitly.

## Shared event fields

| Event | Exact shared `data` shape | Interpretation |
|---|---|---|
| `turn/start` | `{ turn }` | `turn` is a session-local integer starting at 1; no `user`, `executionId`, or frozen plan inserted here |
| `step/start` | `{ turn, step }` | `step` starts at 1 within a turn; it is not a UUID or attempt count |
| `system/message` | `{ turn, step, message }` | Complete identified system message; first active system message precedes the first user message on the model surface |
| `user/message` | The message itself: `{ id, role, content, source }` | Preserve DSH's direct payload; do not add a `message` wrapper for symmetry |
| `request/header` | `{ header: { config, adapterDefaults?, tools? }, reason, startsSeries? }` | Stable generation options and tool schemas; system text belongs in `system/message` |
| `request/context` | `{ provider, model, contextWindow?, systemPromptUpdate? }` | Route capability metadata; no retrieval text and no duplicate header |
| `assistant/message` | `{ turn, step, message, stream, usage?, interrupted? }` | Settled assembled output plus its compact stream; `interrupted`, when present, is `true` |
| `assistant/attempt` | `{ turn, step, stream }` | An attempt that committed no surface message; diagnostics never fabricate model-visible history |
| `tool/call` | `{ turn, step, callId, name, arguments }` | Tool intent with the exact raw argument string; this control event does not itself append another model message |
| `tool/result` | `{ turn, step, message, error?, meta? }` | Complete tool-result message, optional display failure and tool-owned JSON metadata |
| `step/end` | `{ turn, step }` | End of the model-plus-tools step; no new `status` vocabulary |
| `turn/end` | `{ turn, reason }` | `reason.kind` defines the outcome; no repeated answer, replay transcript, message list, or aggregated usage |

`turn/end.reason` follows DSH: `completed`, `blocked`, `max-tokens`, `interrupted`, `aborted` with a cancellation `reason`, or `error` with structured `error` facts. User cancellation, for example, is `{ "kind":"aborted", "reason":{ "kind":"user" } }`. Process-loss settlement is `{ "kind":"interrupted" }`. Do not emit DSH's historical `legacy` cancellation case in new Mira logs.

Request attempt IDs do not belong in DSH's assistant fields. Mira records its durable request boundary in `mira/request-start`, then associates the following assistant message/attempt by its active turn, step, and request boundary. Enforce one terminal settlement per attempt; do not rely on loosely matching timestamps.

## Messages, sources, and content

Every shared message has the same four required fields:

```json
{"id":"message-user-1","role":"user","content":[{"type":"text","text":"Hello."}],"source":{"kind":"user"}}
```

| Field | Alignment |
|---|---|
| `id` | Stable string identity across storage, projections, UI, and request assembly |
| `role` | `system`, `user`, or `assistant`; DSH represents tool results as user-role messages |
| `content` | Ordered block array; preserve interleaved text, reasoning, and tool calls |
| `source` | Required structured provenance; never infer the producer from role alone |

Use DSH's source vocabulary:

- Human input: `{ kind: "user" }`.
- Built-in prompt or context contribution: `{ kind: "plugin", plugin: "mira-system-prompt" }` or the real contributing module name. `plugin` identifies the producer; it does not require adding a plugin framework.
- Context may use the existing `form` values when their semantics apply, such as `instructions`, `catalog`, `snapshot`, or `notice`; include the fields required by that form. Do not copy descriptive text into metadata merely to fill a field.
- Model output: `{ kind: "model", provider, model, replayState? }`.
- Tool result: `{ kind: "tool", callId }`.

Required provider continuation belongs in `message.source.replayState`, as adapter-owned lossless JSON. Visible thinking belongs in `content` as `reasoning`. Preserve block alignment and opaque signed/encrypted provider data without reinterpreting it as display text. A terminal stream's replay payload and the assembled message must stay consistent.

| Content kind | Fields |
|---|---|
| Plain text | `{ type: "text", text }` |
| Thinking | `{ type: "reasoning", text }`; do not write `thinking`, `visibleThinking`, or an answer-level parallel string |
| Tool call inside assistant content | `{ type: "tool-call", id, name, arguments }` |
| Tool result | `{ type: "tool-result", toolCallId, content, isError? }` |

The three tool-correlation spellings are intentional DSH fields: assistant block `id`, `tool/call.data.callId`, and result block `toolCallId`. They must hold the same provider-issued value. `arguments` remains the exact JSON string from the model, including formatting; parsing for execution does not rewrite the stored value.

A result message is `{ id, role: "user", source: { kind: "tool", callId }, content: [toolResultBlock] }`. A `tool/result.data.error` requires an error result block and uses `{ name, code, reason? }`; do not place internal display failures into model-visible content implicitly. `meta` is optional JSON for the actual tool presentation.

DSH also defines `image` and `file` blocks with `attachment` references. Text inlining does not mean base64-encoding every attachment into JSONL. Adapt an existing supported Mira attachment path if needed; this refactor does not add new media capabilities or resurrect external text-body storage.

## Request fields and accounting

`request/header.data.header.config` uses `provider`, `model`, and optional `reasoningEffort`, `temperature`, `maxTokens`, `stop`. `adapterDefaults` contains optional literal-true `reasoningEffort` / `maxTokens` indicators. Tool definitions use `{ name, description, parameters }`, with `parameters` an inline JSON Schema object.

`request/context.data.contextWindow` describes total context capacity; `config.maxTokens` describes the generation ceiling. They are not aliases. Provider endpoint, credential reference/version, adapter revision, and Mira-specific execution limits are recorded in a separate, reused `mira/route-snapshot`; do not expand DSH's shared header into Mira's entire runtime route object. Header and route-snapshot equality are independent: changing only the credential revision updates the route snapshot without inventing a change in generation options.

Use DSH's header `reason` vocabulary: `initial`, `resume`, `change`, `series`. The current Mira scope emits `initial` and `change`, with `resume` for the first new request in a reopened loop. A reopened session does not make a request automatically. Do not add series/fork behavior merely because `series` and `startsSeries` exist. Header equality uses the same canonical shape everywhere; omit empty optional `tools` and empty `adapterDefaults`. Lifecycle snapshots must be counted separately from actual configuration changes.

`usage`, when available, is stored on the owning assistant message and uses:

| Field | Meaning |
|---|---|
| `inputTokens` | Uncached input tokens only |
| `outputTokens` | Output tokens |
| `cacheReadTokens`, `cacheWriteTokens` | Optional, disjoint cached-input counters |
| `totalTokens` | Optional reliable full-call total |
| `reasoningTokens` | Optional provider-reported reasoning tokens |

Adapters must normalize counters to these meanings. Renaming an aggregate input count to `inputTokens` without subtracting disjoint cache counts is incorrect. Do not synthesize zero usage when the provider reported none. Turn totals are derived; failure-attempt usage remains available in the attempt stream. Any existing Mira metric with a different meaning needs an explicit mapping, not a guessed renamed field.

## Stream fields

Preserve DSH's compact stream records inside `data.stream`:

| `type` | Fields |
|---|---|
| `text-chunks` | `time0`, `index`, `dt`, `texts` |
| `reasoning-chunks` | `time0`, `index`, `dt`, `texts` |
| `tool-call-chunks` | `time0`, `index`, `dt`, `id`, optional `name`, `args` |
| `chunk` | `time`, `chunk` |

`time0` and `time` are Unix milliseconds. `index` is the provider-neutral block index. `dt` contains one delta between each neighboring pair of members, so its length equals `texts.count - 1` or `args.count - 1`. Preserve each delta boundary and ordering; do not join text fragments merely to reduce record count. Follow DSH's validated timestamp arithmetic rather than assuming every wall-clock delta is positive.

Raw `chunk` values follow the shared vocabulary: `block-start`, `text-delta`, `reasoning-delta`, `tool-call-delta`, `block-end`, `usage`, and `finish`. `finish.reason.kind` uses `stop`, `tool-calls`, `max-tokens`, `aborted`, or `error`; it differs intentionally from a turn-end reason. A raw stream chunk here is the normalized adapter stream, not an HTTP request/response dump.

## Mira extensions and physical commits

Only add an extension for a concrete current requirement. Each extension uses the same `type/seq/time/data` envelope. Required execution/reconstruction facts omit `ignorable`. Keep extension payloads typed; do not use a catch-all serialized runtime object.

| Extension | Required purpose and initial field direction |
|---|---|
| `mira/turn-admitted` | Correlate `turn`, scalar `executionId`, `userMessageId`, the accepted selection revision and required frozen execution references once; original user message plus this fact commit atomically |
| `mira/route-snapshot` | Record effective endpoint/adapter identity, credential reference/version and unsupported-by-DSH invocation settings once per actual change; no credentials or full history |
| `mira/request-start` | Record `turn`, `step`, `attempt` and the committed input watermark `throughSeq`; refer to the frozen route and record exceptional selections only when needed |
| `mira/draft-checkpoint` | Recoverable in-progress content/stream delta associated with the active request event; inline data, no content-store handle |
| `mira/tool-*` | Current approval, required effect intent, dispatch and receipt facts, correlated by `callId`; do not duplicate completed tool content |
| `mira/turn-retry` | Original user identity and superseded execution/answer placement; do not delete or repeat the original user text |
| `mira/local-response` | Existing deterministic non-model reply; do not invent a provider or model stream to satisfy `assistant/message` |

DSH's `sourceEventSeqs` only refers backward. Put `mira/turn-admitted` after its user message within the same atomic batch to avoid inventing a forward-reference exception in shared fields. The reducer validates the complete candidate batch before publishing either input or queued execution.

`throughSeq` is inclusive; the empty prefix is `-1`. It refers only to an already committed input prefix after request-boundary persistence and before dispatch. In a batch, the prefix may become committed together with the request-start fact. Historical request derivation folds through that position; it does not include later assistant output. Attempt numbers are scoped to one step, and the request-start event position is its durable identity.

New projection-changing extensions, including retry and local responses, need explicit reader support; they cannot be marked ignorable. DSH's shared surface operations keep their exact semantics. Do not silently reinterpret an append as a replacement, or present DSH's model-only replacements as human conversation. Add only the retry replacement capability currently needed by Mira; compaction and forks remain deferred.

Physical transaction framing remains separately owned by MiraData. It must preserve top-level logical event objects, retain atomic admission and side-effect durability barriers, and distinguish commit metadata from DSH semantic events. Freeze the exact commit marker/checksum fields in P0; do not hide another full `SessionBatch`/runtime object inside every event. Physical metadata does not consume logical `seq` values. This is an explicit Mira storage difference, not an assertion that DSH uses commit markers.

## Synthetic shared-field trace

This trace exercises DSH's shared shapes for one model-only turn. It deliberately omits Mira's admission/request/commit extensions; the integrated P0 trace must include those. The header's version 3 identifies the DSH reference example, not the selected Mira format version.

```jsonl
{"type":"session","version":3,"id":"session-demo","createdAt":1800144000000,"cwd":"/tmp/mira-demo","isSeeded":false,"delegationDepth":0}
{"type":"turn/start","seq":0,"time":1800144000010,"data":{"turn":1}}
{"type":"step/start","seq":1,"time":1800144000020,"data":{"turn":1,"step":1}}
{"type":"system/message","seq":2,"time":1800144000030,"data":{"turn":1,"step":1,"message":{"id":"system-1","role":"system","content":[{"type":"text","text":"You are Mira."}],"source":{"kind":"plugin","plugin":"mira-system-prompt"}}},"surfaceOp":"append"}
{"type":"user/message","seq":3,"time":1800144000040,"data":{"id":"user-1","role":"user","content":[{"type":"text","text":"Hello."}],"source":{"kind":"user"}},"surfaceOp":"append"}
{"type":"request/header","seq":4,"time":1800144000050,"data":{"header":{"config":{"provider":"fixture","model":"fixture-model","maxTokens":1024}},"reason":"initial"}}
{"type":"request/context","seq":5,"time":1800144000060,"data":{"provider":"fixture","model":"fixture-model","contextWindow":8192}}
{"type":"assistant/message","seq":6,"time":1800144000110,"data":{"turn":1,"step":1,"message":{"id":"assistant-1","role":"assistant","content":[{"type":"text","text":"Hello!"}],"source":{"kind":"model","provider":"fixture","model":"fixture-model"}},"stream":[{"type":"chunk","time":1800144000070,"chunk":{"type":"block-start","index":0,"blockType":"text"}},{"type":"text-chunks","time0":1800144000080,"index":0,"dt":[],"texts":["Hello!"]},{"type":"chunk","time":1800144000090,"chunk":{"type":"block-end","index":0,"block":{"type":"text","text":"Hello!"}}},{"type":"chunk","time":1800144000100,"chunk":{"type":"finish","reason":{"kind":"stop"}}}]},"surfaceOp":"append"}
{"type":"step/end","seq":7,"time":1800144000120,"data":{"turn":1,"step":1}}
{"type":"turn/end","seq":8,"time":1800144000130,"data":{"turn":1,"reason":{"kind":"completed"}}}
```

Control-event ordering and model-message ordering are distinct. `turn/start` and `step/start` may precede system installation. The first model-visible message is still the system message, followed by user/injected messages. Tools remain structured in `request/header`, rather than concatenated into system text to make file order look uniform.

## Mapping from the current Mira implementation

| Current concept | Target |
|---|---|
| `SessionEvent.sequence`, `occurredAt`, `fact` | `seq`, `time`, discriminated `type` plus typed `data`; update indexing and epoch conversion |
| `SessionHeader.workspaceID`, external `title` | Actual `cwd` only when available; Mira workspace/title metadata separately; title text inline |
| `SessionAdmission.executionID/userMessageID/userBody/plan` | One `mira/turn-admitted` association, standalone identified `user/message`, folded header/route facts; no serialized complete plan |
| `stepID`, `stepIndex`, `attemptIndex`, repeated attempt UUIDs | Numeric `turn`/`step`; attempt identity carried by `mira/request-start` |
| `SessionAttempt.request` payload reference | Committed input prefix and explicit exceptional selections |
| `SessionAttemptResolution.output` | Inline `assistant/message` or `assistant/attempt` |
| `SessionCompletion.answer/visibleThinking/replay/usage` | Ordered message content, source replay state and owning message usage; minimal `turn/end.reason` |
| `toolName`, invocation payload, resolution payload | `tool/call` and `tool/result` shared fields plus minimal effect/receipt extensions |
| Privacy invalidation, retained body descriptors, retry erasure | Removed; retry records supersession/placement without content erasure |

## Field-level acceptance

- Encode/decode synthetic shared events with exactly the approved keys, scalar types, required fields and omission rules. Compare structural fixtures, not JSON object-key ordering.
- Validate the shared fixtures against the inspected DSH definitions; keep a field matrix for each intentional Mira extension. The new Swift codec round-trips the full Mira format.
- Check zero-based event positions, millisecond times, numeric turn/step scope, stable message IDs, backward source references, required surface operations, and unknown-required-event refusal.
- Check request header/context separation, unchanged-header reuse, explicit resume snapshots, exact argument strings and all three tool-correlation fields.
- Reconstruct every synthetic outgoing request from its committed prefix; stream expansion reproduces block order, delta boundaries, timestamps and replay state.
- Normalize usage with fixtures where cached input is nonzero; missing counters stay missing. Verify failed attempts, interruptions and local replies do not masquerade as successful model messages.
- Use this matrix in the existing refactor phases; do not add a second persistent transcript, a compatibility codec, or a generic schema framework.
