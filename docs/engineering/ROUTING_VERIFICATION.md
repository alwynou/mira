# Routing verification

Date: 2026-09-05  
Branch: `dev`  
Scope: MiraCore model configuration, route resolution, capability validation, immutable snapshots, and dispatch authorization.

## Independently confirmed evidence

The package suite passed with:

```sh
swift test --package-path Packages/MiraKit
```

Result: **91 tests in 7 suites passed**. The package run uses synthetic transport, configuration, and policy fixtures; it does not establish compatibility with a paid provider or a real credential.

The package coverage exercises the current normalized configuration split (`ProviderConnection`, `ModelDescriptor`, `ModelRoute` preset, and `RouteBinding`), purpose-specific bindings, and selection precedence in explicit, conversation, workspace, and global order. It also covers independent purpose routes, missing or dangling selected routes without fallback, workspace remote-send policy, `nil` versus empty connection allowlists, unknown context or capability blocking, and stale connection revisions downgrading capabilities.

The runtime fixtures cover immutable snapshots, model/route mutation and workspace-policy revocation before dispatch, and stale probe rejection when the connection, model, or preset has changed. Configuration component CRUD and backup round-trip fixtures are included in the package evidence. These checks verify the authorization and snapshot boundaries without sending personal content or using credentials.

## Host and native verification

The parent ran Debug host tests and a Release build with the documented pinned dependency options. Both passed. `MiraHostTests` passed 5 XCTest localization tests and 11 Swift Testing tests: 8 injected Keychain lifecycle tests and 3 renderer localization tests. The Keychain fixtures cover immutable versioned saves, locked/denied/malformed reads, shared references, cleanup failure/retry, and corrupt-ledger protection without calling the real Keychain.

The language policy and compiler-extracted UI coverage passed with 436 bilingual catalog keys. Release compiled both arm64 and x86_64; this is not an Intel runtime test. Vendored renderer deprecation warnings and the expected unused App Intents metadata warning remain; no first-party compiler warnings were found.

On macOS 26.6.2 / Apple Silicon, an isolated `--demo` library verified inherited global conversation routing, successful synthetic response, immutable route audit labels, persisted conversation after restart, provider subnavigation, independent unbound memory-extraction purpose, English/Chinese settings labels, and the English connection editor. Native inspection found and fixed nested settings tabs merging into the window toolbar. Demo saves and probes remain disabled; no endpoint or real credential was used.

## Acceptance still pending

The following evidence was not established by this package run:

- **Platform credentials:** an attended real Keychain lock, rejection, cleanup, and disposable credential exercise remains deferred.
- **Native macOS:** macOS 15 runtime, Intel runtime, complete keyboard/VoiceOver flows, and real configuration saves remain unverified.
- **CI:** implementation commit `a5347317f26bf2b819eb1e74ee53346a72eee51d` passed package tests, Host tests, and compiler-extracted language coverage on macos-15 / Xcode 26.3: [run 33964811120](https://github.com/alwynou/mira/actions/runs/33964811120). This does not establish native macOS 15 UI behavior.
- **Providers:** no real OpenAI-compatible or Anthropic endpoint calls, model probing, billing behavior, or credential handling against a paid endpoint was tested.
- **Quality datasets:** synthetic agent fixtures do not satisfy the human labeling gate for Q04–Q06 datasets or actual model evaluation. Seven-day use and memory quality remain user-dependent.

The package result is implementation evidence for routing boundaries, not release acceptance.
