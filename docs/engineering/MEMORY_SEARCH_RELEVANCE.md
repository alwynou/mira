# Memory search relevance correction

Date: 2026-09-16
Branch: `codex/memory-embedding-prototype`

## Problem and change

`memory.search` forwarded the supplied query correctly, but the vector path ranked every eligible memory and returned top-K without any score floor. With three indexed memories and a six-result limit, even unrelated queries returned all three. The existing vector tests used identical query/document vectors and did not test an empty semantic result.

- Apply a 0.50 cosine floor in the pinned Qwen 4-bit memory-query space before top-K selection. Keep the existing scope, lifecycle, source, revision and disclosure filters.
- Preserve the independent lexical path, including when local inference is unavailable or all vector scores fall below the floor.
- Return no recall results for whitespace-only queries. The separate management-list API retains its empty-query listing behavior.
- Retain one additional qualified candidate to determine truncation correctly. Exactly K qualifying memories no longer imply an omitted result; fusion also records candidates it excludes.
- Both tool search and automatic topic recall use this shared store path. The automatic communication/language profile remains separately bounded; it is not part of the search tool's results.

No persistence schema, stored memory content, vector generation or embedding prompt changed. No development-library reset is required.

## Focused evidence

- Before the fix, `searchToolRejectsUnrelatedNeighborsInASmallLibrary` failed with seven assertions: two unrelated tool queries returned all three memories and sources, a literal query included unrelated vectors, an empty query listed the library, and exactly K hits incorrectly reported truncation. Evidence: `/tmp/mira-memory-search-before.log`.
- After the fix, **15 tests in three directly affected suites passed**: `MemoryVectorStoreTests`, `MemoryWorkflowTests`, and `MemoryModuleTests`. These cover actual tool prepare/execute with a query different from the user message, semantic paraphrases, literal fallback, model-unavailable fallback, source authorization, stale vectors, result limits and privacy filtering. Evidence: `/tmp/mira-memory-search-after.log`.
- One opt-in native test, `MemoryEmbeddingRuntimeTests.semanticRecallFiltersUnrelatedMemories()`, passed with the real pinned model, GPU inference, an isolated in-memory database and three synthetic pet memories. Three related queries retained their labeled memory; six unrelated queries returned zero. Labeled positive cosine scores were approximately **0.629, 0.662 and 0.731**; unrelated scores ranged from **0.091 to 0.315**. Evidence: `/tmp/mira-memory-search-native.log`.
- The native test requires `TEST_RUNNER_MIRA_TEST_EMBEDDING_MODEL_DIRECTORY` and uses already-verified local weights. No model endpoint, credential or personal library was used. An initial Xcode selector without the trailing `()` selected zero tests; only the subsequent one-test run counts as evidence.

## Limits

The 0.50 floor is an initial relevance safeguard for the current checkpoint and query instruction. These small synthetic fixtures are not comprehensive multilingual calibration. Related-but-unanswerable questions can still have high similarity; for example, a memory about a laptop model cannot establish its serial number. No claim of perfect relevance or answerability is made. The earlier precision experiment's no-answer cases remain open for broader evaluation.

UI screens, extraction/merge behavior, embedding precision and unrelated host suites were not retested for this change. The Debug application build passed (`/tmp/mira-memory-search-app.log`), `git diff --check` passed, and the updated Mira application was reopened using the existing development library.
