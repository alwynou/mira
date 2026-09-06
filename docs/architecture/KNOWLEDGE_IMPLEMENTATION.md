# Markdown knowledge implementation

This document owns the v0.1 Markdown implementation profile. Product scope remains in [MVP](../MVP.md); broad domain design remains in [Memory and knowledge](MEMORY_AND_KNOWLEDGE.md). Verification evidence belongs in engineering documents.

## Ownership and import

The host presents an explicit file picker for `.md` and `.markdown`, with at most 100 files per batch and 10 MiB per file. It holds security-scoped access only during each selected-file read and releases it afterward. This snapshot profile retains no bookmark, watched directory, external canonical path, or continuing access grant. Updating a source requires choosing a file again. The imported copy is managed independently of the original file; deleting it never modifies that original.

New sources belong to the current workspace, or global scope from Inbox. Imported bytes default to local-only. An explicit source setting permits remote use, subject to the conversation workspace's current outbound policy and connection allowlist. Shared physical bytes never grant cross-scope access. The store checks scope before returning metadata or text, and tools record and revalidate usage before returning payloads.

Identical bytes in the same scope reuse an existing source/version. Matching filenames alone never overwrite a source. An explicit update checks the reviewed source revision and creates a new immutable version, keeping all previous versions. Invalid UTF-8 or binary controls produce a failed version retaining the original blob and a safe error. Failed updates leave the last successful current version unchanged. Extension, size, authorization, nonregular file, symlink, or read-time replacement failures reject the import before committing a version.

## Parsing and positions

`markdown-lines-v1` is a Foundation-only line/fence-aware segmentation profile, not a complete CommonMark AST. It recognizes ATX and setext heading paths and backtick/tilde fences. Heading syntax inside a fence does not affect navigation. Bounded paragraphs and fences stay together where practical; long lines and fences split at Unicode scalar boundaries. The target is 4 KiB and each chunk contains at most 8 KiB of raw UTF-8 text.

Original text is preserved, including CRLF. Concatenating chunk text reproduces the decoded source after an optional UTF-8 BOM. Locators contain inclusive one-based line numbers and half-open zero-based UTF-8 byte offsets in the original blob, including the BOM offset. Heading metadata is limited to six levels and 512 UTF-8 bytes per heading; shortening metadata does not alter source text or positions. UUID chunk identities are assigned once when the immutable version commits.

Source previews use selectable plain text. Markdown images, HTML, scripts, links, and Wiki Links do not trigger network requests or execution. Source-derived memory extraction is optional future work and is not enabled by importing a file.

## Search

Only a source's current successful version enters search results. Historical versions remain available through explicit local inspection and authorized exact references, including version/chunk-specific tools under the source's current disclosure policy. Search normalizes a separate text projection using compatibility normalization and case/width/diacritic folding; original text and offsets remain unchanged.

The host opens the exact chunk selected from search, even when it falls outside the detail pane's first 200 chunk summaries. Source/version selection invalidates pending chunk reads; an action from a stale version cannot populate the new selection. The selected chunk also owns its sheet presentation, so clearing the selection or deleting the source dismisses that body.

The word and trigram FTS paths generate literal quoted terms and bind SQL arguments. Post-filtering treats query terms literally, including `%`, `_`, quotes, operators, type names, and path fragments. Short queries, or a missing trigram projection, use a bounded normalized-text candidate scan. Scope, deletion, current version, and remote-use filters apply before candidate processing. The scan permits at most 20,000 eligible candidates and a 200 ms monotonic deadline, enforced during SQLite work with a progress handler. Results disclose truncation and inspected candidate count; the UI asks for a more specific query when incomplete. Deterministic ranking prefers an exact phrase and title match, with chunk ID as the final tie-break.

## Tool and citation contract

| Tool | Input | Result |
|---|---|---|
| `knowledge.search` | Literal query, at most 500 Unicode scalars | At most six 1,200-byte snippets, source/version/chunk IDs, exact references, and truncation status |
| `source.open` | Source UUID and optional version UUID | Selected version metadata and at most 40 chunk summaries; body reading is a separate action |
| `source.readChunk` | Chunk UUID | Complete bounded text and its exact reference |

