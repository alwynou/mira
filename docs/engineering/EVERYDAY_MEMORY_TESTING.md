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

Live runs are disabled by default and require explicit case selection and an existing configured conversation/extraction route. Each selected case uses a fresh temporary library; only provider configuration and credential references are reused. The runner reads credentials through Keychain and never serializes them. It does not read or seed real conversation history.

For each case, send the ordinary statement through the production runtime, wait for the reply and separate extraction, then send the follow-up in a new conversation. Capture is disabled before the follow-up to avoid charging for an unnecessary second extraction. Record active/candidate status, extraction outcome, actual memory references, and the synthetic response. Keyword observations help locate cases for review; they are not a semantic answer-quality judge. Preserve all failure cases and distinguish no capture, review-only capture, retrieval miss, and incorrect answer use.

The initial live sample is bounded to four selected cases and 12 provider request authorizations. It does not qualify the complete corpus, all model providers, Q04–Q06, or general memory quality. Broader runs require explicit selection and review; ordinary CI must never call a paid endpoint.

### State-evolution coverage

Single-statement cases are only the first layer of the memory evaluation. A release-quality run must also include versioned synthetic sequences that exercise memory state changes rather than evaluating isolated extraction labels:

- **correction with replacement** — establish a durable preference, then explicitly replace it; the old revision must not remain independently active and a fresh conversation must use the replacement;
- **correction without a stable replacement** — establish a durable fact, then narrow/retract it without asserting a new stable value; the runner must record review/unresolved behavior rather than silently creating a contradictory active fact;
- **forget and reopen** — establish a memory, perform the production forget operation, close and reopen the temporary library, then verify that the forgotten body is unavailable and is not injected into a fresh model request;
- **related but unanswered** — establish a memory whose topic overlaps a later question but does not answer it; the later request must not treat topical overlap as factual support.

These scenarios must use synthetic data and the same production extraction, revision, maintenance, recall, and HTTP model paths as the application. Reports should record the model/provider identifier, extraction decision, memory IDs and revisions, later-context inclusion/exclusion, terminal outcome, and reported token usage when available. Deterministic host-policy tests remain separate so a live-model classification failure is distinguishable from a storage or application-rule failure.

The current `EverydayMemoryLiveTests` runner already provides the opt-in provider boundary, fresh temporary library, request-authorization cap, extraction status, cross-conversation follow-up, citation verification, and incremental JSON report. Extend that runner for state-evolution cases rather than introducing a second evaluation transport or credential mechanism.

After building the normal `Mira` test scheme, run only the opt-in test. `TEST_RUNNER_` forwards these variables to the macOS XCTest process; the test itself reads their unprefixed names. Supply a new report path, outside the configured library:

```sh
env TEST_RUNNER_MIRA_RUN_LIVE_MEMORY_EVAL=1 \
  TEST_RUNNER_MIRA_EVAL_CONFIGURATION_DIRECTORY=/absolute/configured-library \
  TEST_RUNNER_MIRA_EVAL_CORPUS=/absolute/mira/Tests/Fixtures/EverydayMemory/scenarios.json \
  TEST_RUNNER_MIRA_EVAL_REPORT=/absolute/new-report.json \
  TEST_RUNNER_MIRA_EVAL_CASE_IDS=zh-saturday-errand-batching,en-savory-breakfast,zh-hoarse-no-iced-drinks,en-partner-spicy-food \
  xcodebuild -project Mira.xcodeproj -scheme Mira \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath .build/xcode \
  -onlyUsePackageVersionsFromResolvedFile -skipMacroValidation \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:MiraHostTests/EverydayMemoryLiveTests/testOptInEverydayMemoryEvaluation \
  test-without-building
```

The JSON is written after each case and retained even when the test ends with mismatches. Report keyword checks are descriptive only; a reviewer must compare the synthetic answer and citations with the authored scenario. A candidate when an active capture is expected remains a failed capture rather than being reclassified as success.
