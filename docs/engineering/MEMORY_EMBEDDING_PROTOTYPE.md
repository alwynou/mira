# Native memory embedding prototype evidence

Date: 2026-09-16
Branch: `codex/memory-embedding-prototype`
Status: Prototype complete. Native local inference and retrieval are demonstrated; production integration and broad quality acceptance remain open.

Follow-up: the [expanded precision comparison](EMBEDDING_PRECISION_COMPARISON.md) supersedes the provisional checkpoint decision below and recommends 4-bit as the planned default based on labeled recall and resource measurements. This initial experiment and its failed numeric diagnostic remain unchanged as historical evidence.

## Decision

Qwen3-Embedding-0.6B through MLX Swift is viable for the next Mira implementation phase on the tested Apple Silicon host. Use the official BF16 checkpoint as the correctness baseline. Keep the community 4-bit checkpoint experimental: it passed retrieval and storage checks but failed the predeclared public-example numeric tolerance. Do not silently loosen that gate or promote it as a fully validated default.

The proposed exact SQLite/vector scan is sufficient for this 10,000-vector cost experiment. A dedicated vector database is not justified by these measurements. Equal-weight lexical/semantic rank fusion requires further design: it preserved Hit@6 here but reduced first-result accuracy. Large embedding batches can block a serialized inference service for seconds and must not be the foreground scheduling default.

See the [implementation plan](MEMORY_IMPLEMENTATION_PLAN.md), [prototype source and reproduction instructions](../../Prototypes/MemoryEmbedding/README.md), and [recorded measurements and query rankings](../../Prototypes/MemoryEmbedding/Results/2026-09-16.json).

## Environment and reproducibility

- Host: Apple M1 Pro, 16 GiB unified memory, macOS 26.6.2; Xcode 26.6 / Swift 6.3.3. This is not a macOS 15 runtime test.
- Native Release executable targeting macOS 15/arm64; Swift 6 complete concurrency checking. Metal GPU selected explicitly.
- Dependencies: MLX Swift 0.31.4, MLX Swift LM 3.31.4, Swift Transformers 1.3.0, and locked transitive dependencies in the prototype's shared `Package.resolved`.
- Fixed model revisions and verified artifact hashes are specified in the downloader and recorded results. Model files stay under ignored `.build/memory-embedding/models/`.
- The original build failed because Xcode lacked its Metal Toolchain. The official `xcodebuild -downloadComponent MetalToolchain` installation completed; the native Release build then passed.
- The first 4-bit download failed integrity validation and was discarded. The retry passed all declared file hashes; inference used only verified files.
- Normalization was corrected during the experiment: pooling in BF16 produced vector-length errors up to about 0.00344. Normalizing materialized Float32 vectors reduced maximum error to `1.19e-7` for both checkpoints. All reported final quality and performance figures below use this correction.

Reproduce the main experiment from the repository root:

```sh
python3 Prototypes/MemoryEmbedding/run.py
```

It builds, runs both checkpoints, records all results, and exits nonzero for the known 4-bit reference-score failure. `--model bf16` runs the passing baseline alone. The failure is an experiment result, not an interrupted or incomplete run. No paid endpoint or DeepSeek key is needed.

## Correctness and policy checks

BF16 passed **16/16** checks; 4-bit passed **15/16**, with only `publicReferenceApproximation` failing.

Both passed:

- Finite 1024-dimensional output and Float32 normalization.
- Unequal-length, right-padded batches agreeing with unpadded single inputs: minimum cosine 0.999841 for BF16 and 0.999725 for 4-bit, above the fixed 0.999 gate.
- Empty/overlong input rejection without silent truncation.
- SQLite close/reopen preserving the same vectors and selected records.
- Workspace, active lifecycle and disclosure filtering before semantic and lexical top-K; wrong model fingerprint excluded.
- Old revision exclusion, stale indexing-result rejection, current revision acceptance, deletion removing both retrieval paths, and late-result rejection after deletion.

These checks exercise the isolated prototype store. They do not verify the existing Mira production write path, source authority, privacy coordinator, crash recovery, or cache invalidation during concurrent requests.

### Public model-card reference

