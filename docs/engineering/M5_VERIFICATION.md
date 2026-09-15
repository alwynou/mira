# M5 local engineering verification

Date: 2026-09-06. Branch: `dev`. This record separates independent engineering evidence from the remaining release gates. It does not mark the MVP released.

## Reference-scale measurements

Host: Apple M1 Pro (MacBookPro18,1), 10 CPU cores, 16 GiB RAM, macOS 26.6.2 (25G83), Xcode 26.6 / Swift 6.3.3, SQLite 3.51.0 with trigram FTS. The benchmark uses Release optimization, five warmups, and 30 retained samples per metric. There is no OS cache purge. The source fingerprint is recorded with the raw results so the measured implementation can be matched to its commit.

The fixed-seed fixture contains 10,000 memories, 100,000 messages across 1,000 conversations, 50,001 executions, and 50,000 parser-produced Markdown chunks across 20 imported files. The database is 1,296,535,552 bytes. Each chunk is 4,096 UTF-8 bytes; total original Markdown content is 204,800,000 bytes. Message bodies are 19–26 bytes and memory bodies 50–53 bytes. These are synthetic distribution measurements, not a worst-case long-conversation or human-reviewed retrieval evaluation. Content and memory/conversation identities are deterministic; source/chunk UUIDs are assigned by the production importer.

| Measurement | P95 | Target / interpretation |
|---|---:|---|
| Runtime-equivalent local reads, memory prefetch, and context build | 101.15 ms | 300 ms; includes conversation/workspace/message/execution/suppression reads and verifies memory inclusion |
| Selective English source lookup | 2.89 ms | 500 ms |
| CJK, mixed text, code/path, and literal source lookup | At most 200.58 ms | 500 ms; large hit sets return partial results |
| Indexed negative source lookup | 0.20 ms | 500 ms; empty and complete |
| Short CJK positive / negative lookup | 200.33 / 200.43 ms | 500 ms end to end; internal scan budget is 200 ms |
| Warm SQLite reopen proxy | 1.67 ms | Observation only; does not satisfy native cold-start acceptance |

All positive queries return six hits. Broad positive queries disclose truncation; the absent short query also discloses that its scan is incomplete. No search sample scans more than the 20,000-candidate bound. The 200 ms internal deadline excludes small adapter/return overhead, which remains included in the reported end-to-end sample. These measurements do not establish full-library recall for short queries or Q04–Q06 model quality.

Reproduce the opt-in run (ordinary CI skips it):

```sh
MIRA_RUN_M5_BENCHMARKS=1 \
MIRA_M5_REPORT_PATH=/private/tmp/mira-m5-scale.json \
swift test --package-path Packages/MiraKit -c release \
  --disable-automatic-resolution --filter M5PerformanceTests
```

The runner preserves samples, hit/truncation/scan observations, and operation failures in JSON before testing the thresholds. It then runs one full-scale backup/restore and writes a separate `.backup.json` record. A setup failure is reported by the test runner before timing starts; it is not treated as a measured sample. No model endpoint is called.

## Regression and scale recovery evidence

The complete package run passed 257 ordinary tests, with the opt-in scale test separately skipped in that command (258 registered tests / 33 suites); `/private/tmp/mira-m5-full-package.log`. The independent Release scale test passed in 457.04 seconds, including construction and backup verification; this total is not query latency. Host acceptance passed five localization XCTest cases plus eleven renderer/Keychain Swift Testing cases, and compiler-extracted coverage passed for all 963 bilingual entries (`/private/tmp/mira-m5-host.log`).

The 1,296,535,552-byte database exported in 91.83 seconds and restored in 111.81 seconds. Row counts, complete validation, original-backup immutability, and disabled automatic capture passed. These are single reliability observations rather than P95 backup timings. The combined small restore fixture and six direct file-I/O tests also passed. Host builds include concurrent worktree design resources; the final revision archive and exact CI establish repository-only delivery evidence.

Raw evidence: [measurements](evidence/m5-scale-v1/measurements.json), [scale backup](evidence/m5-scale-v1/backup.json), [source fingerprints and command](evidence/m5-scale-v1/provenance.json).

