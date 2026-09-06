# MVP execution ledger

Started: 2026-09-05. Branch: `dev`. This ledger tracks the active implementation goal; the MVP document owns scope and milestone gates.

## Delivery sequence

1. Model configuration: separate connections, descriptors, route presets, purpose bindings, and frozen execution snapshots. Verify scope precedence, capability checks, revocation, and backup round trips.
2. M3 manual memory: evidence, active/candidate states, revisions/replacement, forget/suppression, scoped retrieval, memory tools, and localized UI.
3. M3 automatic memory: explicit opt-in settings, bounded extraction jobs, validation/review, budgets, cancellation, idempotency, and restart behavior.
4. M4 knowledge: authorized Markdown snapshots, immutable versions/chunks, local multilingual search, tools, citations, and managed blobs.
5. M5 local acceptance: complete backup/restore fixtures, privacy and failure tests, native interaction checks, quality fixtures, and local build artifacts.

Each increment is reviewed, tested, documented in its owning files, committed to `dev`, and checked in CI before proceeding.

## User-dependent work deferred

The user explicitly authorizes recording and skipping work that needs their participation. These items do not block independent implementation:

| Item | Needed from user or external environment | Status |
|---|---|---|
| Real OpenAI-compatible and Anthropic endpoint acceptance | Chosen endpoints/model IDs and locally configured credentials; synthetic tests remain separate evidence | Deferred |
| Real Keychain denial/lock and credential lifecycle exercise | An attended platform session with disposable credentials | Deferred; isolated fixtures exist in `MiraHostTests`, while attended behavior remains pending |
| Signed and notarized public download | Developer signing identity and notarization credentials | Deferred; unsigned local build verification remains in scope |
| Human-reviewed Q04–Q06 datasets and actual model evaluation | User labeling/review and access to the selected model; the evaluation must use the agreed Q04–Q06 datasets | Deferred; agent-created synthetic fixtures are engineering evidence and do not satisfy the human labeling gate |
| Seven-day actual use and real-model memory quality | User participation and elapsed real usage | Deferred; deterministic synthetic evaluations remain engineering evidence only |
| macOS 15 native UI and additional CPU runtime acceptance | Matching machines or an available attended test environment | Deferred; CI compilation and hostless tests remain in scope |
| Default remote reuse of tool-captured memories | A separate user decision on disclosure defaults | Deferred; tool captures are local-only, and the Memory editor exposes an explicit remote-use choice |
| Remaining memory native walkthroughs | Recovery of the native automation service, or an attended UI session | Deferred after repeated SkyComputerUseService crashes; manual creation/save was verified, remaining manual and automatic flows are recorded in their verification documents |
| Knowledge and backup native walkthroughs | A functioning native automation service or attended UI session | Deferred under the same service failure; picker, citations, bilingual switching, deletion/cleanup, and bundle chooser require native evidence |
| Native performance and accessibility acceptance | A functioning native automation service or attended UI session | Deferred; cold UI startup, streaming main-thread profiling, cancel-feedback timing, keyboard navigation, and VoiceOver remain unverified. SQLite timings and process smoke checks do not satisfy these gates |

## Implementation defaults

- New source and prompts remain English; app-owned UI has English and Simplified Chinese resources.
- Schema and contracts change directly during early development. Older libraries are preserved and rejected rather than converted.
- Automatic memory starts disabled and requires explicit opt-in plus an extraction route and budget. This is an implementation default consistent with explicit background authorization; it does not claim real-model extraction quality.
- M3 extraction consumes committed conversation messages. Source-derived memory is optional and remains deferred until a separate increment with explicit source ownership and version checks; M4 delivers file retrieval and citations.

## Current increment

Model-purpose configuration has passed deterministic package, host, native demo, and CI checks. Real endpoints and attended platform behavior remain deferred. M3–M5 implementation and independent local checks are complete; their full milestone acceptance remains pending the deferred gates listed above. No real endpoint calls, Developer ID signing, or seven-day usage have been performed for this goal.

