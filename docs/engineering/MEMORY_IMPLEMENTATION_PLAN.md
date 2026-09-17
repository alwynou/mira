# Memory redesign implementation plan

Date: 2026-09-16
Status: Phase 0 prototype complete. Production 4-bit embedding, indexing, recall, automatic-capture and batched-extraction integration are implemented; [integration evidence and remaining acceptance](LOCAL_MEMORY_IMPLEMENTATION.md) distinguish delivered paths from deferred UI and quality gates.

## Target behavior

Memory forms without item-by-item confirmation. Explicit remember/correct/forget requests commit through the foreground service; ordinary conversation accumulates for bounded background extraction. Replies do not require visible citations; optional details can link to the source conversation. Background extraction/reconciliation uses the model actually used by the latest completed conversation turn in the batch, including DeepSeek when selected. There is no manual/automatic switch, separate extraction route, or daily extraction quota. Actual usage and cache counters remain recorded. Qwen3-Embedding-0.6B through MLX Swift supplies local semantic retrieval alongside lexical search and a small profile.

The source-based [embedding assessment](QWEN_MLX_EMBEDDING_EVALUATION.md) and [memory research](AGENT_MEMORY_RESEARCH.md) explain the design. Existing production contracts remain authoritative until the corresponding implementation phase updates them.

## Phases and acceptance

| Phase | Implementation | Exit evidence |
| --- | --- | --- |
| 0. Native prototype | Separate Xcode command-line target; pinned MLX/Tokenizer dependencies and model revisions; synthetic bilingual corpus; SQLite vectors, lexical baseline and hybrid ranking | Real GPU inference, finite normalized vectors, unequal-length batch consistency, checkpoint comparison, restart/persistence and scope/deletion checks, measured query/scan latency and memory |
| 1. Unified write/use policy | Update owning product and architecture documents; one policy for explicit and automatic saves; remove mandatory candidate approval and exact-quotation activation; keep internal session/range lineage | Save then recall in a fresh conversation; consistent scope/use treatment; forbidden-source and forgetting tests |
| 2. Background extraction | Durable dirty watermarks, bounded multi-turn windows, deterministic batch eligibility, frozen conversation route and per-request limits with reusable request prefix, shared reconciliation across save origins | No model request per ordinary turn by default; explicit actions prioritized; no lost delta, duplicate facts, or resurrection across restart/correction/forget |
| 3. Local model service | Platform-owned serial MLX adapter, pinned/downloadable model manifest, integrity checks, installation state, cancellation/drain and memory pressure handling | Native packaging, offline inference, download/load failures, foreground priority, supported-hardware behavior; Foundation-only core |
| 4. Hybrid recall | Commit index outbox with memory revision; asynchronously embed changed assertions; store versioned vectors; independent lexical/semantic channels and rank fusion; small profile | Current revision/scope filters before top-K and dispatch; lexical visibility during indexing; stale jobs rejected; no deleted or blocked content injected |
| 5. End-to-end validation | Wire production runtime, optional inspection/correction, bounded authorized episode fallback where needed | Existing quality gates with approved citation-policy updates, held-out model evaluation, native conversation workflows, resource and latency acceptance |

Implement directly against the new design; do not introduce old-schema bridges. Any actual schema replacement follows the standing authorization to recreate identified Mira development data. Phase 0 never opens the personal Mira library or uses credentials.

## Phase 0 scope and procedure

Create `codex/memory-embedding-prototype` from the current checkout, preserving the uncommitted tool-verification work. Keep prototype sources under `Prototypes/MemoryEmbedding/`; use its own generated Xcode project and dependency lock. Leave the main application/package dependency graphs unchanged.

