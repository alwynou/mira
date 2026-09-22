# Memory withdrawal near-miss verification

Issue: [#48](https://github.com/alwynou/mira/issues/48). Baseline: `c103de8`, after the clear withdrawal implementation in PR #47.

## Scope

The evaluator now checks that quoted, hypothetical and ambiguous messages do not mutate an established preference. The six authored scenarios cover all three categories in English and Simplified Chinese. They are provisional labels for bounded examples, not an independently labeled benchmark or a host natural-language authorization rule. Product behavior and production extraction/tool validation are unchanged.

Each case requires one source-linked current baseline. It compares the same ID, revision, body, lifecycle, supporting source identities, evidence counts and retained history immediately after the foreground reply, after production background extraction, and after closing/reopening the library. The final fresh-session request must contain the same current reference. Empty baselines, extra assertions, changed evidence and attempted memory writes cannot pass. Foreground and follow-up answers remain available for separate semantic review; keyword observations do not decide success.

The final English run from PR #47 exposed an evaluation gap: authorization-cap exhaustion retained its safe failure code but lost the available failed follow-up audit. Failure reports now retain the exact execution identity, phase, admission/completion outcomes, audit availability, known context references and per-attempt usage. A secondary audit-read failure cannot replace the primary error. Missing evidence and incomplete usage stay unknown. Historical reports are not rewritten.

Review of this increment's first live report exposed another evaluator defect: message pages are newest-first, but the existing reply helper reversed them and selected the first assistant message. Adding per-step answers made that old assumption visible: the second step was labeled with the initial preference acknowledgment. Reply lookup now binds both session and execution identity, rejects duplicate matches, and never substitutes an earlier reply for an absent current answer. An offline regression covers both page orders, missing/absent bodies, foreign sessions and duplicate matches. The initial reports retain this defect visibly; their step-answer text is not used to qualify the near-miss response.

## Offline verification

The final focused `MiraHostTests/EverydayMemoryLiveTests` selection built and passed on local macOS 27: 14 XCTest entries, 12 passed and the two opt-in live entries skipped, including the exact-reply-identity regression. Language policy passed with 2,245 bilingual strings; `git diff --check` passed. No package sources changed, so no unrelated local package suite was run.

Regressions cover mutation attempts without committed effects, changed identity/body/revision/evidence/history, missing established state, absent fresh-context references, partial usage after cap exhaustion, mismatched audit identity, and an unavailable audit after failed admission. Failure records contain safe codes and metadata, not raw provider/query errors. An execution checkpoint is cleared when its normal snapshot is retained, preventing a later reopen/report failure from attaching stale execution evidence.

No native layout or production runtime code changes are included. No personal library or Keychain is opened, and no development library reset is needed. The earlier macOS 27 native divider test limitation is not claimed fixed by this increment.

## Bounded live evidence

This task has a separate aggregate limit of 24 credential request authorizations across all runs. The launcher rejects report overwrites, unfinished preceding runs, and a proposed cap that exceeds the remaining allowance. Authorization counts are not exact transport dispatch or monetary counts. All content is synthetic; libraries are disposable.

Configuration: DeepSeek `deepseek-flash`, `chat.completions` / `deepseek.chat`, provider-default thinking, local Qwen embeddings, 1,000,000-token route context and an 8,192-token output ceiling. The production 120-second extraction idle trigger is retained, with observation up to 240 seconds. No filler turns or shortened timers are used.

| Run | Authorization cap / used | Settled conversation rounds / known extraction dispatches | Qualification |
| --- | --- | --- | --- |
| [Initial English quotation](evidence/memory-withdrawal-near-misses/english-quoted-initial.json) | 12 / 6 | 4 / 2 | All state checks passed; the second step's reply is misassociated and cannot qualify that response. |
| [Initial Chinese hypothetical](evidence/memory-withdrawal-near-misses/chinese-hypothetical-initial.json) | 12 / 5 | 3 / 2 | All state checks passed; the second step has the same reply-association defect. |
| [Final English quotation](evidence/memory-withdrawal-near-misses/english-quoted-final.json) | 8 / 5 | 3 / 2 | All four state checks passed on the corrected evaluator; exact replies reviewed below. |
| [Final Chinese hypothetical](evidence/memory-withdrawal-near-misses/chinese-hypothetical-final.json) | 8 / 6 | 4 / 2 | All four state checks passed on the corrected evaluator; exact replies reviewed below. |

The initial reports are unchanged. Their memory state, tool audit and fresh-session answer observations remain useful, but their second-step reply text is excluded from semantic qualification. The fresh-session answers in those reports have only one assistant message and are not affected by the page-order bug.

Agent semantic review of the final English sample confirms that the assistant translates the quoted line into French, explicitly treats it as script dialogue, and does not reinterpret it as a change to the user's preference. There are no foreground memory-write calls; the original ID/revision/body/source/history stay unchanged after background extraction and reopening. The fresh-session answer correctly identifies quiet cafés, supported by the exact original current memory reference. This is a bounded preservation sample, not a general translation or semantic accuracy claim.

Agent semantic review of the final Chinese sample confirms that the assistant recognizes the window-seat statement as hypothetical, explicitly retains the aisle-seat preference and offers to update it only if the user actually changes their mind. It makes no foreground memory-write call. The same ID/revision/body/supporting source remain current through background extraction and reopening, and the fresh-session answer correctly uses the aisle-seat preference with the original current reference. References listed in audit context do not imply a visible rendered citation.

The four runs used 22 of the 24 allowed authorizations. Their reports contain 14 settled conversation rounds and eight dispatched/completed extraction attempts, deduplicated by attempt identity; no incomplete usage is reported in these successful runs. These observations are recorded separately from credential admissions and are not an exact monetary bill. The remaining two authorizations were not used, and no run was omitted or overwritten. Live ambiguity cases, the Chinese quotation case and the English hypothetical case were not run; their corpus presence does not qualify model behavior.

## Remaining limits

These authored cases do not establish a general false-withdrawal rate, broad M3 quality, or an independent Q04–Q06 benchmark. Unrun categories/languages and incomplete follow-ups remain explicitly unqualified. The historical unclassified storage failure in [#43](https://github.com/alwynou/mira/issues/43) remains open unless a concrete failing boundary is observed; successful runs do not explain it.

Both Chinese baseline replies claim the preference has been noted for future use before the idle-triggered automatic capture, despite zero foreground memory-write calls. That likely premature acknowledgment is tracked separately in [#49](https://github.com/alwynou/mira/issues/49). It is not a database-write failure and this preservation evaluation does not qualify saved-state acknowledgment timing.
