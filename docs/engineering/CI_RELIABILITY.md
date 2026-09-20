# CI reliability

Date: 2026-09-20. Tracked in [issue #9](https://github.com/alwynou/mira/issues/9).

## Observed failure

The [main run on 2026-09-18](https://github.com/alwynou/mira/actions/runs/35352387444) reported package-test boundary timeouts, stopped making progress, and was canceled after approximately six hours. The [composer PR run](https://github.com/alwynou/mira/actions/runs/35485597693) and [provider PR run](https://github.com/alwynou/mira/actions/runs/35485920752) repeated the resolver and snapshot boundary timeouts. Those superseded runs were canceled during investigation to obtain their completed logs.

The package uses Swift Testing, which runs unrelated tests concurrently unless explicitly disabled. Several fixtures deliberately block synchronous model preparation or database callbacks while another task proves cancellation, close, or maintenance ordering. Running the entire set concurrently can starve the tasks needed to release those boundaries on the smaller hosted runner. Per-suite serialization does not isolate a suite from unrelated suites. See the [Swift Testing parallelization contract](https://docs.swift.org/latest/documentation/testing/parallelizationtrait).

Running the later compiler-extracted string check locally also found three missing catalog keys: `Chat Completions`, `Model Two`, and `Thinking budget tokens`. The plain source/catalog check had passed because these keys require compiler extraction.

The [first serialized CI run](https://github.com/alwynou/mira/actions/runs/35486434841) passed package tests, script tests, and language policy, then exposed an asset compiler crash: `AssetCatalogAgent-AssetRuntime` closed its connection while compiling `MiraAppIcon.icon` under macOS 15 / Xcode 26.3. The icon already has successful native build/render evidence on macOS 26.6.2 / Xcode 26.6 in [app icon verification](APP_ICON_DESIGN.md).

The [split-job run](https://github.com/alwynou/mira/actions/runs/35487028539) compiled the app successfully and exposed three host-fixture failures: a 150 ms native drag timer sampled before the drag was consumed, a conversation test exceeded its one-minute limit while streaming the 24-section rendering demo, and an extraction status test exceeded its polling bound while the demo adapter echoed the large extraction prompt character by character. These were previously hidden behind package and asset-build failures.

## Change

The package CI command explicitly uses `--no-parallel`. No tests or assertions are removed: concurrent operations within each test still run and verify their original boundaries. Production code and normal focused-test commands are unchanged.

The package step has a 15-minute deadline in a 20-minute job; the independent app/host step has a 30-minute deadline in a 35-minute job. These workflow deadlines bound future stalls even when a blocked test cannot drain after cooperative cancellation. Existing console logs retain the started test and failure details.

Package and script checks retain macOS 15 / Xcode 26.3. The app/host job uses macOS 26 / Xcode 26.6, whose installed path is confirmed by the [official runner image](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md). Both jobs must succeed; the canonical layered icon and the macOS 15 deployment target are unchanged. Native app runtime acceptance on macOS 15 remains a separate open check.

The missing catalog entries now include both supported languages. The protocol and synthetic model names remain verbatim in both languages; the thinking-budget field receives its missing Simplified Chinese label. No controls or layout change.

The native divider test waits for the initial drag to reach maximum width and the overshoot event to be consumed before asserting geometry while the mouse remains held. A ten-second watchdog still releases the synthetic mouse and fails the test if tracking does not progress. The original geometry and sidebar assertions remain.

Two composition tests now use a bounded synthetic model adapter instead of the deliberately slow rendering demo. Background extraction returns a valid empty version-3 result and the read-model test asserts completion. The conversation test pauses a short thinking/body stream with a one-shot continuation while switching pages, then releases it and verifies durable content and retained drafts. Entry uses the existing bounded polling helper; cancellation releases the gate and drains the producer. No production adapters or test time limits change.

## Verification

- Local baseline at `f4b595e`: 1,037 package tests in 148 suites passed with default parallelism in 11.707 seconds (test execution only).
- The same built tests with explicit `--no-parallel`: all 1,037 tests in 148 suites passed in 48.678 seconds.
- Catalog and script tests: 14 passed.
- Complete local app/host command: `TEST SUCCEEDED`, including Swift Testing summaries of 109 tests in 17 suites and 174 tests in 31 suites, plus the XCTest suites.
- Language policy including compiler-extracted strings: 2,165 bilingual entries passed after filling the missing catalog entries.
- Focused acceptance after the fixture changes: all 16 conversation/read-model tests and both native window tests passed together; the extraction job reaches `completed`. The generated project includes the new composition-only fixture.
- Host tests are rerun after the catalog change. Both pinned GitHub jobs must also pass before merging. Final results are recorded on the fix PR; local success alone does not establish hosted-runner success.

Native light/dark, minimum-size, and language-switch visual checks were not repeated for this catalog-only label correction. Test/build and compiler-extracted string coverage establish resource availability, not visual acceptance.
