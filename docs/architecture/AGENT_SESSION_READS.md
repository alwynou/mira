# Authoritative session reads and query projections

This document defines readers for the canonical [session log](AGENT_SESSION_LOG.md).
The journal is the authority for session identity, committed execution facts,
message order, tool exchanges, and request provenance. SQLite projections and
search indexes are disposable query aids; they do not admit work, authorize
business writes, or supply model history.

## Fixed-prefix reads

`JournalSessionReader` captures a `SessionJournalHead` and reduces exactly that
committed prefix. It validates contiguous DSH event sequences, session and event
identities, turn/step relations, physical commit checksums, and required Mira
extensions. A target cannot end inside a physical frame. New appends after the
captured head do not expand the read.

The reader returns immutable inline message content and typed source references.
It does not resolve a payload path, consult an active-draft sidecar, or decode a
request manifest. Request evidence points to committed route, system, tool
header, user message, and context facts; the full historical provider HTTP body
is intentionally unavailable. A request inspector may show those facts and the
derived context, with an explicit unavailable state where exact wire bytes were
not persisted.

History reconstruction derives complete exchanges from committed user,
assistant, and tool records. It preserves thinking blocks and provider
continuation data recorded in settled attempts, applies the recorded source and
budget rules, and never invents a model message from an unsettled stream. A
hard-crashed stream prefix is absent by design. Orderly cancellation can settle
the consumed prefix before the journal head is published.

## Execution audit and historical sources

`SessionQueryService.executionAudit` reads the selected execution and its model
attempts at one captured head. It returns committed request evidence, settled
assistant/tool blocks, terminal facts, usage metadata, and explicit failure or
cancellation records. It does not expose process-local output that has not
settled and does not re-encode an old request through current adapter settings.

`AgentSourceReference.sessionExecution` resolves through the authoritative
journal and current source authorization. `domain` references resolve through
their domain authority. Reading an old event proves provenance; it does not
grant current business write permission. Consumers that need a business effect
must recheck current authorization and required tool-plan sources in the
business transaction.

## Recovery and projections

On startup, `AgentApplicationRuntime` reads the current journal head, identifies
unfinished executions, and settles known tool receipts and execution facts
without dispatching a model or tool. Recovery has no model-draft input. If the
unresolved process-local stream was lost, the execution records an interrupted
or failed terminal fact according to the runtime contract.

Indexes, query projections, and any recovery summary are disposable,
authenticated derivations of committed journal bytes. They may accelerate a
read but must be discarded and rebuilt when their source head, schema, or
authentication binding differs. They never replace journal reduction and never
authorize a write.

## Concurrency and privacy boundary

Readers hold the library access lease for the complete asynchronous operation.
After content is read, the lease and domain authorization are checked again
before publication. A source revocation or library close therefore suppresses
the result even if an earlier check succeeded. This check is not an atomic
transaction across the journal, SQLite, and external systems; business writes
still require their own transaction boundary.

Session content is inline journal data with no session-specific erasure plan,
retention group, or transitive invalidation graph. Memory, knowledge, and other
domains retain their own evidence and forget contracts; their cleanup does not
create a second session-content store.

## Consumer handoff

The [persistent session consumers](AGENT_SESSION_CONSUMERS.md) receive bounded
committed batches and durable business cursors. A batch cursor is an input to a
consumer transaction, not a permission grant. The consumer re-resolves any
source needed for a domain job and commits its business facts and cursor in the
same domain transaction.
