# Mira interface verification

Date: 2026-09-07. Scope: the screenshot-inspired macOS interface and reusable design foundation. The owning product contract is [Design system](../product/DESIGN_SYSTEM.md).

## Implementation

- Appearance-aware colors, spacing, radii, layout measures, and system typography live in `Apps/MiraMac/DesignSystem/MiraTheme.swift`.
- Native row, icon, primary, circular action, and surface components share these tokens. Self-contained Xcode previews exercise the component library without opening a database or provider.
- The conversation shell, navigation, welcome state, message treatment, and composer use the new foundation. Memory, knowledge, task, and settings surfaces adopt the neutral palette and primary action treatment while retaining their existing workflows.
- `python3 scripts/export_design_tokens.py` exports the Swift source to `designs/mira-ui/tokens.json`. The app reads its Swift constants directly; the JSON adds no runtime parsing or compatibility surface.
- Appearance variants of the existing Mira vector mark are bundled in an asset catalog. They retain the selected identity and are not a copy of the reference product's logo.

No core, data, provider, runtime, schema, credential, or notification contract changed. Verification uses synthetic local demo replies, not paid endpoints.

## Automated evidence

- `swift test --package-path Packages/MiraKit`: 389 tests in 43 suites passed. Log: `.build/design-package-tests.log`.
- Required Debug build with pinned packages and `CODE_SIGNING_ALLOWED=NO`: passed. Log: `.build/design-build.log`.
- `MiraHostTests`: 62 Swift Testing cases and 6 XCTest cases passed; the explicit-opt-in real-model evaluation was skipped. Result: `.build/xcode/Logs/Test/Test-Mira-2026.09.07_22-42-43-+0800.xcresult`.
- `python3 scripts/check_language_policy.py`: passed with 1,273 bilingual entries. No new product strings or translated Swift source were introduced.
- `xcodegen generate`: regenerated the project for the design system sources and vector asset catalog. `git diff --check` passed.

The complete native suite at `.build/xcode/Logs/Test/Test-MiraUI-2026.09.07_22-44-04-+0800.xcresult` passed cancellation, English conversation persistence, new conversation from Memories (button and keyboard shortcut), and task edit/completion/reopen/relaunch. Its Chinese persistence case failed the exact-paste assertion after an external-window interruption; the isolated rerun passed at `.build/xcode/Logs/Test/Test-MiraUI-2026.09.07_22-48-29-+0800.xcresult`. All five existing native workflows therefore have passing evidence across these runs; the combined run itself remains failed and is retained honestly.

The first native test attempt found a container accessibility identifier propagating onto the composer input. Removing that redundant container identifier restored the existing stable input identifier. The focused cancellation test subsequently passed: `.build/xcode/Logs/Test/Test-MiraUI-2026.09.07_22-40-39-+0800.xcresult`.

## Visual QA

The source is the user-supplied 2,846 × 1,802 pixel Codex screenshot. This is a style transfer to an existing native product, so its personal content, Codex-only features, wallpaper, and logo are excluded from matching. Compare the application content at desktop point scale, not the screenshot's surrounding wallpaper. Mira preserves its native window chrome and existing feature set.

The initial rendered pass identified an overly strong composer focus border and a toolbar group placed beside the sidebar after hiding the native title. The focus outline was softened and the native unified title/toolbar layout restored. The subsequent conversation pass caught scrolled text drawing under the titlebar and the renderer’s default warm table palette. The transcript now clips to its viewport; public renderer configuration supplies neutral text/table/code chrome and underlined links without changing parser, continuation, image, or streaming policies. Reading and composer measures were calibrated to 760 pt after comparing the application content at the reference’s approximate point scale. Final captures are recorded below. The post-fix native screenshot confirms that the titlebar is unobstructed, code/table surfaces are neutral, links remain visibly underlined, user messages align to the right, and manual scrolling exposes the working Jump to latest control.

After the renderer-style and clipping changes, cancellation and English persistence/relaunch passed again (2 tests, zero failures): `.build/xcode/Logs/Test/Test-MiraUI-2026.09.07_22-58-40-+0800.xcresult`. The final normal Debug build also passed; see `.build/design-build-final.log`.

### Final capture review

**final result: passed** for the scoped native style transfer.

- [Light welcome](../../designs/mira-ui/previews/welcome-light.png): 1,368 × 788 pt window, captured at 2× (2,736 × 1,576 pixels), close to the reference's approximately 1,365 × 785 pt application window after excluding wallpaper. This is a shared comparison of the reference and final capture, not a claim of pixel-identical product content.
- [Dark narrow welcome](../../designs/mira-ui/previews/welcome-dark-narrow.png): 850 × 632 pt window, captured at 2×; navigation, model control, composer, and footer stay visible. The width is the application's minimum; total window height includes native chrome. The final 760 pt cap does not alter this narrow view because available content width is smaller.
- [Conversation](../../designs/mira-ui/previews/conversation-light.png): 1,100 × 760 pt, captured at 2×; synthetic user bubble, native assistant Markdown, manual reading position, and Jump to latest. Code/table styling and unobstructed toolbar were also inspected at the lower scroll position through native capture.

