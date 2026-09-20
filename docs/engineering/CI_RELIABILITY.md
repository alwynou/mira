# CI reliability

Date: 2026-09-20. Tracked in [issue #9](https://github.com/alwynou/mira/issues/9).

## Observed failure

The [main run on 2026-09-18](https://github.com/alwynou/mira/actions/runs/35352387444) reported package-test boundary timeouts, stopped making progress, and was canceled after approximately six hours. The [composer PR run](https://github.com/alwynou/mira/actions/runs/35485597693) and [provider PR run](https://github.com/alwynou/mira/actions/runs/35485920752) repeated the resolver and snapshot boundary timeouts. Those superseded runs were canceled during investigation to obtain their completed logs.

The package uses Swift Testing, which runs unrelated tests concurrently unless explicitly disabled. Several fixtures deliberately block synchronous model preparation or database callbacks while another task proves cancellation, close, or maintenance ordering. Running the entire set concurrently can starve the tasks needed to release those boundaries on the smaller hosted runner. Per-suite serialization does not isolate a suite from unrelated suites. See the [Swift Testing parallelization contract](https://docs.swift.org/latest/documentation/testing/parallelizationtrait).

## Change

The package CI command explicitly uses `--no-parallel`. No tests or assertions are removed: concurrent operations within each test still run and verify their original boundaries. Production code and normal focused-test commands are unchanged.

The package step has a 15-minute deadline, the app/host step has a 30-minute deadline, and the complete job has a 45-minute deadline. These workflow deadlines bound future stalls even when a blocked test cannot drain after cooperative cancellation. Existing console logs retain the started test and failure details.

## Verification

- Local baseline at `f4b595e`: 1,037 package tests in 148 suites passed with default parallelism in 11.707 seconds (test execution only).
- The same built tests with explicit `--no-parallel`: all 1,037 tests in 148 suites passed in 48.678 seconds.
- Catalog and script tests: 14 passed.
- Language policy: 2,162 bilingual entries passed.
- The complete app/host command and the pinned macOS 15 / Xcode 26.3 GitHub run must also pass before merging. Their final results are recorded on the fix PR; local package success alone does not establish hosted-runner success.

No user interface or runtime behavior changes are included, so native visual verification is not applicable.