The routing increment passed 91 package tests, 16 host tests, Debug/Release builds, and 436-key language coverage. Native demo verification is in [Routing verification](ROUTING_VERIFICATION.md); The implementation commit `a5347317f26bf2b819eb1e74ee53346a72eee51d` also passed [CI 33964811120](https://github.com/alwynou/mira/actions/runs/33964811120). M3 manual memory was the following increment.

The manual memory increment includes local management, explicit remember approval, scoped recall, exact historical citations, competing replacement review, and transitive cleanup of derived execution history. Parent acceptance passed 142 package tests, 16 host tests, Debug/Release builds, and bilingual string coverage. Commit `673e5458c3edf2ee53b463e7547461ec8a974cfc` passed [CI 33970160801](https://github.com/alwynou/mira/actions/runs/33970160801). Native creation/save passed; remaining native flows are deferred after automation service crashes. See [Memory verification](MEMORY_VERIFICATION.md). Automatic extraction has passed local deterministic acceptance: 201 package tests, 16 host tests, Debug/Release builds, and 801 bilingual strings. It includes immutable opt-in policy, dedicated leased requests, candidate review, original reservation ceilings, exact settlement, and transitive forget protection. Commit `9fa7212b3700d0dc24b8763049941935e6a041d2` passed [CI 33977078523](https://github.com/alwynou/mira/actions/runs/33977078523). See [Automatic memory verification](AUTOMATIC_MEMORY_VERIFICATION.md). Markdown knowledge followed this increment.

M4 now includes immutable Markdown versions, bounded multilingual search, three source tools, verified citations, source disclosure/deletion, descriptor-relative managed files, cross-process maintenance exclusion, and complete bundle backup/restore. Parent acceptance passed 249 package tests, 16 host tests, Debug/Release builds, and 962-key bilingual/extracted coverage. After portable fixture corrections, commit `aad66ce5ed64ae3e7b01bde89dcfc731f2e594bc` passed [CI 33981574785](https://github.com/alwynou/mira/actions/runs/33981574785). See [Knowledge verification](KNOWLEDGE_VERIFICATION.md). M5 independent performance and local artifact checks have since passed; the full MVP remains unreleased.

M5 local regression passed 257 ordinary package tests plus a separately executed scale test, 16 host tests, and 963-key bilingual/extracted checks. The 10k/50k/100k fixture passed query targets and complete 1.21 GiB backup/restore. The clean exact-revision Release ZIP passed resource/checksum checks and isolated process installation, reopen, bundle replacement, and uninstall data-retention checks. Source fingerprints and delivery evidence are tracked in [M5 verification](M5_VERIFICATION.md).

The independent implementation goal is complete through M5 local development delivery. Implementation revision `5ee47a78c53f2c225309c8e8b3b104cc80fb048f` passed [CI 33984485447](https://github.com/alwynou/mira/actions/runs/33984485447); the final evidence commit changes documentation only. The remaining items in the deferred table require credentials, human review, actual usage, or an available platform environment. They remain release gates. No public binary release was created, and M6 tasks/reminders have not started.

## Provider onboarding follow-up

The user requested provider activation → per-provider model selection → model pool → final selection, referencing LobeHub. The native setup flow, enabled-state persistence, bounded model discovery, canonical model presets, and pool-based selectors are implemented on fresh schema v8. Current evidence is in [Provider pool verification](PROVIDER_POOL_VERIFICATION.md). This follow-up does not change the deferred real-model or release gates, and M6 remains unstarted.

Provider onboarding implementation commit `c5d9706864ec096aadaba60ac66052b8befa9ea4` passed [CI 34011674174](https://github.com/alwynou/mira/actions/runs/34011674174). Its clean Release ZIP passed checksum/resource checks and schema-v8 startup/reopen/isolation smoke checks. The final evidence commit is documentation only; the local ZIP is a development artifact without Developer ID signing or notarization.
