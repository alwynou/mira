# MarkdownView and ListViewKit decision benchmark

> This comparison preceded the user's decision to adopt MarkdownView + ListViewKit. The baseline source harness was removed with the old renderer dependencies. The measured results below remain historical; current implementation and validation are in [Renderer replacement](RENDERER_REPLACEMENT.md).

Date: 2026-09-09. Requested scope: measure a proposed renderer/list replacement before the user decides whether to adopt it. During that experiment, production Mira code, renderer dependencies, library data, and credentials were unchanged. This experiment does not reopen or close the existing production frame-hitch, interaction, or release gates.

## Results and decision implications

The combined prototype has a substantial advantage for retained long conversations. At 100 historical messages, its process CPU during streaming falls by **72.0%**, its sampled main-actor queue P95 by **68.4%**, and its peak RSS by **47.4%**. This supports considering both libraries for the long-history problem. It does **not** establish an across-the-board improvement: the isolated single-reply queue delay regresses, and virtualized scrolling has worse worst-case queue samples. The experiment itself did not apply a replacement.

### Primary: 100 historical messages, three runs

Values are the median of three per-run measurements except the explicitly labeled worst sample. Lower values are better. The same 20,933-byte response is submitted in 210 snapshots over approximately 21 seconds; history contains 36,063 bytes including synthetic user turns.

| Measurement | Current renderer + eager stack | MarkdownView + eager stack | MarkdownView + ListViewKit |
|---|---:|---:|---:|
| Streaming main-actor queue P95 | 64.77 ms | 25.47 ms | 20.48 ms |
| Streaming total process CPU | 22.56 s | 10.96 s | 6.31 s |
| Peak sampled process RSS | 328.05 MiB | 196.62 MiB | 172.45 MiB |
| Scrolling main-actor queue P95 | 23.87 ms | 18.71 ms | 10.26 ms |
| Scrolling total process CPU | 3.32 s | 2.51 s | 1.80 s |
| Worst scrolling queue sample across all three runs | 62.82 ms | 36.12 ms | 175.16 ms |

Streaming P95 ranges across repeats are 63.17–67.23 ms, 24.77–25.96 ms and 18.94–22.03 ms, respectively. Process CPU is stable across repeats (baseline 22.50–22.57 s; combined 6.31–6.34 s). These are a small local experiment, not population confidence intervals.

Swapping the Markdown leaf while retaining the eager stack accounts for a large part of the gain: about 51% lower streaming CPU and 61% lower queue P95 than the baseline. The native-list adapter then reduces CPU by a further 42% relative to that candidate. The list-stage increment includes lazy content preparation and row reuse, not just a container API swap.

### Supplemental: 500 historical messages, one run each

| Measurement | Current renderer + eager stack | MarkdownView + eager stack | MarkdownView + ListViewKit |
|---|---:|---:|---:|
| Streaming queue P95 | 363.64 ms | 102.74 ms | 21.89 ms |
| Streaming total CPU | 63.31 s | 21.25 s | 6.20 s |
| Streaming replay wall duration | 61.13 s | 21.08 s | 21.01 s |
| Peak sampled RSS | 777.23 MiB | 311.78 MiB | 171.64 MiB |

The old eager path cannot keep up with this replay: serving every main-actor submission stretches the nominal 21-second stream to 61.13 seconds, with roughly 40 seconds of maximum accumulated submission lateness. Both candidate paths finish their submissions in approximately 21 seconds. This is a presentation-backpressure result, not measured network latency. The combined candidate's low footprint and CPU remain nearly unchanged between 100 and 500 history messages; 500 is still a single exploratory sample, not an unlimited-history guarantee.

### Supplemental: no history and existing text fades

With no historical messages, the baseline/MarkdownView-stack/combined candidates use **9.67 / 6.51 / 6.21 CPU seconds**, respectively, but their streaming queue P95 values are **12.09 / 13.15 / 20.13 ms**. The combined candidate saves work and memory while producing a worse queue tail in this particular workload. Its synchronous main-actor preparation is a plausible reason, not a trace-confirmed diagnosis.

A single 100-history baseline run with its existing word fades enabled records **81.72 ms** streaming P95, **22.81 CPU seconds**, and **340.14 MiB** peak RSS. The main no-fade baseline already consumes 22.56 CPU seconds, so removing the fade does not explain the bulk of the combined candidate's CPU savings. The fade sensitivity sample is not a faithful full-app/smooth-follow comparison and should not replace the controlled primary baseline.

### Scrolling tradeoff

