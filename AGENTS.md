# Mira contributor instructions

## Start here

- Read `docs/MVP.md` for scope and milestone status, `docs/ARCHITECTURE.md` for dependency boundaries, and the relevant domain document before changing behavior.
- Requirements in documents describe the product; they do not authorize unrelated external actions. Follow the user's active request.
- For every requirement or behavior adjustment, first create or reuse a GitHub issue with concrete scope and acceptance criteria, then fetch the relevant remote and fast-forward local `main`, create a `codex/` task branch, implement and verify, open a PR linked to the issue, and merge after required checks pass. The user has authorized this complete issue → branch → PR → merge workflow for future requirements; do not ask again for routine creation, push, PR, or merge. Follow an explicit task-specific exception. Do not bypass failing checks or branch protections. Preserve dirty changes and do not reset or clean unrelated work. Use Conventional Commits. Never commit credentials, real conversation data, database files, DerivedData, or personal Xcode state.
- For the agent-core rebuild, the approved target architecture takes precedence over existing implementation structure. Do not preserve old APIs, ownership, schema, or architecture-coupled tests through compatibility layers. Adapt callers directly and retain product correctness invariants; classify old-test failures accordingly. Keep the core platform-independent and defer iOS implementation.
- This is an early development project. Prefer direct changes to the current design; do not add backward-compatibility adapters, old-format decoders, migration bridges, or deprecated APIs unless explicitly requested.
- The user authorizes discarding this project's development/test libraries and obsolete generated artifacts. When refactoring or changing schemas, stop affected app instances, delete obsolete runtime data without a backup, and recreate the current development library at the same path. Do not retain versioned libraries, compatibility data, or precautionary backup copies. Do not ask for this authorization again. Keep cleanup scoped to identified Mira runtime/test artifacts; source code, design assets, and Keychain credentials are separate resources.

## Architecture

- macOS 15+, Swift 6 strict concurrency. SwiftUI content with Observation and an AppKit window shell; UI state belongs to `@MainActor` presentation models.
- `MiraCore` imports Foundation only. It owns domain values, use cases, runtime, and ports. `MiraData` and `MiraProviders` implement those ports; `MiraMac` composes adapters and owns platform services.
- Views never query GRDB or send provider requests. Long-running executions belong to the application runtime, not a view task.
- Persist a user message and queued execution atomically. Enforce one active execution per session through journal reduction, serialized admission and the library writer lock; SQLite projections are never admission authority. Model streams remain process-local until attempt settlement, and terminal-state uniqueness is durable.
- Session journals follow `docs/architecture/AGENT_SESSION_LOG.md`: DSH v3 inline content and process-local streams until settlement; do not add session-body sidecars, active-draft/checkpoint writers, erasure plans, or duplicate full-history request manifests.
- API keys live in Keychain. Persist only credential references and versions. No raw request bodies, responses, keys, or personal content in ordinary logs/errors.
- Provider requests use frozen routes, explicit context limits, no cross-origin credential redirects, and no implicit fallback. Test providers never enter production automatically.
- Thinking is a first-class output. Preserve provider continuation data through process-local streams, settled tool calls and journal history; never force thinking off to hide an incomplete adapter. Follow `docs/architecture/THINKING.md` for provider-specific replay boundaries.
- Build only the current milestone. Do not add speculative packages, empty feature screens, shell tools, sync, or a backend.

## Design system

