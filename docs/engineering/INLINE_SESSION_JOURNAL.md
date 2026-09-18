# Inline session event journal

> Historical engineering record. The current contract is [AGENT_SESSION_LOG](../architecture/AGENT_SESSION_LOG.md). Measurements and implementation details below describe an earlier format and are not current acceptance criteria.

Date: 2026-09-16. Baseline checkpoint: `08e2083`.

## Change

Each conversation retains one append-only JSONL event journal. Ordinary UTF-8 payloads now live inside the same checksummed record as their publishing events. This includes user messages, assistant output, thinking, requests, tool calls/results, drafts and replay data. Logical payload references continue to identify their owning batch, retention group, byte count and digest; they no longer imply a separate file.

The physical envelope is `{checksum, record:{batch, payloads}}`. `payloads` maps canonical UUID strings to exact UTF-8 text. JSON escaping preserves newlines and quotes without adding physical JSONL lines. Binary bodies, text over 256 KiB, and bodies that exceed the 2 MiB encoded inline allowance for a batch use the existing external payload publication path. The encoded record body is capped at 8 MiB; event metadata keeps its existing 2 MiB bound.

The format is version 3. There is no old-format decoder or migration.

## Append-only and erasure

Normal admission, streaming checkpoints, tool results, completion, edits and retry retirement append new events. Retrying a failed execution hides its previous generated result through journal reduction and preserves its physical history. Startup does not rewrite a journal merely because a result was retired.

Explicit privacy invalidation is the physical-erasure exception. The writer builds a temporary JSONL with the selected inline bodies removed, synchronizes it, atomically replaces the source, and synchronizes the directory. Event and batch identities, sequence numbers, the logical head, and retained bodies remain unchanged. Byte-offset indexes and checkpoints are rebuildable and are bound to the new source bytes. Startup removes interrupted temporary copies and completes authorized erasures. An erased body's reference remains as content-free history.

Archives copy the JSONL and only its external payload files. Retired history remains in the archive until explicitly erased. Conversation reads continue to hide retired or erased content. Archive integrity validation can read retained retired tool proofs; this does not authorize their use as model context. Strict archive validation rejects missing retained bodies, corrupted hashes and erased content that remains physically present.

## Focused verification

- **154 tests in 17 suites passed** in `/tmp/mira-inline-final-acceptance.log`: inline/external publication, byte-for-byte append-prefix preservation, torn tails, uncertain commits, recovery, authenticated indexes/checkpoints, privacy maintenance, archive/restoration, state reduction, application admission, audit reads and background memory extraction.
- **22 archive tests in 4 suites passed** in `/tmp/mira-inline-archive-final.log` after the final archive-reader change. This includes 3 additional business-archive tests, for **157 distinct tests across 18 suites** overall. The new real-kernel regression reproduced archive failure after a tool succeeded and the answer was retried; archive validation now verifies the retained historical proposal while ordinary conversation reads still deny retired content. The before-fix log is `/tmp/mira-inline-retired-receipt-before.log`.
- `SessionPrivacyMaintenanceTests/selectingARetryAlsoInvalidatesItsOriginalFailedExecution` drives a synthetic interrupted stream, real application retry, file-library reopen and explicit forget. It proves the original JSONL prefix survives retry/reopen, retired bytes are physically removed only by forget, and the new visible answer remains readable.
- Final unsigned macOS Debug build: **BUILD SUCCEEDED**, `/tmp/mira-inline-app-build.log`.
- `git diff --check` and the language policy check passed; the Unicode persistence fixture carries an explicit test-only exception. No UI strings changed.

The primary selection was:

```sh
swift test --package-path Packages/MiraKit --filter 'InlineSessionJournalTests|SessionJournalTests|SessionPayloadRecoveryTests|SessionIndexTests|FileSessionCheckpointTests|SessionRecoverySummaryTests|JournalSessionReaderTests|FileSessionArchiveTests|SessionPrivacyMaintenanceTests|SQLiteLibraryArchiveTests|SQLiteLibraryRestorerTests|SessionStateTests|AgentApplicationRuntimeIntegrationTests|MemoryExtractionWorkflowTests|AgentExecutionRecoveryIntegrationTests|AgentBusinessJournalIntegrationTests|SessionAuditQueryTests'
```

The archive follow-up selected `SQLiteBusinessArchiveTests|FileSessionArchiveTests|SQLiteLibraryArchiveTests|SQLiteLibraryRestorerTests`.

Only directly affected boundaries were selected; no full package or unrelated UI suite was run. Synthetic tests do not call paid model endpoints. Runtime checks on this macOS 26.6.2 development machine do not establish macOS 15 runtime behavior or physical power-loss guarantees beyond the existing filesystem synchronization contract.

## Development library

The obsolete development library was deleted and recreated at `/Users/alwyn/Library/Application Support/Mira` without a backup or migration. The old database, sessions, knowledge blobs and projections were removed. An initial empty-root launch rejected leftover Finder `.DS_Store` metadata; that obsolete metadata was removed before the successful fresh launch. The native accessibility tree confirmed the empty conversation state and connect-model entry, with no library error. Keychain credentials and the shared local embedding model are separate resources and are retained. Provider/model settings must be configured again in the fresh library. No conversation files, databases, credentials or runtime exports are committed.