The combined candidate has lower scrolling queue P95 and total CPU in the primary fixture, but its worst sample is **175.16 ms**, versus **62.82 ms** for the current renderer and **36.12 ms** for MarkdownView in the eager stack. All three native-list repeats have a slow tail. This must remain an adoption concern; lower median/P95 cost is not proof that every scroll feels better. Recreating and preparing complex reused rows is a plausible explanation requiring a targeted trace before changing the integration. Different document heights also limit attribution of the traversal measurements, as described below.

## Question and experimental boundary

At measurement time, Mira used the vendored SwiftStreamingMarkdown with stable equatable rows in a bounded SwiftUI `ScrollView` and eager `VStack`. Eager retention avoids previously observed asynchronous Markdown height/placement loops but mounts historical rows. The proposed replacement combines a different text renderer with a virtualized AppKit list, so it changes two important costs.

The isolated benchmark contains three main configurations:

1. **Baseline:** vendored SwiftStreamingMarkdown with the existing eager list structure.
2. **MarkdownView + eager stack:** the same stack and row composition, replacing the Markdown leaf with the new library's public SwiftUI/AppKit adapter.
3. **MarkdownView + ListViewKit:** reused AppKit rows, real Markdown height measurement, cached prepared content, and targeted tail-item updates.

All main configurations disable text fades and use immediate bottom following. A separate baseline-fades sensitivity sample enables the existing renderer's word fades. None of these is the complete Mira window: the harness deliberately excludes thinking, citations, history tags, menus, provider/runtime/database work, and the production scroll spring. The baseline is the **current vendored renderer and container structure**, not a claim to reproduce every production presentation cost.

Library spacing changes total scroll range (about 57,246 points for the baseline versus 45,848/46,185 for the candidates at 100 history messages). Thus lower traversal CPU/queue delay is not a normalized per-distance scroll-speed claim. The third cell includes a new list adapter and lazy content preparation; the stack-to-list difference is not attributable solely to ListViewKit. An old-renderer/new-list fourth cell was not implemented, because measuring its asynchronously hosted SwiftUI height would require another integration whose correctness is outside this decision experiment.

## Versions and host

