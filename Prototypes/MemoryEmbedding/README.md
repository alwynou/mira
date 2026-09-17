# Memory embedding prototype

Isolated, native macOS command-line experiment for Qwen3-Embedding-0.6B and MLX Swift. It does not link into Mira, open the personal library, or call a paid API. The implementation plan is in [MEMORY_IMPLEMENTATION_PLAN.md](../../docs/engineering/MEMORY_IMPLEMENTATION_PLAN.md).

## Run

Requires Apple Silicon, Xcode with its Metal Toolchain, Python 3, and XcodeGen. If Xcode reports a missing `metal` tool, install the official component with `xcodebuild -downloadComponent MetalToolchain`.

From the repository root:

```sh
python3 Prototypes/MemoryEmbedding/run.py
```

The first run downloads about 1.53 GB of model weights plus small metadata/tokenizer files. Model IDs/revisions and file integrity checks are fixed in `download_models.py`. Package versions are pinned by `project.yml` and the project's shared `Package.resolved`. Downloads and builds need network access; the executable receives local directories and has no downloader or remote inference route.

Use `--model 4bit` for a smaller experiment. Use `--skip-download --skip-build` to rerun installed artifacts. Use `--summarize-only` to summarize completed reports. Files under `.build/memory-embedding/` include build/runtime logs, JSON results, downloaded manifests and models. They must not be committed. Temporary databases are unique per process and removed on successful or throwing Swift exit; abrupt process termination can leave only prototype files under that ignored directory.

## Scope and interpretation

- All input text is authored synthetic data. Chinese in `Fixtures/recall.json` is an intentional Unicode/search fixture exception; all executable diagnostics and prompts remain English.
- The 32-query corpus has 29 answerable queries and 3 no-answer probes. It is small and authored alongside the implementation, not a held-out quality benchmark. Retrieval results alone do not prove that an answering model uses memories correctly.
- The lexical baseline indexes Latin words and CJK bigrams through FTS5. It is not Mira's current production lexical search. Semantic and lexical candidates are filtered independently before rank fusion.
- Inference uses raw tokenization, right padding, last valid token pooling and Float32 L2 normalization; it does not apply layer normalization or a chat template. Norm error must be below 0.00001. Batch/single agreement is checked with cosine >= 0.999. Public model-card score approximation uses absolute error < 0.06 for both checkpoints; inspect the measured errors rather than treating that permissive smoke threshold as full numerical parity. The runner completes both checkpoints when a measured gate fails, writes the comparison, and returns nonzero; a failed checkpoint is not silently accepted.
- Vector blobs are native Float32 in this disposable Apple Silicon prototype. Production serialization requires an explicit byte format and generation-aware cache invalidation.
- Ten thousand repeated vectors exercise persistence/read/scan costs only. They do not simulate semantic diversity. The scan timing includes scoring, full sorting, and top-K selection on a preloaded array; SQLite loading is reported separately.
- Query latency includes tokenization, GPU execution and materialization. It excludes extraction, ranking and final context assembly. Model loading and first inference are separate single observations, with OS caches uncontrolled. Warm p95 uses 32 queries; batch timings have only three samples each.
- GPU allocations and process peak RSS are distinct metrics, not additive totals. Peak measurements include the largest batch and the scale experiment. The prototype limits MLX cache to 128 MiB; it does not measure app UI responsiveness or production cancellation.
- No-answer inputs still produce nearest neighbors. Do not interpret a score as proof that a relevant memory exists. Abstention and context admission need broader calibration.

The project is generated with `xcodegen generate --spec Prototypes/MemoryEmbedding/project.yml`. Keep that specification and generated project together. See the engineering evidence document for observed results and remaining integration gates.

## Expanded BF16 / 4-bit comparison

After regenerating and building the current prototype, run:

```sh
python3 Prototypes/MemoryEmbedding/compare_precision.py
```

This executes four processes with network access denied, in 4-bit/BF16/BF16/4-bit order. The fixed `Fixtures/precision-comparison.json` has 96 synthetic facts and 112 new queries, including eight multi-fact and eight no-answer questions. Its Chinese content is an intentional Unicode/search fixture exception. Each checkpoint has two runs; repeated queries do not count as additional independent quality examples.

The comparison preserves the earlier numerical diagnostic rather than redefining its gate. It adds labeled ranking/recall, immediate resident-memory measurements, cache clearing, and small background-batch-plus-query costs. Raw reports are under `.build/memory-embedding/precision/`; use `--summarize-only` to recalculate metrics. The checked-in [evidence](Results/precision-comparison-2026-09-16.json) and [selection report](../../docs/engineering/EMBEDDING_PRECISION_COMPARISON.md) explain the recommendation and limitations. The original runner still reports its known 4-bit score failure.
