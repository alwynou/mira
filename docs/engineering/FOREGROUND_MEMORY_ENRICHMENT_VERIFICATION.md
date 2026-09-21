# Foreground memory enrichment verification

Date: 2026-09-21
Issue: [#36](https://github.com/alwynou/mira/issues/36)
Branch: `codex/remember-enrichment`

## Corrected diagnosis

PR #35 fixed a verified background-extraction contract gap, but it did not address the foreground save tool used in the reported interaction. A read-only inspection of the specific local records found explicit-user origin, no extraction-aspect metadata, a `memory.remember` journal invocation and both prior memories already included in the model request. No personal conversation text or identifiers are copied into this document or the issue.

The foreground schema could not name an enrichment target, and its handler always passed `replacing: nil`. Source-bound exact assertion reuse therefore created a new current record for each new statement. The correction adds explicit bounded targets to this route rather than relying on the background worker to clean up an already-committed foreground save.

## Behavior and boundaries

The tool can consolidate up to six explicit current representations of the same identified entity into a complete memory. The host preserves target validity and disclosure, checks exact revisions, inherits all source evidence and supersedes all selected targets in the same business-receipt transaction. Semantic identity and non-conflict are model judgments; the host cannot prove arbitrary natural-language entailment. Unselected records are not rewritten.

A second deterministic gap was found during the production-path regression: superseding a recalled memory invalidated the next model step because context authorization required the newest current revision. Context source authorization now validates the original retained revision under current privacy and lifecycle gates. Current recall and mutation CAS remain strict. Historical context never redirects an old reference to the new memory or resurrects an old current record.

No storage schema, native layout or credential changes are required. The personal library was only inspected for the matched records and their invocation metadata; it was not edited or cleared. No compatibility decoder or migration bridge was added.

## Evidence

- Passed 82 focused Swift tests in 15 suites: 16 core tests and 66 data tests. The selection covers `MemoryRememberToolTests`, `MemoryModuleTests`, `MemoryContextSourceTests`, `MemoryWorkflowTests`, `MemoryRememberHandlerTests`, `ProductionToolWorkflowTests`, `MemoryEnrichmentTests`, `JournalMemoryExtractionCommitTests`, `MemoryApplicationOwnershipTests`, `MemoryHistoryWorkflowTests`, `MemoryHistoryStoreTests`, `SQLitePendingRecoverySourceTests`, `SQLiteMemoryPrivacyStoreTests`, `MemoryExtractionWorkflowTests` and `JournalMemoryExtractionStoreTests` via `swift test --package-path Packages/MiraKit --filter`.
- The production workflow consolidates two current memories with distinct original user sources, preserves all three evidence sources, supersedes both targets, recalls only the successor and completes the next model step. Replaying the persisted effect proof twice returns the original receipt without extra records, evidence or relations. Suppressing an inherited source makes replay authorization fail.
- A synthetic relation-insertion failure leaves both targets current and rolls back the new memory and copied evidence. Stale revisions, foreign workspace targets and local-only targets are rejected. Historical source tests cover retained exact revisions, nonexistent revisions, current disclosure revocation, source suppression and archival.
- Passed the Debug macOS app build with `xcodebuild -project Mira.xcodeproj -scheme Mira -configuration Debug -destination 'platform=macOS' -derivedDataPath .build/xcode -onlyUsePackageVersionsFromResolvedFile CODE_SIGNING_ALLOWED=NO build`.
- Passed `python3 scripts/check_language_policy.py` (2,240 bilingual strings), `git diff --check` and project regeneration with `xcodegen generate` (no generated project change).
- Required PR CI remains the merge gate, including the full package suite on macOS 15 and app/host tests on macOS 26. Local build success is not evidence of either runtime test environment.

## Limits

Regression fixtures use fictional entities, temporary databases and synthetic model streams. They verify the real journal, tool preparation/policy, business transaction, receipt publication and next model step. They do not establish live-model semantic classification quality, native visual acceptance or arbitrary retrospective cleanup. Existing records are consolidated only when explicitly selected by a later enrichment; no bulk personal-library sweep is performed.