The four query/document cosine scores use the exact public Qwen example inputs. The fixed gate is maximum absolute deviation below 0.06; this is a permissive adapter smoke gate, not a general retrieval-quality standard. [Reference example](https://huggingface.co/Qwen/Qwen3-Embedding-0.6B#usage)

| Checkpoint | Maximum absolute deviation | Result |
| --- | ---: | --- |
| Official BF16 | 0.00214 | Pass |
| Community 4-bit DWQ | 0.06472 | Fail |

The BF16 agreement, batch consistency and shared pipeline indicate that quantization is the main source of the larger 4-bit deviation in this experiment. Cross-checkpoint document-vector cosine ranged down to 0.9416, averaging 0.9660. Nevertheless, their top semantic result agreed for all 32 authored queries. These observations warrant a larger held-out evaluation; they establish neither catastrophic quantization failure nor production-quality equivalence.

## Retrieval quality

The fixed diagnostic corpus contains 32 synthetic memories, 29 answerable queries and 3 no-answer probes. It includes Chinese paraphrases, cross-language questions, names, implicit constraints, excluded records and updates. The fixture SHA-256 is recorded with the results. The dataset was authored alongside the prototype and is not held out.

| Retrieval method | First-result hits | Hit@6 |
| --- | ---: | ---: |
| Prototype lexical baseline | 14/29 (48.3%) | 18/29 (62.1%) |
| Semantic, either checkpoint | 28/29 (96.6%) | 29/29 (100%) |
| Equal-weight reciprocal rank fusion, either checkpoint | 21/29 (72.4%) | 29/29 (100%) |

The lexical baseline uses Latin words/CJK bigrams with FTS5; it is not Mira's current production search or a profile-enhanced baseline. These gains cannot be reported as measured improvement over the current app.

Both semantic models put the breakfast preference ahead of the vegetarian constraint for the generic lunch question (`q02`), although the correct constraint remained in the first six. This is why recall ranking alone is not evidence that a reader model will apply the right constraint. A small profile and final context selection remain useful.

Equal-weight rank fusion gave weak lexical matches too much influence. Keep lexical recall for names and identifiers, but evaluate semantic-first or exact-match-aware ranking on held-out data before integration. Do not tune a weight on these same 29 queries and label the result general validation.

All three no-answer questions still returned nearest neighbors, with top scores about 0.29–0.36. They are excluded from the answerable Hit@K denominators. No abstention mechanism was validated; do not derive a production threshold from these three cases.

## Performance and resources

The final runs used already-downloaded files and warmed OS/shader caches. Process/model loading and first inference are single observations, not p95 estimates. Warm query timings include tokenization, GPU execution and vector materialization for 32 different inputs of 25–34 tokens including the instruction. They exclude ranking, extraction, queue contention and final context assembly.

| Measurement | 4-bit | BF16 |
| --- | ---: | ---: |
| Model/tokenizer load | 589 ms | 585 ms |
| First inference in final run | 66 ms | 65 ms |
| Warm query p50 | 43.1 ms | 46.1 ms |
| Warm query p95 | 47.7 ms | 52.2 ms |
| 10,000-vector scan p95, 50 samples | 2.39 ms | 1.88 ms |
| SQLite read/materialize 10,000 vectors, single observation | 23.0 ms | 25.9 ms |
| MLX active allocations after inference work | 335 MB | 1,192 MB |
| MLX peak active allocations, including largest batch | 1,324 MB | 2,091 MB |

The very first 4-bit inference before shader-cache warmup took about 2.05 seconds. Do not promise a 66 ms first-ever launch from the final warmed run. MLX cache was limited to 128 MiB; active/cache GPU allocations and process peak RSS are different measurements and must not be added together or called total application RAM.

The 10,000-vector database occupied 47,919,104 bytes including facts/FTS/metadata. Its vectors repeat the small corpus intentionally: this measures storage and scan cost, not retrieval quality at 10,000 semantically distinct memories. Scan timing includes scoring, full sort, and top-K from a preloaded array; SQLite loading is separate and does not demonstrate cold-disk latency.

### Batch cost

Median elapsed time per call, three observations per shape. Actual token counts were 129 and 513, including tokenizer boundary effects; target input lengths were 128 and 512.

| Batch shape | 4-bit | BF16 |
| --- | ---: | ---: |
| 1 × 129 tokens | 159 ms | 121 ms |
| 8 × 129 tokens | 827 ms | 530 ms |
| 16 × 129 tokens | 1,625 ms | 962 ms |
| 1 × 513 tokens | 472 ms | 292 ms |
| 8 × 513 tokens | 3,110 ms | 1,888 ms |
| 16 × 513 tokens | 6,160 ms | 3,634 ms |

The 4-bit checkpoint reduced model allocations substantially, but it was not uniformly faster. On this host BF16 won the longer-input/batched comparisons. A six-second non-preemptible indexing call would harm query responsiveness even though isolated query latency is low. Production scheduling should bound total tokens per indexing batch and prioritize queries between calls; validate query arrivals during indexing before claiming the 300 ms prefetch/context gate. This prototype does not measure Mira UI responsiveness or prove that gate.

## Offline execution

After downloading, both checkpoints passed native load and inference with process network access denied by macOS `sandbox-exec`:

```sh
/usr/bin/sandbox-exec -p '(version 1)(allow default)(deny network*)' \
  .build/memory-embedding/xcode/Build/Products/Release/MemoryEmbeddingPrototype \
  .build/memory-embedding/models/bf16 \
  Prototypes/MemoryEmbedding/Fixtures/recall.json \
  .build/memory-embedding/bf16-offline.json \
  .build/memory-embedding/temporary --smoke
```

The same check passed for `4bit`. The smoke path validates model load and a normalized vector; it does not override the 4-bit score failure. Network denial applies to these executable runs, not package/model downloads. DeepSeek extraction and final answering are outside this offline prototype.

## Evidence and remaining work

- Native Release build passed; the final added offline-smoke entry point also built and ran for both checkpoints.
- Final normal benchmark completed for both models. The combined runner intentionally returns failure for the 4-bit numeric gate and preserves its report.
- Language policy passed with 2,038 bilingual entries; Python scripts compiled; fixture IDs/expected targets, documentation links and patch whitespace were checked.
- Local raw logs and full vector reports: `.build/memory-embedding/`. Compact reviewable evidence is in the linked `Results/2026-09-16.json`; model weights, runtime databases and personal data are not tracked.
- The main Mira dependency graph, runtime library and production memory behavior were not changed by this prototype. Existing uncommitted tool-verification work was preserved on the new branch.

Next: update the owning memory product/architecture contracts, unify save/use policy, and implement coalesced extraction before integrating the platform adapter and vector jobs. Carry forward the ranking and batching findings. Larger held-out Chinese/English quality, robust abstention, production provenance/forgetting concurrency, cancellation/memory pressure, model-install UX and integrity recovery, macOS 15, final app packaging, and end-to-end answer/tool behavior remain open. No Q04/Q05/Q06 gate is closed by this prototype.
