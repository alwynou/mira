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
| Remaining manual memory native walkthrough | Recovery of the native automation service, or an attended UI session | Deferred after repeated SkyComputerUseService crashes; manual creation/save was verified, remaining flows are recorded in Memory verification |

## Implementation defaults

- New source and prompts remain English; app-owned UI has English and Simplified Chinese resources.
- Schema and contracts change directly during early development. Older libraries are preserved and rejected rather than converted.
- Automatic memory starts disabled and requires explicit opt-in plus an extraction route and budget. This is an implementation default consistent with explicit background authorization; it does not claim real-model extraction quality.
- M3 extraction initially consumes committed conversation messages. Source extraction is introduced only with M4 source ownership and version checks.

## Current increment

Model-purpose configuration has passed deterministic package, host, native demo, and CI checks. Real endpoints and attended platform behavior remain deferred. M3–M5 are not yet accepted. No real endpoint calls, signing, or seven-day usage have been performed for this goal.

The routing increment passed 91 package tests, 16 host tests, Debug/Release builds, and 436-key language coverage. Native demo verification is in [Routing verification](ROUTING_VERIFICATION.md); The implementation commit `a5347317f26bf2b819eb1e74ee53346a72eee51d` also passed [CI 33964811120](https://github.com/alwynou/mira/actions/runs/33964811120). M3 manual memory is now in progress.

The manual memory increment includes local management, explicit remember approval, scoped recall, exact historical citations, competing replacement review, and transitive cleanup of derived execution history. Parent acceptance passed 142 package tests, 16 host tests, Debug/Release builds, and bilingual string coverage. Native creation/save passed; remaining native flows are deferred after automation service crashes. See [Memory verification](MEMORY_VERIFICATION.md). Automatic extraction and Markdown knowledge remain the next increments.
