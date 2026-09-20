# CI reliability

Date: 2026-09-20. Tracked in [issue #9](https://github.com/alwynou/mira/issues/9).

## Observed failure

The [main run on 2026-09-18](https://github.com/alwynou/mira/actions/runs/35352387444) reported package-test boundary timeouts, stopped making progress, and was canceled after approximately six hours. The [composer PR run](https://github.com/alwynou/mira/actions/runs/35485597693) and [provider PR run](https://github.com/alwynou/mira/actions/runs/35485920752) repeated the resolver and snapshot boundary timeouts. Those superseded runs were canceled during investigation to obtain their completed logs.

The package uses Swift Testing, which runs unrelated tests concurrently unless explicitly disabled. Several fixtures deliberately block synchronous model preparation or database callbacks while another task proves cancellation, close, or maintenance ordering. Running the entire set concurrently can starve the tasks needed to release those boundaries on the smaller hosted runner. Per-suite serialization does not isolate a suite from unrelated suites. See the [Swift Testing parallelization contract](https://docs.swift.org/latest/documentation/testing/parallelizationtrait).

Running the later compiler-extracted string check locally also found three missing catalog keys: `Chat Completions`, `Model Two`, and `Thinking budget tokens`. The plain source/catalog check had passed because these keys require compiler extraction.

## Change

The package CI command explicitly uses `--no-parallel`. No tests or assertions are removed: concurrent operations within each test still run and verify their original boundaries. Production code and normal focused-test commands are unchanged.

The package step has a 15-minute deadline, the app/host step has a 30-minute deadline, and the complete job has a 45-minute deadline. These workflow deadlines bound future stalls even when a blocked test cannot drain after cooperative cancellation. Existing console logs retain the started test and failure details.

The missing catalog entries now include both supported languages. The protocol and synthetic model names remain verbatim in both languages; the thinking-budget field receives its missing Simplified Chinese label. No controls or layout change.

## Verification

- Local baseline at `f4b595e`: 1,037 package tests in 148 suites passed with default parallelism in 11.707 seconds (test execution only).
- The same built tests with explicit `--no-parallel`: all 1,037 tests in 148 suites passed in 48.678 seconds.
- Catalog and script tests: 14 passed.
- Complete local app/host command: `TEST SUCCEEDED`, including Swift Testing summaries of 109 tests in 17 suites and 174 tests in 31 suites, plus the XCTest suites.
- Language policy including compiler-extracted strings: 2,165 bilingual entries passed after filling the missing catalog entries.
- Host tests are rerun after the catalog change. The pinned macOS 15 / Xcode 26.3 GitHub run must also pass before merging. Final results are recorded on the fix PR; local success alone does not establish hosted-runner success.

Native light/dark, minimum-size, and language-switch visual checks were not repeated for this catalog-only label correction. Test/build and compiler-extracted string coverage establish resource availability, not visual acceptance.
