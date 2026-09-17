# Embedding precision selection

Date: 2026-09-16
Status: Expanded experiment complete. Recommend the pinned 4-bit checkpoint as Mira's planned default; retain BF16 as the development reference. Production integration remains pending.

## Decision

Select **Qwen3-Embedding-0.6B-4bit-DWQ** for the planned resident macOS embedding service. On the tested 16 GiB M1 Pro it saves about 857 MB of model allocations, while the fixed expanded corpus shows no loss of required facts in the first six results. BF16 has a small ranking advantage and is faster for indexing; retain it as the numerical reference, not a second automatically mixed runtime model.

This recommendation supersedes the initial prototype's provisional choice to leave 4-bit undecided. It does not erase that prototype's failed numeric-reference check or claim broad quality equivalence. The original score comparison is a useful diagnostic, but labeled retrieval is the relevant selection criterion. The loss in nDCG@6 was 0.76 percentage points, within the predeclared 2-point observed-set tolerance. There was no new missing-constraint pattern within the retrieval window; there were several first-rank subject/context confusions, recorded below.

The conclusion is an engineering tradeoff for Mira's small resident memory service, not a general recommendation for large-scale document indexing or all devices. The normal path selects multiple authorized candidates and reads their actual assertions; similarity and rank never establish truth or permission.

## Question and decision criteria

Choose the default Qwen3-Embedding-0.6B checkpoint for Mira on the current M1 Pro / 16 GiB target. Compare the pinned official BF16 artifact with the pinned community 4-bit DWQ artifact using the existing Swift/MLX pipeline. This compares these two artifacts, not every possible 4-bit quantizer or Apple device.

The earlier public-score approximation failure is retained as a numeric diagnostic. Its arbitrary 0.06 tolerance is not evidence by itself that useful memories are lost. Make the selection from labeled retrieval, resource use, and interactive work cost; do not change the original experiment's pass/fail result.

Before examining expanded outputs, use these engineering criteria:

- Prefer 4-bit for a resident personal assistant if its expanded Recall@6 and nDCG@6 are each within 2 percentage points of BF16, with no new repeated pattern of missing critical constraints, and its short-query p95 is within the existing local 300 ms budget. The 2-point rule is an observed-set tolerance, not a statistically established non-inferiority claim.
- Prefer BF16 if expanded recall/ranking meaningfully degrades, or if realistic small background batches impose an unacceptable cost relative to its memory saving. Inspect disagreements, not only aggregate means.
- Keep both vector dimension and stored vector precision fixed at 1024/Float32. Quantizing weights does not reduce the vector database payload.
- Evaluate the first retrieval rank, Recall@6 (including all labeled facts for multi-fact questions), MRR@6 and nDCG@6. Report equal-weight hybrid results separately without retuning fusion or the query instruction.
- No-answer cases are diagnostic only. No production similarity cutoff is inferred from this small authored set.

## Protocol

Author a new bilingual corpus with near-neighbor facts: different people, times, projects, amounts, directions of updates, exact identifiers and multi-fact constraints. Freeze fixture bytes and expected IDs before running either checkpoint. This set is new to the fixed pipeline but still authored by the implementer; it is not an independent external benchmark.

Run four fresh processes in counterbalanced order: 4-bit, BF16, BF16, 4-bit. Each process loads only one checkpoint, indexes identical eligible facts, and performs all queries with one fixed instruction and deterministic traversal order. Run without network access. Repeated runs assess latency and output stability; they do not multiply the number of independent quality questions.

Measure model load, first inference, warm queries, document indexing, small indexing batches and the subsequent query's elapsed time when serialized behind that batch. Record memory immediately after normal query work separately from larger workload peaks. Clear MLX allocator cache and measure what remains resident. Do not force system memory pressure, claim an energy result without energy measurements, or treat warmed file caches as cold disk.

Preserve raw reports under ignored build storage, record compact source-controlled evidence, and report remaining native-app lifecycle and macOS 15 gaps. The production Mira library and model settings remain untouched.

## Completed runs

- New fixed corpus: **96 memories, 112 queries**, including 104 answerable queries, 8 of which need two distinct facts, and 8 no-answer probes. It covers 16 topic groups and near neighbors involving people, time, projects, amounts and identifiers.
- Fixture SHA-256: `4374f75670d286edd826918e8896a0691067b7780489513f2ff4acbe06b13fb4`.
- Four successful native Release processes, in the declared `4bit → BF16 → BF16 → 4bit` order, each with network access denied. No model or ranking parameters changed after fixture creation.
- Both checkpoints produced exactly the same top-six ordering in their respective repeated runs. Quality denominators remain 104, not 208; latency has 224 observations per model.
- Host: M1 Pro, 16 GiB, macOS 26.6.2, Xcode 26.6 / Swift 6.3.3. Dependencies and artifact revisions match the initial prototype.