## Findings retained during acceptance

The initial benchmark setup had overlapping validity ranges; the fixture was corrected before measurements. The next complete fixture exposed a short-CJK failure: a source-first query plan sorted the large candidate rows before returning the first result and exhausted its deadline. The fix streams fallback chunks in rowid order and keeps scope, current-version, deletion, and disclosure filters before the candidate count. The regression inspects the production query plan and exercises local-only disclosure and historical/workspace exclusions. Indexed FTS plans remain unchanged.

Database backup I/O previously materialized up to 512 MiB and could block if a checked file was replaced with a FIFO before opening. It now hashes/copies in bounded buffers with nonblocking file opening, source/destination identity checks, exclusive creation, synchronization, and incomplete-copy cleanup. The measured 1.21 GiB reference database also establishes why the former 512 MiB limit was insufficient; the current limit is 2 GiB. Complete schema, integrity, typed relationship, and original chunk validation remain required.

The combined small restore fixture preserves two workspaces, global/candidate/forgotten memories, suppression records, multiple source versions, historical source and memory citations, original user text, and completed execution identities. It also checks that the original backup is unchanged and that the restored library starts with automatic capture disabled. File-I/O failure hooks are deterministic interruption evidence; they do not simulate actual power failure or physical disk exhaustion.

## Local delivery and remaining gates

The exact-revision packaging procedure is in [Local delivery](LOCAL_DELIVERY.md). A preliminary clean M4 Release from `aad66ce5ed64ae3e7b01bde89dcfc731f2e594bc` passed direct process startup, SIGTERM/reopen, schema validation, and two-directory isolation with synthetic data. These checks do not prove native interaction or graceful UI shutdown.

The final implementation revision is `5ee47a78c53f2c225309c8e8b3b104cc80fb048f`. All 42 measured source/dependency/benchmark fingerprints match that revision. Regenerating its isolated Git archive with XcodeGen produces an identical project file; the correction only removed a stale empty test group. That exact revision passed package tests, app/host tests, language policy, and compiler-extracted coverage in [CI 33984485447](https://github.com/alwynou/mira/actions/runs/33984485447).

The clean revision archive produced `Mira-0.1.0-5ee47a78c53f-unsigned.zip` (11,409,888 bytes), version 0.1.0/build 1, minimum macOS 15, with arm64 and x86_64 slices, English/Simplified Chinese resources, and third-party notices. ZIP SHA-256 is `5975e114ba5aba5ef2f093df4afacdb4439751d0e80d837b66ab4ff5f7047a6a`. The extracted bundle matches the built bundle's bytes, paths, modes, and symlink targets. The executable is ad hoc linker-signed, without a Developer ID identity or notarization. Parallel worktree icon/design changes were excluded from the revision archive.

The delivered ZIP passed direct process startup with a fresh isolated library, SIGTERM/reopen with a synthetic workspace preserved, a second empty library with no cross-directory data, and replacement with another extraction of the same revision. Removing both installed app copies preserved every file byte in the two libraries. All launches kept schema 7, passed SQLite integrity/foreign-key checks, and contained zero configured provider connections. Replacement at the same revision is not an old-version upgrade test; no native UI or graceful UI shutdown is inferred.

[Delivery evidence](evidence/m5-scale-v1/local-delivery.json) records the artifact, host, checks, and limitations. Local output is `.build/local-delivery-5ee47a7/`, including the ZIP, checksum, manifest, smoke report, toolchain, and build log. The artifact is available locally and has not been published as a GitHub release.

Native picker/citation/keyboard/VoiceOver/language-switching walkthroughs, cold UI startup, streaming-main-thread profiling, and cancel-feedback timing remain dependent on a functioning native automation service or attended environment. Real providers, attended Keychain faults, human-labeled Q04–Q06 data, seven-day use, minimum-system/additional-CPU native acceptance, Developer ID signing, and notarization remain deferred in the [execution ledger](MVP_EXECUTION.md).