Closed schemas reject unknown fields, invalid types, and invalid optional UUIDs. Tools derive scope and connection identity from the persisted live execution. Caller-supplied source identifiers cannot choose a different workspace or provider. Results are bounded after JSON encoding, and descriptions identify file content as untrusted data.

The exact citation syntax is `[source:<version-uuid>#<chunk-uuid>]`. A recognized token is only a proposal: the local resolver requires a matching persisted chunk usage by that reply, matching conversation scope, a readable historical version, and current disclosure policy. Metadata-only `source.open` does not authorize a body citation. Search snippets and full chunk reads do. Updating a source never retargets an earlier reference. Unused, guessed, cross-scope, deleted, or revoked references are unavailable.

Citation buttons retain availability state rather than a source body. Opening a citation performs a fresh resolution for the reference, execution, and conversation together. While the sheet is visible, application changes revalidate that same identity and clear unavailable content; closing the sheet clears its presentation copy. This uses the application's existing change stream and does not claim observation of out-of-process database edits.

`source_usages` records source, version, optional chunk, execution, and time. Request audit metadata includes `sourceVersion` and `sourceChunk` references; these do not enter provider wire bodies. History dependencies propagate usage into later requests, and policy is rechecked before dispatch. Revoking remote use or deleting a source purges dependent request/output/tool/draft/assistant bodies transitively and blocks late writes. Original user messages remain local history; preserved source-use markers carry no source text.

## Managed files and recovery

The current schema v11 includes sources, immutable versions/chunks, usage, search projections, and managed blob metadata. Earlier schemas are rejected intact; there are no converters. Blob paths derive only from lowercase SHA-256 digests. Selected-file and managed-file operations use verified regular files, bounded reads, and protected directory traversal. File publication precedes the database transaction: temporary bytes are fully written and synchronized, atomically installed, then referenced by a single database commit. A failed database commit can leave an orphan file, never a reference to a partial file.

Import, backup, and garbage collection share a maintenance boundary across store instances and processes. All retained historical versions count as references. Deleting a source removes its versions/chunks and marks newly unreferenced files for cleanup. Ordinary collection waits at least seven days and rechecks references while holding the maintenance boundary. The Settings cleanup action also discovers orphan files; their grace period begins when first discovered. Failures preserve referenced canonical data and remain visible. This is logical deletion and ordinary filesystem cleanup, not a secure-erasure promise; existing backup copies are not rewritten.

The backup API creates a new directory bundle containing `Mira.sqlite`, `manifest.json`, and only referenced `Blobs`. The manifest identifies format/schema/app version, byte counts, and SHA-256 digests. Export and restore use owned staging and publish only verified complete results. Restore validates the original bundle before opening any staged SQLite copy, checks exact schema/constraints, integrity, foreign keys, typed relationships, and chunk bytes against their original blobs. Automatic extraction is disabled and uncertain work paused in the restored copy. Existing libraries and original backups remain unchanged. Backup credentials, signing, and real-model acceptance remain separate from deterministic restore tests.

The database limit is 2 GiB, the referenced blob total is 2 GiB, each blob is at most 10 MiB, and the manifest is at most 8 MiB with 100,000 blob entries. Database hashing and copying use 64 KiB buffers with descriptor/path identity checks, nonblocking regular-file opening, exclusive destination creation, synchronization, and incomplete-copy cleanup. The database size limit is independent of buffer allocation. It replaces the initial 512 MiB ceiling because the reference 50,000 chunks include canonical text, normalized text, and two FTS content projections. These are bounded local-library limits; they do not imply unbounded backup capacity.

The short-query fallback explicitly scans chunks in rowid order before looking up each source. This avoids sorting the full wide-row candidate set before the deadline can return a useful result. Scope, current-version, deletion, and remote-use filters still run inside SQL before the candidate count. The implementation uses SQLite's documented [CROSS JOIN loop-order guarantee](https://www.sqlite.org/optoverview.html#manual_control_of_query_plans_using_cross_join); the regression checks the actual production query plan for absence of a temporary ordering B-tree. Indexed FTS queries retain their existing plan.
