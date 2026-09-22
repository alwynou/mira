# Memory save acknowledgment verification

Issue: [#49](https://github.com/alwynou/mira/issues/49). Baseline: `d5e9416`, after the withdrawal near-miss evaluation in PR #50.

## Change and evidence boundary

An ordinary Chinese preference reply in the previous evaluation claimed the information had been noted for future use before background extraction committed it. The foreground audit had no `memory.remember` call. Existing tool instructions required a commit before acknowledging an explicit save, but the generic conversation instructions did not distinguish understanding an ordinary statement from durable storage or an open-ended future-use promise.

`ConversationInstructions.default` now owns that distinction for the macOS host and both memory evaluators. It permits natural acknowledgment and current-conversation use, requires the matching successful save result for a new persistence claim, and excludes pending, failed, denied, absent and unrelated prior results as confirmation. It preserves local-only policy and avoids promising guaranteed recall. The final guidance includes an ordinary preference example and counterexamples to future-use promises; changing “saved” to “understood” alone is insufficient. Built-in instructions remain English and responses follow the user's language.

This changes instructions, not the runtime's commit authority. `SessionToolObservation` supplies the settled status and result content; successful `memory.remember` results are backed by a durable business receipt. Ordinary statements still use asynchronous extraction. No forced write, idle-timer wait, output keyword filter, schema change, Keychain access or personal-library reset is introduced. Historical reports retain their original instructions and replies.

## Offline verification

- The selected package suites passed 32 tests: six acknowledgment workflow tests, 12 existing memory workflow tests and 14 extraction-worker tests. The acknowledgment suite includes two parameterized ordinary-language cases and two standard/sensitive save cases. Its final focused rerun passed all six tests.
- The hostless evaluator selection passed 12 tests and skipped its two opt-in live entries. A separate macOS composition test passed, verifying that `ConversationModel` defaults reach both the admitted plan and the recorded model request. The final Xcode test command also built the app.
- Language policy passed with 2,245 bilingual strings. Project generation and whitespace checks passed.

The scripted English/Chinese replies test verbatim output and evidence delivery, not model semantic compliance. Runtime tests inspect committed receipt/result identity, scope and remote-use policy, failed-commit rollback, suppressed-source denial, and an older receipt followed by an ordinary statement. The held-stream test covers an unsettled model tool call before settlement; it does not qualify an already dispatched business transaction with an indeterminate outcome. No new UI layout or macOS 15 native-runtime claim is made.

## Bounded model evidence

This task has an independent aggregate ceiling of eight credential request authorizations. The launcher reserves each run's cap, rejects overwritten reports and unfinished prior runs, and permits a later run only within the remaining allowance. Authorization counts are not exact transport or monetary counts. All content is synthetic and each run uses a disposable library, an in-memory credential reader and the production 120-second idle trigger.

Configuration: DeepSeek `deepseek-flash`, `chat.completions` / `deepseek.chat`, provider-default thinking, local Qwen embeddings, a 1,000,000-token context limit and an 8,192-token output ceiling. New state reports contain the actual shared conversation instructions.

The [initial Chinese sample](evidence/memory-save-acknowledgments/chinese-initial.json) used five authorizations and passed its four deterministic memory-preservation checks. It did **not** pass semantic acknowledgment review: its first reply replaced the earlier saved wording with an acknowledgment but still promised to prioritize aisle seats for later bookings. There was no foreground save. That failure motivated the explicit future-use counterexamples in the final instructions. The report's automated `completed` state records host checks, not semantic approval of the wording.

The [final Chinese sample](evidence/memory-save-acknowledgments/chinese-final.json) used the remaining three authorizations. Agent review of its exact first reply confirms that it only acknowledges the aisle-seat preference, without claiming a save or promising future use. There were zero foreground memory-write calls, followed by one successfully completed production background extraction and one source-linked active memory. This directly qualifies that bounded ordinary-acknowledgment sample, not a general semantic guarantee.

The rest of the final scenario is **not a full workflow pass**. Its second background extraction paused when the credential reader refused another authorization, and the fresh-session follow-up failed for the same reason. The report retains `background_extraction_not_completed`, the primary `request_authorization_cap_reached` code, and the failed follow-up's audit with `credentialMissing` and incomplete usage. The ordinary acknowledgment had already been captured before those later failures. No further run was started and the total remained eight of eight allowed authorizations.

Across both reports, five conversation attempts have complete usage and three extraction attempts completed. One additional extraction attempt is marked `dispatched` by the production job state but paused without another credential authorization; its reserved-token charge is not an observed provider bill. The failed follow-up has unknown/incomplete usage rather than zero usage. Counts are deduplicated by attempt ID, and the reports are retained unchanged. English live wording, successful explicit-save wording and failed/refused/local-only model wording remain unqualified by these live samples.

## Remaining limits

Model wording is not deterministically enforced by these instructions. Authored fixtures and bounded samples do not establish population-level reliability, broad M3 acceptance or Q04–Q06 quality. The unclassified historical storage failure in [#43](https://github.com/alwynou/mira/issues/43) remains separate and open. Failed/refused/local-only wording is covered by scripted offline evidence, not a live provider matrix.
