# Conversational task command verification

Date: 2026-09-28. Scope: [issue #75](https://github.com/alwynou/mira/issues/75).

## Diagnosis and final contract

The reported conversations reached `task.change`, but an internal natural-language parser rejected the already normalized commands. Literal today matching blocked a clock-only reminder. A narrow initial adjustment still failed on harmless title extraction/spacing; a subsequent date clarification failed because the current message did not repeat the whole task. These were tool-domain restrictions, not missing tool registration. Personal journal text and identifiers are excluded from this report and all fixtures.

The final command API removes that duplicate semantic gate: no sentence allowlists, negation regex, verbatim title/notes matching or natural-language clock re-parsing. The model interprets the visible conversation, resolves references and normalizes structured fields. It is instructed to clarify genuinely ambiguous requests and not act on quotations, hypothetical/negated requests or unsupported recurring/conditional schedules. The tool schema no longer asks for copied user/time quotes. The host attaches the actual admitted message's complete journal evidence automatically; the mutation descriptor is revision 2.

Structural invariants remain: strict clock/calendar/time-zone resolution, rejection of conflicting date fields, future reminder times, exact target workspace/revision, current source/lifecycle and library authorization, atomic task/revision/receipt writes, durable deduplication and honest notification state. A clock with no date uses the invoking message's local day, never tomorrow by rollover. Retries use that same admitted date. Missing/invalid/DST-ambiguous or elapsed reminder times produce actionable review results and require explicit correction. Due-only proposals do not gain a reminder. Existing proposals remain pending; there is no data-schema migration or automatic approval.

## Focused automated checks

- `swift test --package-path Packages/MiraKit --disable-automatic-resolution --filter 'TaskTimeTests|TaskWorkflowTests|TaskToolSequenceTests|SessionActivityTests|SessionAuditQueryTests|ProductionToolWorkflowTests|SQLiteBusinessArchiveTests|SQLiteBusinessReceiptStoreTests'`: passed, 46 tests in eight suites (37 data and nine core tests, with parameterized cases).
- The core tests now assert the structured contract, including normalized titles/dates, varied wording, relative dates beyond literal today/tomorrow, original local day, midnight retry, malformed clocks/dates, conflicting date fields and DST gaps/overlaps. Old assertions that the tool should parse or veto natural language were removed with that architecture; they are not semantic-model quality evidence.
- Bilingual multi-turn runtime fixtures first ask for a time, then receive a short date/time clarification without the task title/action. The production journal/tool/SQLite pipeline saves exactly one task, retains both messages in model context, binds evidence to the actual follow-up and leaves no proposal. Other cases exercise list/update/complete/cancel with conversational references, stale targets, forbidden source overrides, source scope, receipts, archives, audit queries, duplicate calls and permission-denied notifications.
- `xcodebuild -project Mira.xcodeproj -scheme MiraCompositionTests -configuration Debug -destination 'platform=macOS' -derivedDataPath .build/xcode -disableAutomaticPackageResolution -only-testing:MiraCompositionTests/LibraryExecutionTests -only-testing:MiraCompositionTests/MacTaskManagementFixtureTests test`: passed, two tests.
- `xcodebuild -project Mira.xcodeproj -scheme Mira -configuration Debug -destination 'platform=macOS' -derivedDataPath .build/xcode -disableAutomaticPackageResolution -only-testing:MiraHostTests/LocalizationTests/testTaskStateAndReminderExplanationSwitchWithLocale test`: passed, one test; also built the final Debug app. The new invalid-command diagnostic resolves in both languages.
- `xcodegen generate`, language policy (2,445 bilingual strings) and `git diff --check`: passed.

The first broad package run reported one failure among 1,130 tests: a Responses protocol fixture still sent the removed `quote` argument. Its command was updated to the current schema; `--filter OpenAIResponsesProtocolTests` then passed all 21 tests. No production code changed in this correction.

Broad regression is delegated to the PR's selected CI checks before merge rather than repeated locally. The PR check history records the final revision and result.

## Native synthetic verification

Environment: Apple Silicon, macOS 27.0 (26A428), Asia/Shanghai, Chinese UI and light appearance. The Debug app ran with `--demo --verify-task-time --data-directory /tmp/mira-task-time-native-75`. The disposable demo library was recreated at the same path for the final contract. This explicit offline model exercises the production task tools; demo notifications are denied and no real notification is scheduled.

At approximately 15:45 local time, `Remind me to review notes` received a time-clarification question. In the same conversation, `Today at 18:00, please` completed `task.list` and `task.change`. Tasks showed the saved record at September 28, 18:00, with the exact follow-up as source, and truthfully indicated that notification permission was required. Needs review was empty. Accessibility state and a full-window capture were inspected; the source, time and notification explanation were visible.

A separate `remind me at 09:00 to review notes` returned the elapsed-time explanation and said no task or notification was committed. The initial implementation's native checks had also verified that the review editor retained the original past date, required exact-time confirmation and disabled acceptance; this UI was unchanged by the final domain rewrite. The regular app was reopened with the final rebuilt binary and normal library after verification.

An initial keyboard-automation input in the earlier verification lost a colon (`1800`). It produced a missing/invalid-time proposal; clipboard paste was used for subsequent native requests. This input artifact is not an application parsing failure. Native tool screenshots returned Stage Manager thumbnails, so the screenshot helper supplied full-window captures.

## Limits

No live provider request was made. Deterministic fixtures prove tool execution, context availability, persistence and native state; they do not prove model intent judgments, tool choice or wording across providers. Those semantics now belong to the model instead of an unreliable language-specific tool parser. Actual OS delivery, authorization prompts, dark appearance, minimum-size layout, full accessibility and macOS 15 runtime were not requalified. No layout, locale-resolution or notification-platform code changed; existing release gates remain separate.
