# Continuous integration

The `Swift checks` workflow selects checks from the complete pull request diff. It runs for every PR, including documentation changes, and supports manual full verification through `workflow_dispatch`. It does not run again after every merge. New commits cancel superseded runs for the same PR.

## Check selection

`scripts/ci_plan.py` compares the event's base and head commits with a three-dot Git diff. Checkout fetches history so the merge base is available. Rename detection is disabled: both the removed and added paths contribute to the plan. Every commit in the PR is considered, rather than only the latest push. Mixed changes take the union of required checks.

| Changed input | Native checks | Lightweight checks |
| --- | --- | --- |
| `Apps/MiraMac/**` | App build, host and composition tests | Language policy; token consistency when `MiraTheme.swift` changes |
| `Packages/MiraKit/**` source, resources or tests | Package tests plus app/host tests | Language policy |
| Known macOS test/support directories | App/host tests | Language policy |
| Ordinary `scripts/**` changes | None | Script tests and language policy; token consistency for the exporter |
| `designs/mira-ui/tokens.json` | None | Token consistency |
| Recognized documentation/design artifacts and root READMEs, `LICENSE`, `AGENTS.md` | None | CI routing/result regression tests |
| Workflow/CI policy, Xcode project, package manifest/lock, vendored code, shared fixtures, or unknown paths | Both native suites | All lightweight checks |

All PRs run CI routing/result regression tests on Ubuntu 24.04. When script tests are selected, they include these regressions rather than running them twice. Source/catalog language checks run on Linux; compiler-extracted UI string checks still run after the macOS app build. The token check regenerates the export and fails if it differs from the committed JSON.

Missing or malformed event data, unreadable commits, invalid diff output, empty change lists and unknown paths request all checks. If the planner job itself fails or does not publish its outputs, native jobs are selected conservatively and the final result still fails. Paths are never interpolated into shell commands or copied into workflow outputs.

App-only changes keep the complete host/composition suite because views, presentation state and shared components are compiled into overlapping targets. A file called a view is not assumed to contain only visual behavior. This workflow still does not invoke the separate `MiraUI` scheme, live provider evaluations, opt-in real embedding tests or large-scale measurements. Native screenshots and interaction acceptance remain separate evidence.

## Native commands and final result

Package tests keep macOS 15 / Xcode 26.3, locked dependencies, `--no-parallel`, a 15-minute step deadline and a 20-minute job deadline. App/host tests keep macOS 26 / Xcode 26.6, the `Mira` Debug scheme, locked dependencies, `CODE_SIGNING_ALLOWED=NO`, a 30-minute step deadline and a 35-minute job deadline. The [reliability record](CI_RELIABILITY.md) explains why the serialization and deadlines must remain.

`CI result` runs after selection, lightweight checks and both native jobs, including when a dependency fails or is skipped. `scripts/ci_result.py` requires successful planning, valid selection outputs, successful lightweight checks and success from every selected native job. Missing results, failures, cancellation and unexpectedly skipped selected jobs fail. An unselected job may be skipped or may have completed successfully; a failure is never ignored. This stable result is the status to require when configuring branch rules. Existing branch protections are not rewritten by these workflows.

Manual **Swift checks** runs always select every check. They provide a full verification path without modifying a PR or using skip labels.

## Dependency caches

The shared `.github/actions/swift-dependencies` action caches only SwiftPM repositories, checkouts, downloaded artifacts and workspace resolution metadata. It uses separate package and Xcode workspaces. It does not cache app binaries, compiled modules, test results, runtime libraries, credentials or whole DerivedData directories. A cache hit never skips a selected build or test.

Keys include the workspace type, macOS major version, runner architecture, an `xcodebuild -version` fingerprint, and the manifests, lockfiles and project configuration. Restore requires an exact key; there is no fallback across dependency revisions or toolchains. The cache action records the hit/miss in the job summary and saves only after successful jobs.

GitHub scopes PR caches to their merge ref, so a cache from one PR cannot seed the next PR. **Warm Swift dependency caches** resolves pinned dependencies on `main` after dependency inputs or CI/cache configuration change. It performs no application build or test run. Unchanged source-only merges do not launch this workflow. It can also be dispatched manually to repopulate an evicted cache or seed a newly installed Xcode version. PR jobs can restore the caches created on their base branch. See [GitHub cache scope](https://docs.github.com/en/actions/reference/workflows-and-actions/dependency-caching#restrictions-for-accessing-a-cache).

Compilation caching is deferred until there is measured evidence that reuse is reliable and beneficial for these Swift/Xcode toolchains. Dependency caching reduces repeated downloads and checkout work; it does not claim to remove cold compilation. The prior icon PR spent 4m53s in the package job and 8m47s in the app/host job. Routing the same app-only diff skips the package job, saving roughly 36% of raw macOS runner minutes at that baseline, but the parallel app job still determines elapsed time.

## Verification

Tracked in [issue #32](https://github.com/alwynou/mira/issues/32). Focused regression coverage includes module routing, documentation-only and mixed changes, unknown paths, manual runs, event/diff failures, real multi-commit Git history with a rename and deletion, and missing/failed/cancelled/skipped job outcomes.

Local acceptance commands:

```sh
python3 -m unittest discover -s scripts/tests
python3 scripts/check_language_policy.py
python3 scripts/export_design_tokens.py
git diff --exit-code -- designs/mira-ui/tokens.json
git diff --check
```

All 34 Python tests passed locally. Replaying the actual icon PR #31 diff (`720f0cd...3883e9d`) through the event-based planner selected app/host, language and token checks, with package and ordinary script tests disabled. Language policy passed for 2,239 bilingual strings, and token regeneration left the committed export unchanged.

The workflow files are also checked with actionlint 1.7.12. This CI change selects the full hosted workflow before merge. Default-branch cache warming and restore outcomes are recorded on the linked implementation PR after merge; source-routing tests alone are not evidence of a hosted cache hit.
