# Memory withdrawal verification

Issue: [#46](https://github.com/alwynou/mira/issues/46). This increment implements a clear withdrawal with no replacement value. It does not close general memory-quality acceptance or the unrelated unclassified storage failure in [#43](https://github.com/alwynou/mira/issues/43).

## Implemented behavior

The foreground `memory.retract` tool binds one current ID/revision and an exact current-user quote. Its atomic transaction archives the same memory, increments the revision and records separate withdrawal provenance. It creates no opposite assertion, successor or replacement relation. The original body, revisions and supporting evidence remain available in history. Its receipt reports the mutation without advertising an archived revision as a new fact or citation.

Automatic extraction uses strict version-4 output with separate assertion and withdrawal arrays. Automatic withdrawal requires a frozen current observed-user target, current extraction metadata, standard disclosure and current source authorization. Uncertain, quoted, hypothetical or inferred classifications cannot withdraw a target. A successful withdrawal causes ordinary assertion items from that batch to be skipped conservatively; the source boundary must not be used to establish a guessed replacement.

Capture barriers cover the original and withdrawal sources. Dirty rows are removed before batching, and pending or dispatched work revalidates the barrier before writing. The barrier is separate from privacy suppression, so unrelated existing facts sharing the original source remain usable. A fresh later user source remains eligible. Explicit manual reactivation still works; subsequent enrichment copies supporting evidence and excludes withdrawal evidence. Forgetting purges both evidence roles and affected receipts.

## Local verification

Environment: macOS 27.0. The app targets macOS 15; this local run is not a macOS 15 runtime test.

- Focused package selection: 69 Data tests and 51 Core tests passed. Coverage includes foreground tool completion, stale revision refusal, atomic receipt failure rollback, completed extraction replay, late dispatched results, dirty-source barriers, source-sharing isolation, manual restoration, inherited-evidence roles, forgotten bodies, archive validation and database reopening.
- `xcodegen generate` and the normal `Mira` app/host `build-for-testing` passed. Project generation produced no project-file delta.
- The full hostless target ran 30 XCTest cases (2 opt-in live entries skipped) plus 109 Swift Testing cases. One existing native window test failed at `MiraWindowShellTests.swift:141`: its synthetic divider event did not enter mouse tracking. The isolated retry failed the same assertion. No window implementation or window test was changed. All other host checks passed; the complete local target is not reported as green.
- The evaluator's offline checks require an established predecessor, exact archived ID/revision, unchanged supporting provenance, a distinct withdrawal source, no replacement, and exclusion from fresh-session context after reopening. Empty baseline and keyword-only outcomes cannot pass.
- Language policy passed with 2,245 bilingual entries. No UI layout was changed, so no new visual acceptance is claimed.

## Bounded model evidence

All messages are authored synthetic fixtures. The evaluator opens disposable libraries, uses the production runtime and HTTP adapter, and never opens the personal library or Keychain. Credentials remain in process environment/memory and are not included in these artifacts.

Configuration: DeepSeek `deepseek-flash`, `chat.completions` / `deepseek.chat`, local Qwen embeddings, 1,000,000-token route context and an 8,192-token conversation/extraction output ceiling. The evaluator does not disable provider-default thinking; the preserved usage includes reasoning tokens. Production batching retains the 120-second idle trigger; observation waits up to 240 seconds. The aggregate ceiling for this task is 24 request authorizations, including exploratory and final runs; authorizations are not exact billable HTTP counts.

The initial English sample used 8 authorizations and passed the established-memory, foreground withdrawal, reopening and fresh-session checks. It preceded the final receipt-shape tightening and inherited-evidence validation refinement, so its original report is retained separately as [initial English evidence](evidence/memory-retraction/english-initial.json).

| Sample | Request authorizations | Recorded settled conversation rounds / dispatched extraction attempts | Result |
| --- | ---: | --- | --- |
| [Initial English](evidence/memory-retraction/english-initial.json) | 8 | 7 / 1 | Established assertion, exact withdrawal, reopen and fresh-session answer passed; before the final refinements described above. |
| [Final Chinese](evidence/memory-retraction/chinese-final.json) | 8 | 7 / 1 | All four state checks passed on the final implementation; fresh context excluded the old assertion. |
| [Final English](evidence/memory-retraction/english-final.json) | 8 | 4 / 1 | Established assertion, exact withdrawal and reopen passed. Follow-up execution reached the authorization cap, so the final fresh-session answer is unqualified. |

The aggregate consumed all 24 allowed authorizations; no additional paid run was started. The final English report preserves `request_authorization_cap_reached` at `followup_status`, not a completed success. Its absent follow-up snapshot means the recorded five settled/dispatched rounds are a lower bound, not a complete HTTP accounting of all eight authorizations. No state mismatch was reported before the cap.

Semantic review of the completed initial English and final Chinese answers found no claim that the withdrawn preference was still current and no invented opposite preference. Both answers state that no preference was found and ask the user to supply one. That wording is reviewed as a statement about current recall, not evidence that retained history was erased. Keyword observations remain non-authoritative. Successful foreground withdrawals suppressed the source's background job (`suppressed_retraction_source`); that status is not counted as a completed extraction request.

## Development library reset

The strict extraction protocol changed from version 3 to version 4. Under the existing development-data authorization, the obsolete runtime contents of `/Users/alwyn/Library/Application Support/Mira` were removed while no Mira process was running, and the current Debug app recreated the library at that same path. Cleanup was limited to the identified business database, sessions, projections and knowledge directories; no backup or compatibility library was retained. Keychain credentials, shared embedding weights, source code and design assets were untouched.

Native startup showed an empty conversation list and the model-connection onboarding state. The new business database and session/projection stores were opened at the original path. Previous development conversations and model connection configuration are gone; model connections must be configured again. This startup check does not claim a new light/dark or window-size visual matrix.

## Remaining limits

The live samples measure clear authored withdrawals, not arbitrary natural-language accuracy. The final English fresh-session live answer remains unqualified after the budget cap; the earlier English success is retained with its implementation boundary. Classification near misses are covered with authored offline metadata, not a broad live ambiguity benchmark. Background withdrawal, race rejection and settlement replay have synthetic integration coverage; successful foreground samples do not establish a live background-withdrawal success rate. Archive validation and database reopen are covered, but this increment does not claim a new full backup/export/import acceptance run. The local native mouse-tracking failure and macOS 15 runtime coverage remain separate verification limits.