The five fidelity surfaces were checked: system typography and regular welcome title; 34 pt row rhythm and centered reading/composer measure; white/gray/charcoal colors; the intact Mira vector mark; and localized Mira-owned copy with synthetic demo content. The final comparison retains native macOS toolbar/sidebar materials and a multiline composer, which differ from Codex's chrome and compact input. These are intentional native/product adaptations. No remaining P0/P1/P2 visual issue was found in the inspected states. The snapshots are unmodified and include the system screen-sharing/cursor overlays visible during inspection.

The native model menu opened and selected the offline demo route. A Chinese draft enabled sending; the local reply completed; manually scrolling paused following and exposed Jump to latest. No real provider was contacted. The final application remains open in a Chinese light-mode demo using `.build/design-preview-library`.

## Sidebar translucency follow-up

The user's follow-up identified an opaque sidebar fill in the initial implementation. The sidebar now leaves its background clear, and the conversation window uses `.containerBackground(.clear, for: .window)`. `NavigationSplitView` supplies the native material; detail screens retain their opaque canvas. No custom blur renderer or additional visual-effect layer is installed. The component gallery uses the same split-view and window treatment.

The obsolete fixed sidebar color was removed from the Swift palette and JSON export. `systemSurfaces.sidebar` now records platform ownership and automatic appearance/accessibility behavior. `AGENTS.md` and the owning design document require preserving this material.

- Final required Debug build: passed, `.build/sidebar-material-build-final.log`.
- Existing native Memories-to-new-conversation workflow: one test passed, including toolbar and Command-N navigation. Result: `.build/xcode/Logs/Test/Test-MiraUI-2026.09.07_23-24-59-+0800.xcresult`.
- Token export regenerated; language policy passed with 1,273 bilingual entries; `git diff --check` passed. No product strings changed. Package/domain tests were not repeated for this presentation-only follow-up.
- A temporary native window with a synthetic blue/pink/orange background demonstrated visible tint through the light sidebar while the detail canvas stayed white. Capture the actual screen region after activating Mira: an isolated window snapshot omits the backdrop and can look opaque.
- [Dark, minimum-width preview](../../designs/mira-ui/previews/sidebar-glass-dark-narrow.png): English interface at 850 × 632 pt; navigation, selected row, composer, and footer remain visible. The system dark material is more subdued.

The host reported Reduce Transparency and Increase Contrast both disabled. Their enabled states were not changed or newly verified; macOS owns the material's accessibility treatment. The temporary colored backdrop is a QA fixture, not an application background. No paid provider was contacted.

### Final correction: original translucency and full-height sidebar

The user rejected the stronger-transparency experiment and its discontinuity beneath the titlebar. All custom backdrops, HUD material settings, native glass-ancestor configuration, and related material tokens were removed. The final implementation returns to the original `NavigationSplitView` material with a clear conversation window background. The native sidebar again continues through the titlebar area.

Only row interaction styling remains from that follow-up: a black/light or white/dark overlay at 10% for selection, 5% for hover, and 14% for pressing. Text and icons keep full opacity. Reduce Transparency and Increase Contrast retain solid interaction colors, and increased contrast retains the selected outline.

- Final restored build passed: `.build/sidebar-restored-build.log`.
- Language policy and `git diff --check` passed; portable tokens regenerated.
- [Restored sidebar and selected conversation](../../designs/mira-ui/previews/sidebar-restored-selection.png): native Chinese demo at 1,100 × 760 pt. The titlebar and sidebar are continuous, the synthetic conversation opens, and its selected row remains visibly highlighted. The temporary backdrop fixture was closed and removed afterward.
- The final restoration was checked with a build and native visual/selection inspection. The earlier navigation test above remains historical evidence; the automated suite was not repeated after this restoration.

`AGENTS.md` and the product design contract now explicitly preserve the original native material and full-height treatment. No experimental material hooks remain in app source.

### Unified, lighter sidebar highlight

The next visual adjustment unifies selected, hovered, and pressed rows under `opacity.sidebarHighlight` at 4%. `MiraSidebarRow` owns the single fill, while `MiraRowButtonStyle` forwards pressed state without drawing a background. Hovering a selected row therefore cannot stack another translucent layer. Accessibility fallback states also share one solid highlight token. Native sidebar material, titlebar, window configuration, and typography are unchanged.

The required Debug build passed (`.build/sidebar-highlight-build.log`), token export was regenerated, and language policy plus `git diff --check` passed. This is a row styling change; domain/package tests were not repeated.

## Limits

The host runs macOS 26.6.2 with a macOS 15 deployment target. Compilation is not a macOS 15 runtime test. Dark appearance, narrow layout, focus, disabled controls, navigation, and synthetic conversation behavior are visual/interaction checks rather than a complete VoiceOver, increased-contrast, or Reduce Transparency audit. Provider behavior and long-conversation performance gates are not expanded by this visual change.
