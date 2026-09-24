# Memory save retry verification

Date: 2026-09-24
Issue: [#65](https://github.com/alwynou/mira/issues/65)
Branch: `codex/memory-save-deduplication`

## Diagnosis

A read-only inspection confirmed two current representations of the same name: a name-only fact and a fuller profile. They were not historical revisions. The save sequence first used an invalid quotation assembled from multiple user turns. It then selected an incompatible preference as a target, and later selected that preference alongside the valid name fact. The generic target error did not distinguish the kind mismatch. The final retry removed every enrichment target and succeeded as an independent save, leaving the name-only fact current. Automatic recall had not included the name, and a targeted search happened only after the first failed calls.

The personal library was not modified. No personal text, identifiers, database files or credentials are included in the issue, fixtures or this report.

## Change

Shared conversation and tool instructions require a fact-specific search before an explicit save, resolve referential requests from the conversation, select overlapping assertions instead of every same-subject memory, and retain compatible targets when correcting a failed save. They explicitly forbid dropping consolidation targets to save overlapping facts independently. The quote schema explains its exact current-message boundary. An authorized enrichment target with a mismatched kind receives a specific recovery diagnostic, localized in English and Simplified Chinese for display. Replacement, source, scope, privacy, revision and transaction rules remain unchanged.

Semantic overlap and target selection remain model decisions. The host does not merge by text similarity or silently discard a proposed target. This change does not retroactively consolidate existing personal records.

## Evidence

- The new synthetic production-runtime scenario uses a name-only fact, a separate nickname preference, a later occupation statement and a short save request. It exercises search, invalid combined quote, mixed-kind targets and a corrected save that retains the name target.
- Before the implementation, that scenario failed its two recovery-diagnostic assertions: the next model request contained only the generic invalid-target error. With the change, the corrected save leaves one current name-bearing profile and the untouched nickname. The name-only predecessor becomes history, both selected evidence sources remain attached, failed calls have no write intent or receipt, and only one business receipt is created.
- Passed 50 focused package tests across five suites: `MemoryRememberToolTests`, `MemoryWorkflowTests`, `MemoryRememberHandlerTests`, `MemoryEnrichmentTests` and `MemoryAcknowledgmentWorkflowTests`. Coverage includes exact target binding, invalid quotes, replacement isolation, stale/foreign/private targets, source suppression, relation/receipt rollback, replay idempotency and instructions delivered to subsequent model steps.
- Passed `python3 scripts/check_language_policy.py`: 2,344 bilingual strings.
- Passed the Debug macOS app build using the standard `Mira` scheme, resolved package versions and `CODE_SIGNING_ALLOWED=NO`.
- Passed the six `MiraHostTests/LocalizationTests` tests, including rendering the new recovery error in both supported locales without changing its diagnostic value.
- The requested full local `MiraHostTests` run passed all 114 Swift Testing tests and 49 XCTest cases, with three opt-in live cases skipped. One unchanged native window-shell test failed at `MiraWindowShellTests.swift:141` because the synthetic divider did not enter mouse tracking; one focused rerun failed at the same boundary. This is recorded as a local native-interaction failure, not a pass or an assertion weakened for this change.
- Regenerated the project with `xcodegen generate` with no generated diff. Required CI, including the full package suite on macOS 15 and app/host tests on macOS 26, remains the merge gate.

## Limits

Scripted model calls verify the real journal, validation, tool observations and business effects; they do not prove a live provider follows the revised search and retry guidance. No paid model requests or changes to the personal library were made. Native layout is unchanged; this task does not claim new visual or macOS 15 runtime acceptance. Existing duplicates require a later explicitly targeted enrichment.
