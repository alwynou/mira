# Everyday memory baseline and native UI verification

Date: 2026-09-07 (Asia/Shanghai). Environment: local Apple Silicon macOS desktop, Xcode 26.6. Implementation changes in this increment add tests and stable accessibility identifiers; they do not change memory classification rules.

## Corpus and offline result

The [32-case corpus](../../Tests/Fixtures/EverydayMemory/README.md) contains independently authored everyday statements and fresh-conversation follow-ups, with no instructions to save or search memory. English and Simplified Chinese each have eight active-capture expectations and eight non-active expectations. These are provisional AI-authored labels, not human-qualified Q04 data.

The host-gate test supplies an optimistic proposal for every full statement: user preference, standard sensitivity, stable, high confidence, uninferred, exact source quote, and no validity dates. This intentionally isolates host triage from extraction-model behavior. The 16 negative cases also receive these optimistic flags, testing whether the host still refuses automatic activation.

- **2/16 positive cases accepted**: the two Saturday-errand preferences.
- **0/16 negative cases activated**.
- All 32 results are retained in [host-gate.json](evidence/everyday-memory-v1/host-gate.json), including the 14 missed positive cases.

The CI test asserts corpus shape and negative-case safety only. Its passing status is not a positive-recall acceptance result. The narrow whole-statement lexical gate excludes most natural routine phrasing in this set; improving that decision boundary is the next memory-quality task. Do not change expected labels merely to make the current gate pass.

## Bounded real-model result

The user requested limited paid testing. This run selected four cases and enforced a shared maximum of **12 provider dispatch attempts**, including tool continuations and background extraction. The configured `deepseek-v4-flash` route and existing Keychain credentials were used. The authorized environment-key fallback was not needed. No additional paid retry was performed.

| Case | Observed result | Assessment |
|---|---|---|
| `zh-saturday-errand-batching` | Exact statement became active; fresh follow-up prefetched one memory and returned one verified citation; answer used Saturday batching and free weekday evenings | Passed this scenario |
| `en-savory-breakfast` | Exact statement was extracted as a candidate; fresh follow-up had no active memory and asked again about sweet/savory preferences | Capture failed; consistent with host-gate baseline |
| `zh-hoarse-no-iced-drinks` | Extraction paused with `malformedStream`; follow-up was stopped by the dispatch cap | Incomplete; cannot count as a successful negative case |
| `en-partner-spicy-food` | Budget was exhausted before provider dispatch for this case | Not evaluated |

The raw [live-four.json](evidence/everyday-memory-v1/live-four.json) contains only authored synthetic case observations, generated replies, and non-secret model metadata. Its aggregate `casesMeasured` counts processed runner entries, including incomplete/budget-stopped entries; only the first two completed the full workflow. The opt-in XCTest ended with an expected failure to preserve the mismatch signal. The third case's raw extraction output was not retained, so its protocol/structured-output failure cannot be attributed more specifically from this report.

Each case used a new isolated library and the runner removed all four owned directories after shutdown. Provider credentials, the configured development library, and real conversation history were not modified. Historical model outputs in this evidence were generated for synthetic fixtures, not copied from user conversations.

## Native automation result

The new `MiraUITests` target and `MiraUI` scheme ran actual macOS UI automation with the offline demo provider:

- English input, send, completed reply, sidebar identity, terminate/relaunch, exact user-message persistence, and no automatic redispatch: **passed**.
- The same workflow with Chinese display labels and Unicode fixture input: **passed**.
- Cancel streaming, restore the send control, and enter another exact message: **passed**.

The first runner attempts exposed inherited hardened-runtime signing requirements and reliance on restored windows. The final UI test target uses local ad hoc signing without hardened runtime, while the application retains hardened runtime. The suite activates the app and uses its standard New Window command if no window is restored. Tests use accessibility identifiers and state waits; they do not depend on coordinates or modify model output expectations.

Local `xcresult` evidence:

- `Test-MiraUI-2026.09.07_01-40-00-+0800.xcresult`: cancellation case.
- `Test-MiraUI-2026.09.07_01-41-21-+0800.xcresult`: English and Chinese persistence cases.
- `Test-Mira-2026.09.07_01-54-16-+0800.xcresult`: offline baseline and host regression checks.

These results are in `.build/xcode/Logs/Test/`. Screenshots and UI failure diagnostics stay local because native captures can include unrelated desktop content. Reproduction commands and the separation of UI/model evidence are in [Everyday memory testing](EVERYDAY_MEMORY_TESTING.md).

## Final checks and remaining work

- Package suite: **340 tests passed in 37 suites**.
- Host suite: **65 passed**, including the new offline baseline; **one opt-in live test skipped** in the normal run.
- Native UI suite: **three cases passed** across the two final selected-test runs.
- Source and compiler-extracted language checks: **1,193 bilingual strings passed**.
- `git diff --check`: passed.

Next: improve natural-statement activation against the retained offline misses, add enough synthetic diagnostics to distinguish structured-output failures without another paid replay, and reserve future live calls for a small selection of changed boundaries. This increment does not close Q04–Q06, minimum-macOS runtime, seven-day use, or distribution gates.
