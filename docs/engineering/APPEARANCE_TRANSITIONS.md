# Appearance transition verification

Date: 2026-09-09. Host: macOS 26.6.2, system light appearance.

The user reported mixed light/dark rendering after Dark → Follow System. Production roots set both SwiftUI `preferredColorScheme` and `NSApplication.appearance`. The regression fixture reproduced the divergence: after returning to system, application and window appearance resolved to light, while the sidebar and detail SwiftUI environments remained dark.

`MiraAppAppearance` now owns the saved preference and sets only the application appearance. Follow System sets it to nil, allowing normal AppKit inheritance through the native split shell and its SwiftUI hosting controllers. No window/view reconstruction, native glass manipulation, forced redraw loop, or system preference write is used. Preview-only explicit appearances remain separate from production preference ownership.

`AppDisplayModeTests.testExplicitAppearanceReturnsToSystemAcrossHostedPanes` mounts the actual modifier and split shell in a native window with isolated UserDefaults. It checks application, window, sidebar, and detail appearance through Dark → System → Light → System → Dark → System, relative to the host's system appearance. Before the fix, both panes failed on both Dark → System transitions (four assertions). Application and window assertions passed, isolating the stale hosted-content state. The fixture restores application appearance and deletes its test preference domain.

After the fix, the regression and complete host suite passed: 10 XCTest passes, one opt-in live-provider skip, and 52 Swift Testing tests across 11 suites. Debug/Release builds, language policy (1,139 bilingual strings), and whitespace checks passed. Local build logs are `.build/appearance-before-tests.log`, `.build/appearance-after-tests.log`, and `.build/appearance-release.log`.

Native UI verification used a separately identified synthetic app and isolated library. At 850 × 620, the settings page was inspected in [Dark](evidence/2026-09-09-appearance-dark.png), then changed through its actual selector to [Follow System](evidence/2026-09-09-appearance-system-light.png). Both sidebar and detail returned to light together. Returning to the conversation showed a light transcript and composer with the synthetic eight-line draft retained. The [floating-composer fixture](evidence/2026-09-09-appearance-layout.json) passed all five English/light and Chinese/dark scenarios, zero wheel events, 14 pt bottom spacing, final-row clearance, and stable streaming/terminal offsets.

No system appearance preferences or provider requests were changed. macOS 15 runtime, changing the system itself while the app is open, simultaneous multiple windows, sheets, and full accessibility interaction were not exercised in this increment. The disposable app/library was removed and the normal Release app relaunched.
