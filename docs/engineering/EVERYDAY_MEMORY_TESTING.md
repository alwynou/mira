# Everyday conversation and macOS automation

This workflow tests natural user behavior without telling the assistant to save, search, or recall memory. The authored corpus lives in [EverydayMemory](../../Tests/Fixtures/EverydayMemory/README.md): 32 synthetic cases, 16 per supported language, with 16 expected active captures and 16 cases that must not become active automatically. Labels express intended behavior independently of the current lexical gate. They are provisional authored labels, not a human-qualified Q04 benchmark.

## Three separate kinds of evidence

| Layer | Runner | What it establishes |
|---|---|---|
| Domain and integration | Swift Testing in MiraKit; hostless XCTest / Swift Testing | Transactions, permissions, source evidence, suppression, protocol boundaries, localization, and recovery with controlled inputs |
| Native interaction | XCTest with XCUIAutomation, target `MiraUITests`, scheme `MiraUI` | Actual macOS launch, input, send, cancellation, sidebar navigation, persistence after relaunch, and both display languages |
| Model behavior | Explicit opt-in `EverydayMemoryLiveTests` | The configured model's extraction and cross-conversation use of authored everyday statements; failures remain visible |

The offline demo provider in UI tests produces predetermined Markdown. Passing these tests does not establish intelligent capture or recall. Conversely, a live headless integration run does not establish clickability, layout, or accessibility.

## Native UI tests

Apple supports native UI automation on macOS through XCTest and XCUIAutomation. Keep `XCUIApplication` UI tests in XCTest; Swift Testing remains suitable for domain and integration tests. Use stable accessibility identifiers instead of translated labels or screen coordinates for navigation. Language-specific assertions can then independently verify visible translations. See Apple's [UI automation guidance](https://developer.apple.com/videos/play/wwdc2025/344/) and [Swift Testing introduction](https://developer.apple.com/videos/play/wwdc2024/10179/).

Run from a logged-in macOS desktop session:

```sh
xcodebuild -project Mira.xcodeproj -scheme MiraUI \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath .build/xcode \
  -onlyUsePackageVersionsFromResolvedFile -skipMacroValidation \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual test
```

Local ad hoc signing and disabling hardened runtime on the UI test target allow the native XCTest runner to load its test bundle. The application target retains hardened runtime. It does not sign a downloadable release with Developer ID. The standard hostless `Mira` test scheme retains its existing unsigned build procedure.

The native suite passes `--demo` and a unique temporary `--data-directory`, never the user's configured or default library. Language overrides use the process argument domain and do not change the saved display preference. Unicode fixture input is pasted through the actual composer, verified before sending, and previous clipboard representations are restored. Tests open a standard New Window when the macOS process has no restored window and use bounded state waits rather than fixed sleeps. Each test terminates the app and removes its own temporary library. `xcresult` contains UI screenshots and failures.

This suite requires a functional graphical session and macOS automation permissions. Keep the headless CI checks independent; run the `MiraUI` scheme on a suitable desktop runner. A runner bootstrap failure is an environment failure, not an application behavior pass.

## Live model evaluation

Live runs are disabled by default. Each selected case opens a fresh temporary library and uses the production runtime, memory application, extraction worker and HTTP adapter. The evaluator does not open the selected personal library or system Keychain. Its endpoint, provider, model, limits and secret are supplied explicitly through the environment; the credential reader keeps the secret in memory. Never put a real key in a command, fixture, report, issue or commit. A local launcher can forward an existing secret environment variable without printing it.

The ordinary `testOptInEverydayMemoryEvaluation` entry evaluates the 32-case single-statement corpus. The separate `testOptInStateEvolutionEvaluation` entry exercises sequential changes and writes a report after each case, including failures. These are two entries in the same evaluation harness, not independent transports. The state-evolution corpus also covers explicit saves; those scenarios intentionally ask the model to remember a synthetic statement, while automatic-capture scenarios use ordinary statements.

Provider setup must match the requested protocol. Reports must describe the actual provider/dialect and embedding mode. `MIRA_EVAL_EMBEDDINGS` defaults to `offline`; selecting `local` requires the production local model to become ready before model requests. Background extraction uses the production output limit derived from the frozen conversation route; there is no separate evaluation extraction-output setting. A run using offline embeddings measures the HTTP model and lexical recall path, not local semantic-vector quality. A run using the local model still does not establish broad retrieval quality from a few authored questions.

### State-evolution coverage

The versioned corpus in `Tests/Fixtures/EverydayMemory/state-evolution.json` covers:

