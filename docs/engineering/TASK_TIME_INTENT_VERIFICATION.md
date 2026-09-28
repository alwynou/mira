# Conversational task time verification

Date: 2026-09-28. Scope: [issue #75](https://github.com/alwynou/mira/issues/75).

## Diagnosis and behavior

The reported conversation reached both `task.list` and `task.change`. The task handler required an explicit today token for `day_offset: 0`, so a clear clock-only reminder became a pending proposal even when its time was still ahead. Its generic result did not explain the failed source check and did not require time clarification. This was a domain admission problem, not a missing tool registration. Personal journal content and identifiers are deliberately absent from this report and the fixtures.

Supported English and Chinese ordinary reminder instructions with an exact clock and no date now use the original message's local day. They commit only while that time remains in the future. They never advance to tomorrow, including execution retries after midnight. Unknown date qualifiers, contradictory dates, ambiguous clocks, DST overlaps, negation and hypothetical instructions remain reviewable. The tool result now gives a bounded reason and required action; time failures on reminders require explicit correction before acceptance. Due-only proposals do not gain a reminder.

`task.list` advertises its authoritative `reference_time` and `time_zone` even with no tasks. The model is instructed to use them without Bash or a guessed working directory. Successful persistence remains separate from actual notification scheduling. Existing proposals retain their review state; no schema change or retrospective approval is included.

## Focused automated checks

- `swift test --package-path Packages/MiraKit --disable-automatic-resolution --filter 'TaskWorkflowTests|TaskTimeTests|TaskToolSequenceTests'`: passed, 38 tests in three suites (22 data tests and 16 core tests; parameterized inputs run within these tests).
- Coverage includes bilingual date omission, `6pm`, missing versus invented day offsets, original local date, execution after midnight, already elapsed times, unsupported or conflicting dates, DST overlap, existing intent guards and source/target authorization contracts.
- Production journal/runtime/tool/SQLite fixtures assert the exact saved date, source-backed tool receipt, absence of proposals on success, actionable proposal reasons, mandatory time correction, due-only semantics and notification permission denial without platform installs.
- `xcodebuild -project Mira.xcodeproj -scheme Mira -configuration Debug -destination 'platform=macOS' -derivedDataPath .build/xcode -disableAutomaticPackageResolution build`: passed.
- Language policy and `git diff --check`: passed. No new UI strings or layout changes.

Broad regression is delegated to the PR's selected CI checks before merge, rather than repeated locally. The PR check history records the final revision and result.

## Native synthetic verification

Environment: Apple Silicon, macOS 27.0 (26A428), Asia/Shanghai, Chinese UI and light appearance. The Debug app ran with `--demo --verify-task-time --data-directory /tmp/mira-task-time-native-75`. This explicit offline model exercises the production `task.list` → `task.change` pipeline. Demo notification permission is denied and no real notification is scheduled.

At approximately 15:34 local time:

1. `remind me at 18:00 to review notes` completed two tool calls and reported a saved task. Tasks showed September 28 at 18:00, the exact source, and the truthful notification-permission requirement.
2. `remind me at 09:00 to review notes` returned the elapsed-time reason and explicitly said no task or notification was committed. Only the first task appeared in the active list. Needs review contained the second request; the editor retained 09:00 on September 28, required exact-time confirmation, displayed the future-time instruction and disabled acceptance.
3. An initial keyboard automation input lost its colon (`1800`). It correctly produced a missing/invalid-time proposal. The intended request was rerun using clipboard paste and passed. This input artifact is not counted as an application parsing failure.

Accessibility state and full-window captures were inspected for the saved task and review sheet, including scrolling to the time-confirmation controls. Native tool screenshots returned Stage Manager thumbnails; the screenshot helper supplied full-window captures. No visual obstruction or clipped required controls remained after scrolling. The regular app was reopened with the rebuilt binary and normal library after verification.

## Limits

No live provider request was made. The deterministic fixture proves tool dispatch, domain behavior, persistence and native state; it does not establish model wording or tool-choice compliance across providers. Notification authorization prompts, actual OS delivery, dark appearance, minimum-size layout, a full accessibility audit and macOS 15 runtime behavior were not requalified; no UI layout, localization catalog or platform notification code changed. Existing release gates remain separate.
