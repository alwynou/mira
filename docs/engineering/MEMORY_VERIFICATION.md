# Manual memory verification

Historical evidence: the memory-forgetting behavior described below is superseded by [natural memory and retained-history verification](NATURAL_MEMORY_VERIFICATION.md). Current memory forgetting preserves committed visible replies with status tags and excludes them from future model context; source deletion remains a separate contract.

Date: 2026-09-05. Branch: `dev`. Status: deterministic package and build checks passed; remaining native checks are deferred after an automation service failure. This is not a full M3 or release acceptance.

## Implemented boundary

The manual increment adds reviewed memory creation, revisions and replacements, candidate decisions, archive/remove/forget, scoped local management, policy-filtered recall, and the `memory.search`, `memory.get`, and `memory.remember` tools. Host UI supports English and Simplified Chinese. The citation resolver verifies execution provenance and returns the exact historical revision. Tool saves use a separate host approval coordinator and remain local-only until the user changes disclosure settings.

Storage uses a fresh v5 library with memory, evidence, revisions, replacement decisions, source suppression, usage links, search, and execution history dependencies. Older development libraries are rejected intact; no compatibility migration or silent reset is included. The owning contract is [Memory implementation](../architecture/MEMORY_IMPLEMENTATION.md).

## Deterministic checks

The focused package tests exercise:

- Exact committed user evidence, stable manual entry identity, operation idempotency, and source suppression.
- Scope, lifecycle, validity, connection restrictions, and bounded search/context assembly.
- Concrete tool approval, denial, cancellation, and durable two-step request/tool exchange.
- Revision checks, competing successor review, and historical citation resolution beyond the management history limit.
- Forgetting during generation, tool capture cleanup, and cleanup of replies derived from earlier conversation history.
- Malformed backup rejection for retained evidence/revisions/search bodies, missing suppression, and individually retained step/tool/draft bodies under a purged execution.
- Valid historical usage after later edits, without weakening current-revision checks before live dispatch.

Parent independently ran 142 package tests across 18 suites successfully (`mira-memory-parent-acceptance-2.log`). Host testing passed five localization XCTest cases plus eleven Swift Testing cases for isolated Keychain behavior and the Markdown renderer. Debug and Release builds passed on macOS 26.6.2 / Apple Silicon with Xcode 26.6. Release compiled arm64 and x86_64; this does not establish Intel or macOS 15 runtime acceptance. Language policy and compiler-extracted coverage passed with 673 bilingual keys. Existing translation entries were preserved; obsolete new diagnostic keys were removed.

The earlier failed runs exposed real issues in memory hash updates, duplicated replacement payloads, Date serialization comparisons, and transitive cleanup. Those failures were fixed and the complete package suite was rerun. Parent review also added source workspace policy inheritance, exact citation provenance, and separate corruption cases for each audit child. Parsing alone was not treated as verification of delegated work.

Implementation commit `673e5458c3edf2ee53b463e7547461ec8a974cfc` passed [GitHub Actions 33970160801](https://github.com/alwynou/mira/actions/runs/33970160801) on macos-15 / Xcode 26.3. The exact run completed successfully, including package tests, app/host tests, language policy, and compiler-extracted UI coverage.

## Native interaction evidence

The Debug demo used a fresh disposable `/private/tmp/mira-memory-native-v5` library with no network requests. The native UI opened Memories, displayed the editor with separate scope/sensitivity/remote-use controls, saved a synthetic manual memory, and displayed it in the active list. This exposed a narrow navigation hit target; the Memories button now fills its row.

Further detail, replacement, citation, forgetting, and Chinese-screen walkthroughs could not be completed because `SkyComputerUseService` crashed with `EXC_BREAKPOINT` / `SIGTRAP` at 21:41–21:42 local time. Resetting the automation session did not restore it. The observed crash reports identify the automation service, not Mira. These walkthroughs and the final hit-target retest remain deferred; deterministic tests cover their underlying transactions and authorization boundaries. The demo library contains only the synthetic entry, and the app display language remains English.

## Remaining boundary

This document records the manual increment. The subsequent automatic extraction, persisted job, and budget implementation is tracked in [Automatic memory verification](AUTOMATIC_MEMORY_VERIFICATION.md). Markdown knowledge and complete M5 delivery remain subsequent increments. These synthetic fixtures do not establish actual model extraction quality. Human-reviewed Q04–Q06 evaluation, real endpoints, attended Keychain behavior, signing/notarization, additional platform runtime checks, and seven-day actual use remain recorded in [MVP execution](MVP_EXECUTION.md).