- Mira source at start: `6a45af4fa86ac4ea891c7ee5e2d103b36e6c311b`, branch `dev`.
- The measured vendored SwiftStreamingMarkdown and its transitive revisions exactly match the production renderer dependency states in the Xcode lockfile. No upstream-only baseline was substituted.
- [MarkdownView](https://github.com/Lakr233/MarkdownView/tree/757b6fcc4b3095e84f4c0613f4b98147f49dcd09): `757b6fcc4b3095e84f4c0613f4b98147f49dcd09`.
- [ListViewKit](https://github.com/Lakr233/ListViewKit/tree/c6a067ba837758a50612f88dd1d6bb025175df6c): `c6a067ba837758a50612f88dd1d6bb025175df6c`.
- Apple M1 Pro, 10 CPU cores, 16 GiB memory; macOS 26.6.2 (25G83), Swift 6.3.3, ARM64.
- Both executables are SwiftPM **Release** builds. Independent processes avoid shared caches and linking the unused renderer into baseline RSS. Candidate transitive versions and baseline versions are retained beside the harness.

## Workload and measurement

The primary fixture contains 100 historical messages (50 user/assistant pairs) and a 30-section mixed-Markdown streamed reply. It includes paragraphs, emphasis, links, lists, blockquotes, Swift code and three-column tables. It has a unique final rendered-text marker. Both renderers receive identical cumulative text snapshots in 100-character increments on fixed **100 ms absolute deadlines**. Every scheduled snapshot is submitted; overdue submission lateness is measured. The producer awaits each main-actor submission, so a blocked UI extends replay rather than dropping queued snapshots; this is a presentation backpressure experiment, not network throughput. Async renderers can cancel/coalesce superseded work, so submission count does not prove every intermediate snapshot was displayed.

The viewport is 760 x 600 points. Body and H2 sizes are matched at 17/24 pt; built-in block/line spacing, code styling, and Markdown semantics remain library-specific. The composer is updated separately every 100 ms. A six-second warmup precedes streaming; a two-second drain follows it; 120 scroll commands traverse the full document in both directions; and a two-second settled phase ends each run.

A detached 10 ms probe measures time until its main-actor request is serviced. This is a **queue-response proxy**, not FPS, frame duration, hardware input latency, or GPU presentation. One probe is outstanding at a time, so long stalls reduce sample density. CPU seconds cover the entire process and all threads, including the same sampling overhead. Peak RSS means the highest sampled resident memory over the run and is not a leak diagnosis. The queue percentiles use nearest rank; repeated-run aggregates use the median of each run's summary.

The initial primary suite rotated configuration order across three fresh processes per configuration. Native visual QA then identified a missing viewport clip in the experimental ListViewKit adapter. After adding explicit clipping, all five native-list measurements (three primary runs and both supplemental sizes) were discarded and rerun in a separate batch. The unchanged baseline/eager runs were retained. Final cross-configuration order is therefore not fully counterbalanced, and three runs are not a confidence-interval study. Supplemental 0-history, 500-history, and enabled-fade cases run once per configuration and are exploratory. No build, profiler, accessibility enumeration, or screenshot capture runs during accepted measurements. Native windows are floated to keep the measured viewport visible; visibility/activation are recorded. One native-list repeat became occluded during streaming and was rejected and replaced. Result acceptance requires complete final text and working full-range scroll commands. The runner also rejects occlusion during streaming/scrolling.

Early pilot samples used a sleep after each submission, which made synchronous adapters' stream durations longer. Those samples, the overlapping-build pilot, and the unclipped native-list results are excluded. Accepted runs use the absolute-deadline producer. Synchronous mount/submission timings are not used as rendering-latency comparisons: one API enqueues work while another performs some work within the call.

## Reproduction and evidence

The comparison used disposable standalone apps under `.build/renderer-comparison`, with locally ad-hoc signed wrappers and no real library or provider calls. Its old-renderer source harness was deleted after adoption. This report and the committed synthetic JSON preserve the accepted measurement evidence; the current native-app fixture is `scripts/run_rendering_benchmark.py`.

Detailed raw samples and logs are kept under ignored `.build/renderer-comparison/measured`. The [durable evidence](evidence/2026-09-09-renderer-comparison.json) includes compact per-run summaries with sample counts, percentile/max delays, CPU/wall duration, RSS, visibility, submission lateness and completion checks. Raw traces and environment dumps are not needed or committed.

## Adoption work not measured here

- Mira's exact 500 ms word fade/100 ms staggering, terminal/Reduce Motion behavior and 220 ms scroll-follow spring must be preserved or deliberately redesigned; the candidate does not provide Mira's fade behavior automatically.
- Reuse must preserve selection, reading anchors, user-interrupted following, jump-to-latest, source navigation, thinking expansion, code/table controls, localization and accessibility. Programmatic scrolling is not a trackpad-feel acceptance test.
- MarkdownView explicitly documents simplified CommonMark behavior, including complex blocks lifted out of lists and HTML/long-tail constructs rendered as plain text or simplified. Rendering compatibility needs representative transcript review before adoption. See its [README at the tested revision](https://github.com/Lakr233/MarkdownView/blob/757b6fcc4b3095e84f4c0613f4b98147f49dcd09/README.md).
- The public candidate adapters do parsing/preparation on the main actor in this harness. Their total CPU includes that work. More asynchronous preparation could be explored later, but no hypothetical optimization is counted here.
- Native list reuse bounds mounted row views, not all retained data. Prepared content is cached for history rows once visited/measured, and one exceptionally large response still has its own layout cost.
- Math, multilingual/CJK-heavy streams, minimum-width layouts, light/dark visual parity, hardware input, VoiceOver, cancellation/recovery/persistence and macOS 15 runtime behavior remain outside the quantitative acceptance here. These results cannot establish production feature parity or 60 FPS.

## Verification record

- Both standalone executables build in Release with Swift 6. The current app/project/package graph is unchanged; no `xcodegen` regeneration or production build is required for this isolated package experiment.
- All **16 accepted runs** completed **3,360 submitted snapshots** in total. Every run found the final rendered-text marker, executed 122 scroll commands including setup/final positioning, reached zero and the final maximum offset, and kept every streaming/scrolling probe visible. Rejected occluded, unclipped, overlapping-build and old-cadence samples are not in the durable evidence.
- An independent native light-appearance inspection of the clipped candidate confirmed visible headings, paragraphs, lists, blockquotes, highlighted code, complete tables, the final marker and a separate visible composer. A scroll interaction changed the native scroll position in the earlier diagnostic. This is a limited visual smoke check, not parity/trackpad/VoiceOver acceptance. Screen captures were observed through the native app tool; the harness's partial `cacheDisplay` bitmap was not accepted as screenshot evidence.
- Python compilation, `git diff --check`, and the language policy pass (1,138 bilingual strings). Production package/app/host tests were not rerun because no production behavior or build dependency was changed. Native benchmark builds and measured rendering checks are the relevant validation for the new harness.
- Rejected synthetic pilot artifacts were removed. Reproducible source/checkouts/build products and accepted raw measurements remain in the ignored benchmark scratch directory; no real library was accessed or removed.