1. Build a Release executable with Xcode so Metal resources are built and discoverable.
2. Download pinned public model artifacts to ignored build storage, validate their declared hashes, and load local files only during inference. Compare official BF16 and community 4-bit DWQ where supported.
3. Start with unpadded singleton inference; verify right-padded batches with explicit masks, last-token pooling and normalization. Include empty/overlong input rejection and mixed input lengths. Do not enable unrelated layer normalization or a chat template.
4. Use authored synthetic Chinese/English memory/query fixtures with fixed expected IDs, distractors and excluded records. Report top-1, Hit@6 and per-query results. Include no-answer observations without pretending cosine similarity alone supplies reliable abstention.
5. Persist vectors in an isolated SQLite file. Reopen it and verify identical retrieval, policy filters, replacement/deletion, fingerprint isolation and stale-write rejection. Use an exact scan as the initial vector path and a documented FTS baseline.
6. Measure cold process/model loading separately from first inference and warm inference, single/batched inputs, and a 10,000-vector scan. Report p50/p95, sample counts, token lengths and peak process/MLX memory. Synthetic repeated vectors establish scan cost, not large-corpus retrieval quality.
7. Record findings, failures and remaining gates in `MEMORY_EMBEDDING_PROTOTYPE.md`. Model/runtime compatibility is separate from complete memory-system acceptance.

The bilingual corpus is an explicitly documented Unicode/search fixture exception to the English-source policy. No paid inference, remote extraction, production memory mutation, UI redesign, or model auto-installation is included in this prototype.

## Proposed integration contracts

- Core ports use plain Sendable values; MLX arrays and GPU state remain in the macOS adapter.
- Canonical facts/revisions retain journal and transaction ownership. Vectors and profile references are rebuildable derivatives, never authorization authority.
- Index identity includes model revision/quantization, tokenizer/preprocessing/pooling, dimension and normalization. Query template/version is fixed and recorded.
- Index jobs carry expected fact revision and library generation; completion revalidates both. Deletion invalidates persisted rows, caches and queued/in-flight results.
- New facts remain available through lexical/recent-commit recall while indexing runs. Missing local models have a visible diagnostic state and a tested lexical/profile fallback.
- Scope, lifecycle, validity and destination policy are enforced before selection and again at dispatch. Local embedding grants no permission to send recalled text to DeepSeek.
- Extraction uses count/token/idle/age eligibility without a second model call for triage. Production threshold values are selected after measurement; the prototype does not claim to tune them.

## Decision rules after the prototype

Measured phase 0 outcome: BF16 passed all 16 prototype checks; the community 4-bit checkpoint passed 15 and failed the fixed public-example numeric tolerance. Both achieved 29/29 Hit@6 on the small authored corpus. The subsequent [expanded precision comparison](EMBEDDING_PRECISION_COMPARISON.md) recommends the pinned **4-bit checkpoint as the planned default**: all required facts were retrieved within six candidates for 104/104 answerable queries by both checkpoints, the 4-bit nDCG@6 loss was 0.76 percentage points, and its model allocation was about 857 MB smaller. Retain BF16 as the development correctness reference. The original numeric diagnostic failure remains recorded; it is not reclassified as a pass.

Equal-weight rank fusion reduced first-result accuracy, and large batches blocked inference for seconds; phase 3/4 must address scheduling and ranking explicitly. Start active-conversation indexing with at most four assertions and approximately 128 padded tokens per dispatch, then validate the complete foreground queue and context budget. Keep subject/time qualifiers and multiple candidates; the expanded comparison found several first-rank subject/context mistakes in 4-bit. The production integration now uses the pinned 4-bit checkpoint, semantic-primary retrieval with a lexical reserve, and one assertion per background GPU dispatch. The prototype measurements remain scoped to the prototype.

Adopt the 4-bit checkpoint only if its quality is acceptable against BF16 on the same fixtures and its packaged execution is correct. Compare hybrid recall with the lexical baseline; preserve exact-name retrieval. Use measured latency and memory to choose batching, residency and dimensions. If the existing 300 ms p95 prefetch/context budget is missed, report it and redesign scheduling or the retrieval budget rather than declaring acceptance.

The small prototype corpus is a smoke/diagnostic set, not Q04/Q05/Q06 acceptance. Complete extraction quality, implicit-use behavior, macOS 15 runtime, packaged-app lifecycle, and a held-out corpus remain later gates even when phase 0 succeeds.
