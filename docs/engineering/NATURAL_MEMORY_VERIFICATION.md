# Natural memory association and retained history

Date: 2026-09-06. Branch: `dev`.

## Result and contract

Ordinary messages enter the existing bounded memory prefetch path. Prompt and tool guidance now tell the assistant to apply relevant supplied facts naturally and use topic-focused `memory.search` only to fill gaps. Users do not need to request memory retrieval explicitly. This changes recall guidance, not automatic extraction settings or remote-use permission.

Committed conversation messages and visible assistant reasoning survive memory forgetting. Replies carry small localized tags derived from current memory lifecycle and execution provenance. Forgotten bodies and hidden tool exchanges remain unavailable. Superseded/expired entries no longer appear in the Active list; All retains historical entries with their effective status.

Retained display history is separate from eligible model history. Rebuilt requests exclude affected turns and transitive descendants after forgetting or lifecycle invalidation. The store rechecks provenance when preparing an attempt. Failed attempts do not contaminate the history of a subsequent successful retry. Forget still clears memory revisions/evidence, request/tool/audit bodies and active drafts, and blocks late writes and source re-extraction.

No database schema change, library reset, migration bridge, or recovery of already deleted replies was introduced. Knowledge-source deletion remains governed by its existing separate contract. Owning rules: [memory product behavior](../product/MEMORY_AND_KNOWLEDGE.md), [memory implementation](../architecture/MEMORY_IMPLEMENTATION.md), and [context](../architecture/CONTEXT.md).

## Deterministic checks

- `NaturalMemoryRecallTests`: ordinary reading-note task receives the authorized preference and exact revision; unrelated meal planning receives no memory. Real application/store with synthetic transport.
- `MemoryToolTests`: the remember receipt and acknowledgment agree with the committed local-only or reused remote-use policy.
- `MemoryDerivedHistoryTests`: memory captured after three replies already exist; forget preserves their text, derives transitive tags, purges audit bodies and omits old history from the next request. A post-forget backup restores retained history and suppression. A failed attempt followed by successful retry remains usable after forgetting the failed attempt's memory.
- `MemoryRememberApplicationTests`: committed save acknowledgment remains after forget; hidden tool messages and call payloads are removed, audits are purged, and the snapshot reports the forgotten status.
- `MemoryHistoryStatusTests`: updated, superseded, archived, expired and source-policy-unavailable notices; conversation isolation; active-list filtering.

Final local checks: 331 package tests in 37 suites passed, the Debug app built successfully, and the host suite passed five XCTest plus 59 Swift Testing cases. Language policy and compiler-extracted translations passed. The language check covers 1,170 bilingual catalog entries. The parent reviewed Luna contributions, corrected a SwiftUI opaque-return compile error, and strengthened the late-capture and retry fixtures. The retry regression failed before correcting both the user-message and successful-execution dependency lookup, then passed. Status traversal starts from actual memory usages, so conversations without memory usage do not traverse every history pair.

One final host run encountered the existing `TranscriptScrollAnimationTests.changingTargetsProducesIntermediateOffsetsWithoutReversing` timing assertion while package verification also ran. An idle `test-without-building` rerun passed the entire host suite. No renderer, animation or scroll implementation was changed; the timing variation remains recorded under the user-deferred streaming-performance work.

## Authorized live DeepSeek walkthrough

The existing user-configured development library and Keychain were used. All test mutations went through the visible native UI. CUA operated conversation surfaces; the previously authorized AppleScript/accessibility fallback operated memory details. Only a disposable fabricated reading-note preference was changed.

| Action | Observed result |
|---|---|
| Save a preference that reading-note action items use purple labels | Reviewed the proposed statement, approved its save, and received an acknowledgment explicitly saying it was local-only |
| Enable remote use for this test memory in the editor | Detail showed revision 2 and remote use allowed; the earlier save reply remained visible with an updated-memory tag |
| New conversation: “帮我设计一份读书笔记模板，包含行动项，100字以内。” | Without requesting memory search or supplying a color, DeepSeek produced a template with purple action labels and the correct revision-2 citation. Inspector showed one completed model attempt |
| Forget the fabricated memory through confirmation | Active list became empty; superseded entries from the earlier walkthrough did not reappear as Active |
| Reopen the template conversation | Original template and thinking disclosure remained. A “关联记忆已遗忘” tag appeared below the reply, and its citation became unavailable |
| Same conversation: “再给我一份更简洁的读书笔记模板，包含行动项，80字以内。” | New answer used an ordinary action-item field without the purple preference or a memory citation; original answer remained above it |
| Restart the final Debug app with the same configured library | Both answers, the forgotten-memory tag and the unavailable citation persisted; the app was left showing the retained original reply |

The fixture memory is now forgotten. The retained template conversation remains available for inspection. A local screenshot captured the original answer and its forgotten-memory tag; no conversation database, credentials, screenshot, or raw provider audit was committed.

This single-provider smoke check establishes the specific ordinary-input and retained-history behaviors above. Broad semantic-recall quality, other providers and macOS 15 runtime acceptance remain separate gates. Retrieval still uses bounded lexical prefetch plus model-directed tools; this increment does not add embeddings. Previously purged replies from the old implementation cannot be reconstructed.