- **Automatic enrichment** — establish a fact about an identified entity, then add a non-conflicting detail through ordinary conversation. Require one current representation retaining the supported details and both source identities.
- **Foreground enrichment** — explicitly save successive facts about the same entity through the production `memory.remember` tool. Inspect the foreground result before later background extraction can conceal a duplicate save.
- **Correction with replacement** — establish a durable preference, then explicitly replace it. The predecessor remains historical and cannot be an independent current memory or a normal follow-up context source.
- **Clear withdrawal without a replacement** — establish a source-linked current assertion, withdraw it without a new value, and require the same ID to be archived with retained history and separately tagged withdrawal evidence. Require no new assertion or successor. Close and reopen the library before the fresh-session follow-up and verify that no old memory reference enters ordinary context. The English and Chinese cases use explicit withdrawal intent; ambiguous, quoted and hypothetical classifications are exercised separately in focused offline tests.
- **Forget and reopen** — submit production `memory.forget` library maintenance for the exact current revision, close and reopen the same temporary library, then check the body-free record and fresh follow-up context.
- **Related but unanswered** — ask about an unstated preference sharing a topic with a saved fact. Inspect the actual answer for unsupported inference; retrieval overlap alone is not evidence for the missing fact.

Reports distinguish effective lifecycle from persisted review state: a record can have raw state `active` while being superseded or forgotten. Record exact IDs/revisions, source lineage, historical relationships, per-attempt context memory references, citation resolution, foreground/background usage and safe error codes. Preserve failed cases and partial evidence. Keyword observations are review aids; they do not establish semantic entailment, answer quality or citation correctness by themselves.

Automatic extraction keeps the production batching rules, including the 120-second idle trigger. A foreground answer is not proof that capture has completed. Wait for persisted extraction status and record a terminal empty result separately from timeout or failure. A successful foreground `memory.retract` creates a durable capture barrier for its source; when no extraction job exists, the evaluator records `suppressed_retraction_source` from the committed receipt and tagged source provenance, without claiming that a background job completed. The live evaluator must not shorten the production idle threshold or insert extra turns merely to make a case pass.

### Running a bounded sample

Build the normal `Mira` test scheme first. `TEST_RUNNER_` forwards configuration to the macOS XCTest process, which reads the unprefixed variable names. For state evolution, select IDs from the state corpus and supply a new absolute report path. Select an explicit request-authorization cap; this counts credential-read admissions before transport, not an exact count of completed HTTP requests. The cap is shared by all cases in that invocation. It is not a monetary budget or permission for repeated reruns.

The launcher supplies `TEST_RUNNER_MIRA_EVAL_API_KEY` in its process environment, without writing or displaying it. Other required settings are:

```text
TEST_RUNNER_MIRA_RUN_LIVE_MEMORY_STATE_EVAL=1
TEST_RUNNER_MIRA_EVAL_PROVIDER_ID=deepseek
TEST_RUNNER_MIRA_EVAL_ENDPOINT=https://api.deepseek.com
TEST_RUNNER_MIRA_EVAL_PROTOCOL=chat.completions
TEST_RUNNER_MIRA_EVAL_CONVERSATION_MODEL=<explicit model ID>
TEST_RUNNER_MIRA_EVAL_CONTEXT_WINDOW=<configured context limit>
TEST_RUNNER_MIRA_EVAL_CONVERSATION_OUTPUT=<bounded output limit>
TEST_RUNNER_MIRA_EVAL_EMBEDDINGS=local
TEST_RUNNER_MIRA_EVAL_CORPUS=<absolute path to state-evolution.json>
TEST_RUNNER_MIRA_EVAL_REPORT=<absolute path to a new JSON report>
TEST_RUNNER_MIRA_EVAL_CASE_IDS=<comma-separated selected IDs>
TEST_RUNNER_MIRA_EVAL_REQUEST_AUTHORIZATION_CAP=<explicit cap>
```

Then invoke only the selected live test:

```sh
xcodebuild -project Mira.xcodeproj -scheme Mira \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath .build/xcode \
  -onlyUsePackageVersionsFromResolvedFile \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:MiraHostTests/EverydayMemoryLiveTests/testOptInStateEvolutionEvaluation \
  test-without-building
```

Ordinary CI validates corpus selection and evaluator failure boundaries with synthetic inputs and skips both live entries. Human review of the saved synthetic answers and citations remains necessary. A small sample, or deterministic host assertions passing, does not close Q04–Q06: their larger labeled datasets, repeated runs and per-model quality thresholds remain defined in [Quality](QUALITY.md#quality-gates). Record the selected configuration, request cap and count, usage, failures and remaining gaps in an engineering evidence document for each authorized live evaluation.
