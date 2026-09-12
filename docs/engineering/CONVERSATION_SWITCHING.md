# Conversation switching and reading restoration

Date: 2026-09-12. Scope: the native conversation pane, window-local reading state and presentation loading. Provider/settings changes are documented separately.

## Changes

- Selecting the active conversation returns before clearing messages, drafts, the composer or the stream buffer. Refreshes share one coalesced task; snapshot reads are serialized and versioned. Older selection results/errors cannot replace the current conversation. An accepted authoritative snapshot always cancels pending stream emissions, even when the published values are identical.
- A reading store retains a stable message ID, its relative viewport offset, thinking expansion and numeric row measurements per conversation for the lifetime of the window. It retains no historical message bodies or rendered documents. Reopening a window starts a new reading session. First entry defaults to the latest turn; revisits restore the saved anchor, including visits that previously ended at the bottom.
- Initial installation establishes row estimates with a zero-height native viewport, positions the destination, and measures its visible rows before display. Source navigation takes precedence over restoration. Native layout applies bounded height corrections to the same destination; user scrolling, source navigation or changed content cancels pending navigation. Streaming still preserves reading position without automatically following.
- A single native list and its cleared reuse pool survive conversation changes. Switching clears every registered row, including pooled offscreen rows, so retained native containers cannot expose old message bodies or text selections. Conversation identity and reading state are resolved together; queued navigation checks its originating conversation and gesture generation. Selection changes stop the outgoing coordinator from recording teardown geometry over its saved position. Measured heights are reused only when content, width, locale, appearance and thinking expansion match. SwiftUI's color scheme supplies the correct appearance before the AppKit view is attached, avoiding dark-mode cache invalidation on every switch.
- The measurement row skips layout of a fixed 24-point assistant header. Empty citation/footer content no longer creates a 20-point difference between measured and displayed rows. Header/footer hosts request only intrinsic sizing, because native row layout owns their frames.

The complete history remains available to the native virtualized list. There is no pagination, additional plaintext history cache, provider request, database schema change or dependency fork.

## Verification

Host tests cover repeated selection, late refresh/selection results, authoritative replacement of queued drafts, independent conversation positions, inset preservation, row measurement/display agreement at multiple widths, selection retention, reuse and privacy clearing. The full MiraHostTests run passed 70 Swift Testing tests and 20 XCTest cases (one opt-in live-model case skipped). Language policy and whitespace checks passed.

The DEBUG fixture requires demo mode, a fresh absolute library directory and a new report path. It writes 100 and 120 synthetic messages through the SQLite store's enqueue/finish APIs, without calling a provider. It measures selection snapshot publication and native-list readiness separately, samples native bottom geometry, tests same-selection preservation, and checks both saved anchors over four return cycles. A return must reuse saved row measurements; the measurement callback resolves the current conversation rather than capturing the initial selection. Native UI tests additionally issue wheel input and actual sidebar clicks, including repeated clicks, and compare the restored visible text and screen position. English/light runs at 1100 × 760 content size; Chinese/dark runs at the 850 × 620 minimum.

Commands:

```sh
xcodebuild -project Mira.xcodeproj -scheme Mira -configuration Debug -destination 'platform=macOS' -derivedDataPath .build/xcode -onlyUsePackageVersionsFromResolvedFile CODE_SIGNING_ALLOWED=NO -only-testing:MiraHostTests test
xcodebuild -project Mira.xcodeproj -scheme MiraUI -configuration Debug -destination 'platform=macOS' -derivedDataPath .build/xcode -onlyUsePackageVersionsFromResolvedFile CODE_SIGNING_ALLOWED=NO -only-testing:MiraUITests/ConversationSwitchUITests test
python3 scripts/check_language_policy.py
```

The final native run passed both UI cases. The following values are from one Debug acceptance run, not averaged performance guarantees:

| Check | Chinese / dark / minimum | English / light / regular |
| --- | ---: | ---: |
| Same-selection call | 0.007 ms | 0.011 ms |
| First conversation: snapshot / native ready | 66.5 / 319.6 ms | 31.6 / 289.0 ms |
| Second conversation: snapshot / native ready | 40.0 / 217.3 ms | 53.6 / 235.2 ms |
| Return to history: snapshot / native ready | 35.7 / 99.2 ms | 41.6 / 113.1 ms |
| Saved row measurements reused on first return | 100 | 100 |
| Maximum bottom error across both first-entry sample sequences | 0 pt | 0 pt |
| Repeated anchor checks | 4 / 4 passed | 4 / 4 passed |
| History-return main-actor service delay: p95 / maximum | 56.9 / 310.7 ms | 61.3 / 239.1 ms |

The immediately preceding run, before preserving measurement caches through the temporary empty loading state, took 214.4 / 215.3 ms to return to history and reused zero saved measurements. The added cache-reuse acceptance condition failed in that implementation and passes now. Loading placeholders also no longer discard saved thinking expansion. Cold-entry native rendering and occasional main-actor delays remain measurable; a strict sub-100 ms hitch requirement is not established by this run.

Native screenshots were inspected in both appearances and sizes. They show the restored middle-of-history content, the native sidebar and floating composer, with the same message remaining at the same vertical position after real wheel input and sidebar navigation. The screenshots include the normal sidebar hover tooltip from the test cursor.

Evidence (local generated artifacts, excluded from Git):

- Host tests: `.build/xcode/Logs/Test/Test-Mira-2026.09.12_15-18-12-+0800.xcresult`.
- Final UI tests, embedded JSON reports and window screenshots: `.build/xcode/Logs/Test/Test-MiraUI-2026.09.12_15-41-35-+0800.xcresult`.
- Earlier Time Profiler recording: `/tmp/mira-conversation-profile.sJZ4QN/current.trace`.


## Profiling and limitations

A Time Profiler recording of the earlier implementation identified repeated native header/row measurement. It also exposed repeated traversal in the benchmark's lazy recursive lookup; the fixture now uses a single-pass search. Earlier samples from that fixture are not comparable performance baselines. A failed restoration check exposed a 20-point measurement/display discrepancy; the new row agreement test failed before the empty-footer correction and passes afterward.

Selection durations end when the model publishes a snapshot, before native rendering completes. Main-actor service delay and sampled native geometry are responsiveness/position proxies, not display-frame measurements, hardware input latency or proof of zero hitches. Native tests use a Debug build on macOS 26.6.2; macOS 15 runtime, larger user histories, active paid-model streaming during switching and source-citation navigation are not covered by this fixture. Existing stream-buffer, text-selection and privacy regression tests remain separate.