Reproduction after the existing prototype build/download steps:

```sh
xcodegen generate --spec Prototypes/MemoryEmbedding/project.yml
xcodebuild -project Prototypes/MemoryEmbedding/MemoryEmbeddingPrototype.xcodeproj \
  -scheme MemoryEmbeddingPrototype -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/memory-embedding/xcode \
  -onlyUsePackageVersionsFromResolvedFile CODE_SIGNING_ALLOWED=NO build
python3 Prototypes/MemoryEmbedding/compare_precision.py
```

See the [frozen corpus](../../Prototypes/MemoryEmbedding/Fixtures/precision-comparison.json), [runner](../../Prototypes/MemoryEmbedding/compare_precision.py), and [recorded evidence](../../Prototypes/MemoryEmbedding/Results/precision-comparison-2026-09-16.json). Complete per-run outputs remain in ignored `.build/memory-embedding/precision/`. Chinese in the corpus is an explicitly documented synthetic Unicode/search fixture exception.

## Measured quality

| Semantic retrieval metric | 4-bit | BF16 |
| --- | ---: | ---: |
| Correct first result | 93/104 (89.4%) | 95/104 (91.3%) |
| At least one expected fact in top six | 104/104 | 104/104 |
| All expected facts in top six | 104/104 | 104/104 |
| Mean Recall@6 | 100% | 100% |
| MRR@6 | 0.9439 | 0.9551 |
| nDCG@6 | 0.9577 | 0.9653 |

Recall@6 counts each required fact for a multi-fact question. MRR measures how early the first correct result appears; nDCG also rewards retrieving all relevant items near the front. Equal-weight hybrid first-result hits were 89/104 and 91/104 respectively, with all required facts still in the first six. The prototype lexical baseline found all expected facts for 84/104 queries. This does not compare against Mira's existing production lexical/profile path.

### Inspecting the differences

Among six labeled-rank disagreements:

- `food-q4`: 4-bit ranked a colleague's nut restriction before the user's restriction; the correct fact was second. BF16 put the user's fact first.
- `hardware-q0`: 4-bit preferred the travel laptop before the main development laptop; the correct configuration was second. BF16 put the main laptop first.
- `budget-q3`: 4-bit preferred the user's chair budget before the partner's budget; the correct budget was second. BF16 put the partner's budget first.
- `display-q5`: both put a nearby presentation constraint first; the target was third for 4-bit and second for BF16.
- `language-q5`: 4-bit put the requested explanation-language preference first; BF16 put it second behind UI-language support.
- `multi-7`: both retrieved the automatic-capture policy first; the separate extraction-frequency rule was second for 4-bit and third for BF16.

Thus quantization does affect ranking; it is not numerically free. For the planned six-candidate recall window, no extra labeled fact was lost. Preserve these cases as regression fixtures. Do not reduce the window to a single result or discard subject/time qualifiers merely because the highest score looks convincing. A complete answering-model evaluation is still needed to establish that retrieved distinctions are correctly applied.

The paired Recall@6 differences are all zero; a bootstrap of these same questions consequently returns [0, 0]. This is a ceiling effect on a small authored set, not proof of equal population performance or a statistical non-inferiority certificate. The broader claim remains limited to observed behavior and the stated engineering tolerance.

### No-answer probes

The no-answer top scores ranged from 0.364 to 0.727 for 4-bit and 0.347 to 0.725 for BF16. Some exceed scores on answerable questions. For example, a query asking for an actual secret can strongly match a policy about where credentials are stored without the secret being present. Neither precision supplies a reliable universal similarity cutoff. Final context reading must distinguish a relevant topic from evidence that answers the question.

## Measured cost

All sizes below are decimal MB. Memory figures are scoped to the standalone prototype. Model allocations, allocator cache and OS process residency are separate views and must not be added as independent totals.

