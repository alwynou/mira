# Automatic memory verification

Date: 2026-09-05; CI confirmed 2026-09-06. Branch: `dev`. Local deterministic acceptance and exact-commit CI passed. Native interaction and real-model quality remain separate, deferred gates; this does not mark M3 or the MVP released.

## Implemented boundary

Capture starts disabled. Explicit settings choose candidate review or conservative automatic activation and a daily UTC token budget. Dedicated purpose routing, source/workspace disclosure, committed user authorship, source suppression, and frozen policy are checked before sending and again before commit. Initial processing does not backfill history. Explicit retries preserve original job/attempt provenance across policy changes and restore.

The worker owns one leased job independently of view lifetime. It builds an English schema-bearing prompt, bounds output, observes cancellation and a 90-second deadline, validates exact quotes and host-derived scope, and commits memories/evidence/revisions/decisions/accounting together. Candidate review and edits grant explicit user authority while preserving capture origin. Category overlap never automatically replaces an existing assertion. The English and Simplified Chinese UI exposes opt-in settings, durable processing status, review/source links, and disabled-mode retry restrictions.

Fresh schema v6 preserves each attempt's immutable route and original reservation ceiling. Unknown dispatched usage charges the ceiling; valid reported usage above it is recorded without clamping. Forget clears extraction payloads and dependent foreground bodies while retaining the original user message and body-free accounting. Restoring first validates the original snapshot in owned staging, then disables automatic capture and pauses uncertain jobs in the restored copy. Older schemas are preserved and rejected.

The technical contract is [Automatic memory implementation](../architecture/AUTOMATIC_MEMORY_IMPLEMENTATION.md); product scope and external gates remain in [MVP](../MVP.md) and [Quality](QUALITY.md).

## Local evidence

Environment: macOS 26.6.2, Apple Silicon, Xcode 26.6, Swift 6.3.3; deployment target macOS 15.

| Check | Result |
|---|---|
| Complete Swift package | 201 tests / 24 suites passed; `/private/tmp/mira-extraction-final-package.log` |
| Host tests | 5 localization XCTest cases and 11 Swift Testing cases across isolated Keychain and renderer suites passed; `/private/tmp/mira-extraction-final-host.log` |
| Debug app | Built as part of the successful host test run |
| Release app | Build passed; `/private/tmp/mira-extraction-final-release.log` |
| Localization | 801 bilingual keys; source policy and compiler-extracted Debug coverage passed; all 673 previously committed entries preserved |
| Source/project consistency | XcodeGen regenerated the project; `git diff --check` passed |
| Exact-commit CI | Commit `9fa7212b3700d0dc24b8763049941935e6a041d2` passed [CI 33977078523](https://github.com/alwynou/mira/actions/runs/33977078523), including package tests, app/host tests, language policy, and extracted UI coverage |

Fixtures cover opt-in/no-backfill, dedicated routing and permissions, exact source/request ownership, foreground priority, lease/restart recovery, explicit retries, midnight reservation transfer, actual/unknown settlement, malformed output, transaction failure, candidate review and later recall, disable/forget during suspended extraction, fractional timestamp round trips, and independently corrupted backup relationships. The synthetic provider returns source-matching quotes, so late-result rejection is not accidentally explained by a mismatched fixture quote.

Parent review found and fixed real defects beyond compilation: nested database reads, queue blocking, route/policy history overwritten by retry, missing response schema, incomplete usage accounting, scalar/JSON authority mismatch after approval, Date representation differences, and missing child purge/lease/accounting checks in restore. Failed corruption fixtures were retained until the corresponding validation rejected them. Delegated parse checks were provisional; full parent runs establish the evidence above.

Existing renderer warnings concern its pinned Swift 5 mode, Sendable font values, and older SwiftUI callbacks. Xcode also reports the expected absence of App Intents metadata. These warnings are not treated as new first-party runtime acceptance.

## Deferred evidence

No real provider endpoint, paid model call, attended Keychain exercise, or human-labeled memory evaluation was performed. Q04–Q06 precision/recall and seven-day actual use remain open; a narrow deterministic activation lexicon does not establish those quality targets.

The earlier native automation service repeatedly crashed. Automatic capture settings, extraction review/source navigation, live bilingual screen switching, and the remaining manual-memory walkthrough need a functioning native service or attended session. Compilation, host tests, and transaction tests do not substitute for that UI evidence. macOS 15/Intel runtime, signing, notarization, and installation acceptance are also deferred in the [execution ledger](MVP_EXECUTION.md).