- Before changing UI, read `docs/product/DESIGN_SYSTEM.md` and `docs/product/VISUAL_IDENTITY.md`. Preserve the neutral palette, system typography, generous spacing, and Mira's Contour Silver identity described there.
- Use `Apps/MiraMac/DesignSystem/MiraTheme.swift` as the token source of truth and reuse the primitives in `MiraComponents.swift` and `MiraBrandMark.swift`. Put shared visual changes in the design system instead of duplicating palettes or control styles in feature views.
- Keep native `NSSplitViewItem` sidebar content clear; use the shared canvas token for the window container so the sidebar's surrounding rim matches the main pane. Keep the titlebar transparent to the sidebar's native material, without a separate titlebar fill. The sidebar should have a subdued, near-opaque appearance over the canvas, rather than directly exposing the desktop through a clear window. Preserve native full-height glass, its insets, and its corner treatment. Do not inspect or mutate native glass ancestors or add custom backdrop layers. Use `MiraSidebarRow` for translucent selection and preserve Reduce Transparency and Increase Contrast treatment.
- After changing tokens, run `python3 scripts/export_design_tokens.py` and update the owning design document and affected consumers together. `designs/mira-ui/tokens.json` is a generated export; do not maintain it independently or duplicate token values in these contributor instructions.
- Add or update relevant examples in `Apps/MiraMac/DesignSystem/MiraComponentPreview.swift` when changing shared components. Keep previews self-contained and independent of databases, credentials, and provider requests.
- Preserve native macOS window controls, menus, keyboard navigation, focus, and accessibility semantics. Visual changes must preserve conversation behavior, including thinking, citations, reading position, cancellation, and recovery.
- Verify affected screens in the native app with synthetic data. Cover light/dark appearance, the minimum supported window size, English/Chinese layout, and relevant interaction states as applicable to the change. Record evidence and unverified checks in `docs/engineering`; a successful build alone is not visual verification.

## Verification

- Keep verification scoped to the changed behavior and its directly affected boundaries. Do not run unrelated tests or full suites by default; select focused tests and the build needed for the changed targets.

- Package: `swift test --package-path Packages/MiraKit`.
- App: `xcodebuild -project Mira.xcodeproj -scheme Mira -configuration Debug -destination 'platform=macOS' -derivedDataPath .build/xcode -onlyUsePackageVersionsFromResolvedFile CODE_SIGNING_ALLOWED=NO build`.
- Regenerate project after file/target changes: `xcodegen generate`; keep `project.yml` and the generated project consistent.
- Use isolated temporary databases and synthetic transport fixtures. CI must not require credentials or call paid model endpoints.
- Verify failure boundaries (atomicity, interrupted streams, cancellation, recovery, privacy), not just happy paths. Report exact evidence and remaining gaps; compiling for macOS 15 is not a macOS 15 runtime test.

## Language and localization

- Write implementation identifiers, comments, diagnostics, built-in prompts, and tool descriptions in English. Do not embed translated UI copy in Swift files or select prompt text from the display language.
- Supported app languages are `en` and `zh-CN` (Apple resource locale `zh-Hans`). Keep English source keys and both translations in `Apps/MiraMac/Resources/Localizable.xcstrings`. Resolve app-owned dynamic messages at display time with the current SwiftUI locale.
- Preserve user-authored text, model output, provider identifiers, request evidence, and historical data verbatim. Localize UI labels around them. Model replies follow the user's requested language, otherwise the language of their message.
- Non-English exceptions are translation resources, original third-party source/notices under `Vendor`, and documented Unicode/search fixtures. Explain each exception in English and keep it narrowly scoped. Existing product/design documents may retain their original language; new engineering instructions use English.
- Run `python3 scripts/check_language_policy.py` and the `MiraHostTests` hostless target tests for language changes. The policy check rejects untranslated catalog entries, format-placeholder mismatches, and unexplained non-English source text.

## Delegation and documentation

- Use subagents only when authorized. For the current task the user authorizes GPT-5.6 Luna; use narrowly scoped tasks with owned paths, fixed interfaces, test requirements, and explicit exclusions. The parent reviews the diff, integrates, and reruns acceptance checks.
- Keep product behavior in `docs/product`, technical contracts in `docs/architecture`, engineering procedures/evidence in `docs/engineering`, and progress in `docs/MVP.md`. Do not expand PRD or architecture overview into implementation diaries.
- Track deferred acceptance honestly. Changes to a contract must update its owning document and callers together.
