# Functional milestones verification

Date: 2026-09-07. Branch: `dev`. Runtime: macOS 26.6.2 (25G83), Apple Silicon.

The user authorized completing natural memory capture, memory evolution, natural
recall, Markdown knowledge Q&A, and local tasks/reminders while deferring checks
that require their participation. This increment implements those five paths.
It does not declare all v0.1 release quality gates complete.

## Implemented scope and evidence

| Functional path | Result | Deterministic evidence |
| --- | --- | --- |
| Ordinary automatic memory | Opt-in extraction v2 uses exact user evidence, advisory assertion metadata and a conservative host gate. Stable preferences and constraints can activate without a manual “remember” command. | `MemoryExtractionValidatorTests`, worker/application/privacy suites; the authored EverydayMemory host gate accepts 16/16 positives with 0 unsafe activations across 16 negatives. This is synthetic gate coverage, not model accuracy. |
| Memory evolution | Independent aspects coexist. A clearly stated change can replace one same-aspect, unchanged, extractor-observed record. User-confirmed, manually revised or ambiguous conflicts remain candidates. Revision history and forgotten/superseded citation tags remain available. | `MemoryExtractionCommitTests` covers coexistence, replacement, manual conflicts, revision binding and purge. Backup validation checks assertion metadata against source hashes and historical revisions. |
| Natural recall | Bounded English/Chinese local alias expansion retrieves related current memories for ordinary questions. Existing scope, lifecycle and disclosure checks still apply. | `NaturalMemoryRecallTests` and `MemoryContextTests`, including unrelated queries and protected/forgotten records. No embedding service or extra model request is introduced. |
| Markdown Q&A | Source-oriented questions can prefetch current, authorized chunks. Query framing is stripped on word boundaries; memory and source context share a bounded budget. Used chunks are recorded for citation validation. | `KnowledgePrefetchTests`, `KnowledgePrefetchApplicationTests`, existing source/search/backup suites. Coverage includes current versions, source citations, local-only sources and workspace isolation. |
| Tasks and one-time reminders | Scoped manual and conversational creation/editing, completion/cancellation/reopening, independent proposal review, evidence and revision history. The scheduler records permission, scheduling and recovery separately from a saved task. | `TaskTimeTests`, `TaskWorkflowTests`, `ReminderSchedulerTests`, `TaskIntegrityTests`, `TaskPresentationTests` and native `TaskUITests`. |

Task tests cover exact English/Chinese commands, missing-time review and acceptance,
revision conflicts, identical tool calls and terminal receipt replay, denied
permission recovery, schedule updates/cancellation, asynchronous edit races,
strict source-date/time-zone anchoring, DST gaps/overlaps, ambiguous periods and
recurrence rejection. Restore pauses reminders until an explicit resume. Orphan
cleanup checks both the library namespace and canonical task existence, including
requests outside a bounded work page. Corrupt receipt, revision and indexed status
snapshots are rejected.

The current native task test performs creation, editing, completion, filtering,
reopening and application relaunch with an isolated demo library. It uses the real
macOS accessibility/XCTest interface, a synthetic provider and no real notifications.

## Limited real-provider check

One authored scenario, `en-savory-breakfast`, was run against the configured
`deepseek-v4-flash` conversation/extraction routes with the existing Keychain
credential. The shared ceiling was four provider dispatches; **three were used**:
initial reply, automatic extraction and a new-conversation follow-up. No retry or
environment-key fallback was needed.

The ordinary statement became one active memory with its exact source wording.
The unrelated-conversation breakfast question prefetched that memory, produced a
relevant savory-breakfast answer and included one successfully resolved citation.
The user did not ask Mira to search or save memory in either message. The fixture
library was deleted after shutdown. [The report](evidence/functional-milestones/live-breakfast.json)
contains synthetic prompts/results and model identifiers, with no keys or personal
conversation history. One successful case does not establish general semantic
recall, extraction precision, or other-provider qualification. Tasks and knowledge
were not subjected to additional paid tests in this increment.

## Verification commands

- `swift test --package-path Packages/MiraKit` — full package acceptance.
- `xcodebuild -project Mira.xcodeproj -scheme Mira -configuration Debug -destination 'platform=macOS' -derivedDataPath .build/xcode -onlyUsePackageVersionsFromResolvedFile -skipMacroValidation CODE_SIGNING_ALLOWED=NO test` — hostless platform and presentation checks; the live test skips without explicit opt-in.
- `xcodebuild -project Mira.xcodeproj -scheme MiraUI -configuration Debug -destination 'platform=macOS' -derivedDataPath .build/xcode -onlyUsePackageVersionsFromResolvedFile -skipMacroValidation CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual test` — native UI automation with ad-hoc signing.
- `python3 scripts/check_language_policy.py` plus compiler-extracted app strings — English implementation/prompts and complete English/Simplified Chinese UI resources.
- `xcodegen generate` and `git diff --check` — generated project and review hygiene.

Final package acceptance passed **389 tests in 43 suites**. Host acceptance passed
**62 Swift Testing tests in 13 suites**, plus **6 XCTest checks**; the single opt-in
live XCTest skipped in that offline run and passed separately in the bounded live
run above. All **4 native UI workflows** passed: English conversation persistence,
Chinese conversation persistence, cancellation/composer recovery and the task
lifecycle. The app Debug build passed. Language validation passed **1,273 bilingual
entries**, including compiler-extracted strings.

Reproducible local evidence paths (generated logs are not committed):

- `/private/tmp/mira-functional-package-accepted2.log`
- `/private/tmp/mira-functional-host-accepted.log`
- `/private/tmp/mira-functional-native-final.log`
- `/private/tmp/mira-functional-app-accepted.log`
- Native result: `.build/xcode/Logs/Test/Test-MiraUI-2026.09.07_03-55-38-+0800.xcresult`

An earlier task presentation test incorrectly expected a completed item to remain
selected while the completed filter was off; corrected assertions cover both
filter states. A subsequent package run exposed floating-point rounding between
JSON milliseconds and SQLite seconds. Task timestamp validation now accepts only
representation-level ULP differences, and a fractional-second regression fixture
verifies normal reminder round trips. The final package run includes that fix.

## Deferred acceptance and development reset

The following remain explicitly unverified and were skipped under the user's
instruction: granting/checking real notification permission, actual alerts after
quitting Mira and under Focus, macOS 15 runtime behavior, other CPU architectures,
signing/notarization for public distribution, and the seven-day usage gate.
Human-labeled Q04–Q06 memory evaluation and broader provider qualification remain
separate release work. Further streaming-performance and detailed billing work
remain deferred as previously requested.

Development schema is now 12. The old `.build/dev-library` was deleted in place
and recreated without a backup or compatibility converter. Only unchanged model
configuration was held briefly in process memory and reinstalled; Keychain keys
were untouched. Old conversations, extracted memory and test records were not
retained. The new normal library starts with automatic capture disabled until the
user explicitly enables its mode and budget.

The final Debug app was ad-hoc signed for local launch and opened against the recreated `.build/dev-library`; the Mira process and one native window were confirmed. This is a development run, not a signed/public distribution package.