| Measurement | 4-bit | BF16 |
| --- | ---: | ---: |
| Weight download | 335 MB | 1,192 MB |
| Model allocations after normal work/cache clear | 335 MB | 1,192 MB |
| Prototype process resident memory after normal work, two runs | 472–481 MB | 1,305–1,328 MB |
| Peak active MLX allocations during normal indexing/queries | 562 MB | 1,575 MB |
| Warm query p50, 224 observations | 41.2 ms | 41.8 ms |
| Warm query p95, 224 observations | 62.7 ms | 49.0 ms |
| Embedding all 96 facts, two runs | 1.74–1.88 s | 1.38–1.44 s |

Queries contained 27–41 tokens including the instruction. They exclude queueing, database work and context assembly. The p95 difference is about 14 ms, small relative to the 300 ms local prefetch/context budget; this experiment does not close that end-to-end budget.

Clearing the 128 MiB MLX allocator cache reduced its reported cache bytes to zero but barely changed immediate OS resident memory. The loaded weights remain allocated. Do not promise that clearing cache alone frees the model footprint; model unloading and OS reclamation need a separate lifecycle test.

### Indexing while conversation is active

Each observation serially embeds a background batch and then embeds a query. The combined duration is a conservative service-time approximation for a query arriving when that batch begins. It is not a test of the production scheduler or actual concurrent GUI responsiveness. Each shape has five observations per run.

| Background batch followed by one query | 4-bit combined p95 across the two runs | BF16 combined p95 across the two runs |
| --- | ---: | ---: |
| 4 short facts, 10–14 tokens each | 117–125 ms | 97–100 ms |
| 8 short facts, 8–14 tokens each | 168–170 ms | 134–141 ms |
| 1 longer fact, 129 tokens | 185–186 ms | 150–155 ms |
| 2 longer facts, 129 tokens each | 296–298 ms | 217–221 ms |
| 4 longer facts, 129 tokens each | 472–489 ms | 337 ms |

BF16 is faster for sustained matrix work on this host. Weight quantization is not a guarantee of faster computation: the compressed operations have their own execution costs. This experiment did not profile kernels or measure energy, so it does not attribute the exact slowdown or claim better battery life for either version.

For the planned 4-bit service, start with at most four assertions and approximately 128 padded tokens per background dispatch during active conversation. Longer jobs should run in idle windows with foreground priority between dispatches. These are implementation starting bounds based on measured shapes; verify the full queue and context path before treating them as guaranteed response-time limits.

## What BF16 and 4-bit change

The official artifact stores BF16 tensors. The community artifact stores packed quantized weights plus BF16 scale/auxiliary tensors; its configuration uses four-bit groups of 64. Both run the same embedding architecture and emit the same 1024-dimensional representation. In this prototype both persist Float32 vectors, so each vector remains 4096 bytes regardless of checkpoint. The model-size reduction does not shrink the vector database.

BF16's advantages are less quantization error, the slightly better observed ranking, faster longer/batched work here, and a direct official reference artifact. Its costs are approximately 3.55 times the weight storage/model allocation and a larger resident process.

4-bit's advantages are about 72% less weight/model memory and a smaller download, with preserved observed Recall@6 and adequate short-query service time. Its costs are the small ranking loss, larger score drift, slower longer/batched indexing here, and the need to validate a community conversion. [Official model](https://huggingface.co/Qwen/Qwen3-Embedding-0.6B), [quantized artifact](https://huggingface.co/mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ), [MLX quantized layer contract](https://ml-explore.github.io/mlx/build/html/python/nn/_autosummary/mlx.nn.QuantizedLinear.html)

## Implementation consequences and limits

Use one pinned 4-bit artifact consistently for stored memories and queries, with Float32 normalization. Keep model identity in index fingerprints. Do not index with BF16 and query with 4-bit, or silently switch checkpoints under memory pressure; changing the checkpoint requires a distinct index generation and reevaluation. BF16 remains a development reference for adapter and quality regression.

Keep native memory lifecycle, exact scope/revision validation, lexical visibility during indexing, and calibrated context admission in the implementation plan. The current numerical-reference failure remains visible in the original prototype runner; production acceptance should use explicit adapter correctness plus product retrieval/answer metrics, not copy an arbitrary cross-precision cosine tolerance as its only quality rule.

This recommendation is for the tested M1 Pro/16 GiB target and the planned use case. We did not test an 8 GiB machine, induce memory pressure, measure energy, validate macOS 15, run the Mira GUI under load, or call DeepSeek to grade final answers. The set was frozen before evaluation and inference parameters were unchanged, but labels are not externally audited. No production Q04/Q05/Q06 gate is closed.
