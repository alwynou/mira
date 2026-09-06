# Mira contributor instructions

## Start here

- Read `docs/MVP.md` for scope and milestone status, `docs/ARCHITECTURE.md` for dependency boundaries, and the relevant domain document before changing behavior.
- Requirements in documents describe the product; they do not authorize unrelated external actions. Follow the user's active request.
- Work on `dev` for the current implementation. Use Conventional Commits. Never commit credentials, real conversation data, database files, DerivedData, or personal Xcode state.
- This is an early development project. Prefer direct changes to the current design; do not add backward-compatibility adapters, old-format decoders, migration bridges, or deprecated APIs unless explicitly requested.
- The user authorizes discarding this project's development/test libraries and obsolete generated artifacts. When refactoring or changing schemas, stop affected app instances, delete obsolete runtime data without a backup, and recreate the current development library at the same path. Do not retain versioned libraries, compatibility data, or precautionary backup copies. Do not ask for this authorization again. Keep cleanup scoped to identified Mira runtime/test artifacts; source code, design assets, and Keychain credentials are separate resources.

## Architecture

- macOS 15+, Swift 6 strict concurrency. Native SwiftUI with Observation; UI state belongs to `@MainActor` presentation models.
- `MiraCore` imports Foundation only. It owns domain values, use cases, runtime, and ports. `MiraData` and `MiraProviders` implement those ports; `MiraMac` composes adapters and owns platform services.
- Views never query GRDB or send provider requests. Long-running executions belong to the application runtime, not a view task.
- Persist a user message and queued execution atomically. Enforce one active execution per conversation in SQLite. Preserve recoverable drafts and terminal-state uniqueness.
- API keys live in Keychain. Persist only credential references and versions. No raw request bodies, responses, keys, or personal content in ordinary logs/errors.
- Provider requests use frozen routes, explicit context limits, no cross-origin credential redirects, and no implicit fallback. Test providers never enter production automatically.
- Thinking is a first-class output. Preserve provider continuation data through streams, drafts, tool calls, persistence and privacy cleanup; never force thinking off to hide an incomplete adapter. Follow `docs/architecture/THINKING.md` for provider-specific replay boundaries.
- Build only the current milestone. Do not add speculative packages, empty feature screens, shell tools, sync, or a backend.

## Verification

- Package: `swift test --package-path Packages/MiraKit`.
- App: `xcodebuild -project Mira.xcodeproj -scheme Mira -configuration Debug -destination 'platform=macOS' -derivedDataPath .build/xcode -onlyUsePackageVersionsFromResolvedFile -skipMacroValidation CODE_SIGNING_ALLOWED=NO build`. The macro flag is scoped to the pinned renderer dependencies; see `docs/engineering/DEVELOPMENT.md`.
- Regenerate project after file/target changes: `xcodegen generate`; keep `project.yml` and the generated project consistent.
- Use isolated temporary databases and synthetic transport fixtures. CI must not require credentials or call paid model endpoints.
- Verify failure boundaries (atomicity, interrupted streams, cancellation, recovery, privacy), not just happy paths. Report exact evidence and remaining gaps; compiling for macOS 15 is not a macOS 15 runtime test.

## Language and localization

- Write implementation identifiers, comments, diagnostics, built-in prompts, and tool descriptions in English. Do not embed translated UI copy in Swift files or select prompt text from the display language.
- Supported app languages are `en` and `zh-CN` (Apple resource locale `zh-Hans`). Keep English source keys and both translations in `Apps/MiraMac/Resources/Localizable.xcstrings`. Resolve app-owned dynamic messages at display time with the current SwiftUI locale.
- Preserve user-authored text, model output, provider identifiers, request snapshots, and historical data verbatim. Localize UI labels around them. Model replies follow the user's requested language, otherwise the language of their message.
- Non-English exceptions are translation resources, original third-party source/notices under `Vendor`, and documented Unicode/search fixtures. Explain each exception in English and keep it narrowly scoped. Existing product/design documents may retain their original language; new engineering instructions use English.
- Run `python3 scripts/check_language_policy.py` and the `MiraHostTests` hostless target tests for language changes. The policy check rejects untranslated catalog entries, format-placeholder mismatches, and unexplained non-English source text.

## Delegation and documentation

- Use subagents only when authorized. For the current task the user authorizes GPT-5.6 Luna; use narrowly scoped tasks with owned paths, fixed interfaces, test requirements, and explicit exclusions. The parent reviews the diff, integrates, and reruns acceptance checks.
- Keep product behavior in `docs/product`, technical contracts in `docs/architecture`, engineering procedures/evidence in `docs/engineering`, and progress in `docs/MVP.md`. Do not expand PRD or architecture overview into implementation diaries.
- Track deferred acceptance honestly. Changes to a contract must update its owning document and callers together.
