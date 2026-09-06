# Long-conversation rendering verification

Date: 2026-09-06. Scope: retained history, live Markdown with visible fades, and automatic following. This is a local performance increment, not completion of the M5 release gates.

## Changes and rationale

Sampling the previous implementation showed repeated `NSHostingView` size-constraint negotiation measuring the growing transcript. The transcript now fills a finite viewport. Completed rows compare their immutable content before rebuilding headers, menus, and citations. Geometry-driven following is coalesced outside the current layout transaction.

History retains its existing continuous, eager layout. An explicit pagination experiment reduced mounted content but introduced source-navigation and page-layout regressions; it was removed. This change does not claim bounded memory for unlimited history. Product behavior remains owned by [Workspace and conversation](../product/WORKSPACE_AND_CONVERSATION.md); implementation boundaries are owned by [Platform and security](../architecture/PLATFORM_AND_SECURITY.md).

The renderer's existing 500 ms fades and 100 ms word staggering remain enabled. Automatic following now retargets an explicit bottom offset with a 220 ms non-bouncing spring, rather than repeatedly snapping a pinned edge. Initial/history placement and Reduce Motion remain immediate, and manual scrolling cancels pending follows. This increment does not shorten or remove the animation. Native retention tests verify stable prefix views and selection, finite resized/replaced layouts, and locale/animation environment propagation across equal content wrappers.

## Fixture and interpretation

Host: Apple M1 Pro, 10 CPU cores, 16 GiB RAM, macOS 26.6.2 (25G83). Both comparison runs use Debug (`-Onone`) with the same pinned renderer. The baseline is application behavior at `e48ab27`, with the opt-in synthetic presentation fixture added; the changed run includes this increment. User-owned icon/design changes remain outside the implementation commit.

The fixture installs 100 historical messages in presentation memory (34,773 bytes of assistant Markdown), streams a 20,911-byte reply in 50-character cumulative increments approximately every 100 ms, and supplies 1,760 bytes of thinking. The baseline leaves thinking collapsed; the changed run expands it. The full history remains in memory and is mounted in both runs. Expanded thinking adds visible work in the changed run; this comparison does not claim that each animation frame became proportionally cheaper.

A detached task timestamps requests for main-actor service every 100 ms. On service, it samples RSS and updates the unsent composer during streaming. It records at least 30 samples per phase and performs 30 native scroll commands. These are repeatable presentation checks, not hardware input measurements.

Main-actor service delay is a responsiveness proxy. It is not hardware keystroke latency, frame rate, or proof of the Instruments 100 ms gate. RSS includes allocator retention and does not diagnose leaks. These fixtures bypass provider and persistence; previous cancellation/recovery checks remain separate. Do not call paid endpoints in this benchmark.

Clean comparison runs exclude Instruments, builds, and accessibility-tree enumeration. Rejected pagination/navigation experiments and their diagnostic probes are not included in the implementation or accepted comparison.

## Results

Raw synthetic reports: [baseline](evidence/2026-09-06-rendering-baseline.json) and [final smooth following](evidence/2026-09-06-rendering-smooth.json). The baseline retains its original system-provided OS label verbatim. All samples in both reports recorded the fixture as active and visible.

| Measurement | Baseline | Final smooth following |
|---|---:|---:|
| Streaming service samples | 418 | 418 |
| Streaming P50 | 139.03 ms | 30.23 ms |
| Streaming P95 | 488.41 ms | 126.51 ms |
| Streaming maximum | 584.60 ms | 182.43 ms |
| Scrolling P95 | 11.03 ms | 14.30 ms |
| Scrolling maximum | 298.34 ms | 250.48 ms |
| Settled P95 | 0.157 ms | 0.138 ms |
| Peak sampled RSS | 468.50 MiB | 460.28 MiB |

Streaming P95 fell by about 74%. The final result includes visible scroll animation and expanded thinking. An intermediate version with immediate following measured 108.04 ms P95; the user reported its stepped movement, so it is not the final interaction. Memory is essentially unchanged in this single-run comparison. The 100 ms main-thread gate is **not accepted** from these results. Scrolling still has a 250 ms tail sample, and initial full-history layout remains expensive (1.57 seconds at the worst warmup probe). Warmup is not a repeated cold-start benchmark.

The pre-scroll-animation Time Profiler recording ran for 30.93 seconds and contained no `potential-hangs` intervals. AttributeGraph update/dirty propagation remained the dominant main-thread work. Its hitches lane was unavailable, so it does not establish frame-rate or the 100 ms gate; it is also not evidence for the later smooth-follow change. Final motion is independently covered by the native geometry tests below. A separate final SwiftUI recording reached its 30-second limit but remained CPU-bound in trace finalization for more than four minutes; it was cancelled and discarded. It provides no additional frame-hitch evidence.

## Verification and remaining gates

Local checks pass: 306 package tests in 34 suites; 5 XCTest localization cases plus 48 Swift Testing cases in the host target; 8 script tests; and 1,132 bilingual entries with extracted UI coverage. Debug and Release builds pass separately; the Release executable does not contain the benchmark entry flag. Two new native-window tests observe multiple intermediate scroll offsets, monotonic retargeting from 500 to 800 points, and immediate placement with animation disabled. Six additional tests cover scheduler cancellation/coalescing and native Markdown identity, selection, replacement/resize, and environment propagation.

ScreenCaptureKit returned error -3811 when attempting fresh native visual inspection; a new recording was unavailable. The previous synthetic word-fade recording and deterministic bitmap tests remain valid for the unchanged renderer. Real trackpad feel and visual scroll-animation acceptance remain manual checks; the native geometry tests are not a substitute for them.

The fixture runner, reproduction command, isolation guards, and cleanup behavior are documented in [Development](DEVELOPMENT.md#native-long-conversation-fixture). Reports contain synthetic metrics only; raw Instruments traces and process environments must stay uncommitted.

The [quality gates](QUALITY.md#quality-gates) remain authoritative. macOS 15 manual interaction, hardware input/frame-hitch measurements, multi-megabyte individual messages, provider-dependent behavior, and seven-day real use require separate acceptance. Current-host Debug measurements must not be presented as completed cross-platform release validation.
