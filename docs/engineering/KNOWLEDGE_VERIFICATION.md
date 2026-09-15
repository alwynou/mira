# Markdown knowledge verification

Date: 2026-09-06. Branch: `dev`. This record covers deterministic M4 engineering evidence, including the complete-file backup boundary needed to preserve imported material. It does not mark M3–M5 or the MVP released.

## Implemented boundary

Explicit Markdown selection produces immutable, locally managed snapshots with exact byte/line positions. Same-scope byte duplicates reuse records, matching names never overwrite, and explicit updates retain old versions. Failed parsing retains original bytes and preserves a previous successful version. Search covers English, Chinese, mixed text, code, paths, and literal operators, with scope/send filtering and explicit candidate/time truncation.

The three source tools provide search, bounded metadata inspection, and complete chunk reading. Citation resolution checks actual persisted chunk use and the exact historical version. Metadata-only opening does not authorize a body citation. Source usage follows derived conversation history; revocation/deletion clears dependent request, tool, output, draft, and assistant bodies and blocks late writes. Original user messages remain.

Fresh schema v7 includes complete directory backup bundles and owned staging. Restoration checks manifest hashes, exact schema/constraints, typed relationships, and chunk bytes against their original files before installing a separate directory. Automatic capture is disabled in the restored copy. There is no historical-format compatibility path.

File handling uses descriptor-relative operations, regular-file checks, verified aliases, anchor identity checks, bounded reads, file/directory synchronization, and a nonblocking maintenance lock across instances/processes. Cleanup retains all referenced historical versions, observes the seven-day grace for unreferenced blobs, and removes only recognized stale publication temps. POSIX advisory locking does not protect against malicious same-user replacement of the lock file.

## Local evidence

Environment: macOS 26.6.2, Apple Silicon, Xcode 26.6, Swift 6.3.3; deployment target macOS 15.

| Check | Result |
|---|---|
| Complete package suite | 249 tests / 30 suites passed; `/private/tmp/mira-knowledge-full-package.log` |
| Host tests | 5 localization XCTest cases and 11 Swift Testing cases across isolated Keychain and renderer suites passed; `/private/tmp/mira-knowledge-host-catalog-final.log` |
| Debug app | Built as part of the successful host test run |
| Release app | Build passed; `/private/tmp/mira-knowledge-release-catalog-final.log` |
| Localization | 962 bilingual strings; source policy and compiler-extracted Debug UI coverage passed; all 801 original entries preserved without semantic changes |
| Source/project consistency | XcodeGen regenerated the project; `git diff --check` passed |

Commit `4864711bc92cad56bec4c2fde1d091510885aa02` initially failed CI because a backup fixture used a machine-specific path and a lock test depended on a two-second scheduling window. The correction uses the system temporary directory, fixed fixture time, and nested independent lock descriptors. All 249 package tests passed again locally (`/private/tmp/mira-m4-portable-tests.log`). Commit `aad66ce5ed64ae3e7b01bde89dcfc731f2e594bc` passed [CI 33981574785](https://github.com/alwynou/mira/actions/runs/33981574785), including package, host, and extracted-language checks.

Concurrent icon/design work remains separate in the shared workspace. Exact-commit CI and the isolated git-archive Release build establish repository-only acceptance.

New focused coverage includes 8 parser tests, 5 tool tests, 5 application integration tests, 7 source store/search tests, 16 managed-file tests, and 7 backup tests. Existing backup corruption fixtures now mutate the bundle's database and reseal its test manifest, so typed/schema rejection remains independently exercised instead of being hidden by a checksum mismatch.

Parent review and retained failures led to fixes for metadata-only citation grants, invalid optional IDs, heading metadata amplification, UI selection/truncation handling, shared directory cursor state, parent/shard replacement, FIFO blocking, directory durability, temporary recovery, backup-source mutation, schema validation order, and live WAL handling, and untranslated diagnostics returned through a private error helper. The language scanner now covers that helper form. Focused agent checks were provisional; the complete parent runs establish the combined evidence above.

The integration provider uses synthetic source content and deterministic tool requests. It verifies that an instruction-like file passage remains tool data in the request envelope. This is engineering boundary evidence, not a real-model prompt-injection or retrieval-quality evaluation. Filesystem fault hooks exercise interruption boundaries; they do not simulate an actual power failure.

## Deferred and following acceptance

The native automation service remains unavailable after the previously recorded service crashes. The knowledge picker, long lists, source review/citation windows, deletion/cleanup, backup chooser, and live bilingual interaction need a functioning native service or attended session. Compilation and hostless tests do not substitute for that walkthrough.

M5 still owns fixed-seed scale/performance measurements and local artifact/install verification. Real endpoint checks, attended Keychain faults, human-labeled memory evaluation, seven-day use, macOS 15/additional CPU runtime, signing, and notarization remain deferred under the user's authorization. See [MVP execution ledger](MVP_EXECUTION.md).
