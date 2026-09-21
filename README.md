<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="designs/mira-app-icon/final/mira-logo-white.svg" />
    <source media="(prefers-color-scheme: light)" srcset="designs/mira-app-icon/final/mira-logo-black.svg" />
    <img src="designs/mira-app-icon/final/mira-logo-black.svg" alt="Mira logo" width="160" />
  </picture>
</p>

<h1 align="center">Mira</h1>

<p align="center">
  A local-first AI assistant for conversations, personal memory, and knowledge.
</p>

<p align="center">
  <a href="https://github.com/alwynou/mira/actions/workflows/ci.yml"><img src="https://github.com/alwynou/mira/actions/workflows/ci.yml/badge.svg" alt="Swift checks" /></a>
  <img src="https://img.shields.io/badge/macOS-15%2B-222222?logo=apple&logoColor=white" alt="macOS 15 or newer" />
  <img src="https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white" alt="Swift 6" />
  <img src="https://img.shields.io/badge/status-early%20development-888888" alt="Early development" />
</p>

<p align="center">
  <strong>English</strong> · <a href="README.zh-CN.md">简体中文</a>
</p>

<p align="center">
  <a href="#features">Features</a> ·
  <a href="#roadmap">Roadmap</a> ·
  <a href="#quick-start">Quick start</a> ·
  <a href="#documentation">Documentation</a>
</p>

Mira is a native macOS workspace that connects your own model providers to conversations, tools, and reusable personal knowledge. It is built around a simple loop: remember something useful, recall it in a later conversation, inspect its source, and correct or forget it when it changes.

Your library lives on your Mac. You bring your own API keys (BYOK), choose your models, and control which memories and knowledge may be sent to them. Mira requires no account or Mira-hosted backend.

> **Early development.** Core functionality is implemented, but v0.1 release acceptance is still in progress. Build from source to try it. Development builds use disposable libraries and do not support older data formats. Knowledge and Tasks management screens remain deferred.

## Features

- **Native conversations** — workspaces, streaming Markdown, code and math rendering, separate thinking output, and cancellation, retry, and recovery.
- **Your models, your settings** — OpenAI Chat Completions, OpenAI Responses, and Anthropic Messages adapters; compatible custom endpoints, model discovery, manual model IDs, and explicit context limits.
- **Memory you can correct** — automatic capture of eligible user-stated facts and preferences, local semantic and text recall, and a native manager for inspecting sources, editing, replacing, archiving, and forgetting.
- **Knowledge with provenance** — Markdown snapshot import, versioned sources, local retrieval, and verifiable references in the core. The management interface is still pending.
- **Visible agent activity** — bounded tool execution, permission checks, inspectable results, and foreground/background usage and cost estimates when provider data is available.
- **Local ownership** — on-device storage, Keychain credentials, scope and remote-use controls, and library backup and restore.
- **English and Simplified Chinese** — switch the interface language in Settings without changing your content or the language of model replies.

<p align="center">
  <img src="docs/engineering/evidence/memory-management/en-light-wide-detail.png" alt="Mira's native memory manager showing a local-only memory, its scope, source, and editing actions" width="960" />
</p>

<p align="center">
  <sub>Native memory management with synthetic demo data. Knowledge and Tasks screens are still pending.</sub>
</p>

## Roadmap

Checked items mean the capability is implemented with scoped verification; they do not mean every release gate has passed. The [MVP plan](docs/MVP.md) owns detailed scope and acceptance status.

### Implemented

- [x] Native macOS conversation workspace and bilingual settings.
- [x] BYOK connections, model pool, three model protocols, and thinking/tool continuation.
- [x] Journal-backed agent runtime with cancellation, retry, and crash recovery.
- [x] Automatic memory extraction and local hybrid semantic/text recall.
- [x] Native memory management with current/history views, sources, corrections, and forgetting.
- [x] Markdown import, versioned knowledge retrieval, and source validation in the core.
- [x] Local library backup, restore, and unsigned development packaging.
- [x] Task tools and one-time local reminder infrastructure; replacement management UI pending.

### Next

- [ ] Complete broader real-model evaluations for memory capture, correction, forgetting, and relevant recall.
- [ ] Expand live provider coverage, including thinking and tool continuation.
- [ ] Build the Knowledge and Tasks management interfaces.
- [ ] Complete native macOS 15, Intel, accessibility, and interaction acceptance.
- [ ] Meet remaining large-library, latency, and long-conversation performance gates.
- [ ] Prepare signed, notarized downloads and verify installation and updates.

### Later / deferred

- [ ] Validate reminder delivery with Focus enabled.
- [ ] Explore recurring reminders and Apple Calendar / Reminders publishing.
- [ ] Expand structured records and explore an iOS app.

These are development directions, not release-date commitments. See the [memory UI evidence](docs/engineering/MEMORY_MANAGEMENT_VERIFICATION.md), [memory integration limits](docs/engineering/LOCAL_MEMORY_IMPLEMENTATION.md), and [release acceptance record](docs/engineering/MVP_EXECUTION.md) for verified scope and remaining gaps.

## Quick start

### Prerequisites

- macOS 15 or newer. Current native and local embedding evidence comes from Apple Silicon; Intel runtime acceptance remains open.
- Xcode 26.3 or newer with its command-line tools selected. Host dependencies require Swift 6.2+; the project uses Swift 6 language mode.
- Your own model-provider credentials for real conversations. The Debug demo below needs no API key.

### Build and run

```sh
git clone https://github.com/alwynou/mira.git
cd mira
xcodebuild -project Mira.xcodeproj -scheme Mira -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath .build/xcode \
  -onlyUsePackageVersionsFromResolvedFile CODE_SIGNING_ALLOWED=NO build
open .build/xcode/Build/Products/Debug/Mira.app
```

You can also open `Mira.xcodeproj` and run the shared **Mira** scheme. The generated project is committed; XcodeGen is only needed when changing the project definition or file organization.

### Connect a model

1. Open **Settings → Providers**, add a built-in or compatible custom provider, and save and enable the connection with your endpoint and API key.
2. Fetch its model list or enter a model ID manually, then enable the models you want in the model pool.
3. Review the model's context window, output limit, and capabilities. Supply missing context limits before sending a request.
4. Select a model in a conversation or configure a default, then start chatting.

API keys stay in Keychain. Discovery queries the selected provider's model catalog; explicit tests send synthetic prompts and may incur provider charges. An invalid model selection produces an error instead of silently switching providers.

Memory capture runs automatically in batches after completed turns, using the batch's last completed conversation route. It makes additional provider requests and can incur usage charges; there is no separate extraction model or daily extraction quota. Per-request model limits still apply. **Settings → Memory** shows local embedding preparation and status. Semantic recall uses a locally downloaded Qwen embedding model through MLX. See [memory behavior](docs/product/MEMORY_AND_KNOWLEDGE.md) and [local model integration](docs/engineering/LOCAL_MEMORY_IMPLEMENTATION.md).

### Try the offline demo

Quit any running Mira instance, then launch the Debug app with an isolated temporary library:

```sh
open .build/xcode/Build/Products/Debug/Mira.app --args \
  --demo --data-directory /tmp/mira-demo
```

The demo uses synthetic responses, makes no provider requests, and does not access credentials. It previews the interface; real memory quality requires real-model evaluation. Demo mode is unavailable in Release builds.

## Data and privacy

- Conversations and execution history live in local session journals; domain records and search projections live in SQLite and managed files.
- The default library is `~/Library/Application Support/Mira`. Use an absolute `--data-directory` path for an isolated development library, and quit Mira before switching libraries.
- Remote models receive the context authorized for the selected connection. Local storage does not make provider requests offline.
- Manually added memories start local-only, with remote-use settings you can inspect and change. Automatic capture skips content classified as sensitive.
- Library backup and restore are implemented. Development schemas may change without migration support; use disposable data while evaluating the project.

Read the [data and privacy contract](docs/product/DATA_AND_PRIVACY.md) for scope, disclosure, export, deletion, and forgetting behavior.

## Architecture

Mira uses ports and adapters, with dependencies pointing toward a Foundation-only core:

```text
MiraMac (SwiftUI + AppKit, composition, platform services)
  ├── MiraData      ──┐
  ├── MiraProviders ──┼──> MiraCore (Foundation only)
  └──────────────────┘
```

The application runtime owns long-running executions independently of views. Session journals are authoritative for conversation execution; SQLite projections can be rebuilt. Platform services such as Keychain, notifications, and MLX stay in the macOS host.

| Path | Purpose |
| --- | --- |
| `Apps/MiraMac/` | Native app, presentation models, design system, and platform adapters |
| `Packages/MiraKit/Sources/MiraCore/` | Domain values, use cases, agent runtime, and ports |
| `Packages/MiraKit/Sources/MiraData/` | Persistence, search, managed files, and backup adapters |
| `Packages/MiraKit/Sources/MiraProviders/` | Model protocols, discovery, and transport adapters |
| `Tests/` | Host, composition, and native UI tests with synthetic fixtures |
| `docs/` | Product scope, architecture contracts, and engineering evidence |
| `designs/` | Brand assets, design explorations, and exported tokens |

See the [architecture overview](docs/ARCHITECTURE.md) and [agent core design](docs/architecture/AGENT_CORE_PROPOSAL.md).

## Development and contributing

Bug reports and focused contributions are welcome. Start with a [GitHub issue](https://github.com/alwynou/mira/issues), describe the problem and acceptance criteria, and read the [contributor instructions](AGENTS.md) and [development guide](docs/engineering/DEVELOPMENT.md). Work from an updated `main` on a `codex/` task branch, use Conventional Commits, and submit a linked pull request. Required checks must pass before merge.

| Command | Purpose |
| --- | --- |
| `swift test --package-path Packages/MiraKit` | Run package tests; add `--filter` for focused work |
| `python3 scripts/check_language_policy.py` | Check English source and bilingual UI resources |
| `python3 -m unittest discover -s scripts/tests` | Check catalog and supporting scripts |
| `xcodegen generate` | Regenerate the project with XcodeGen 2.46.0 after project/file changes |

Select tests for the behavior you change. App language changes also require `MiraHostTests`; native UI changes require actual interaction checks. CI uses synthetic fixtures and does not require paid model endpoints. Never include API keys, real conversations, or development libraries in contributions.

For a ZIP built from a committed revision, follow the [local packaging procedure](docs/engineering/LOCAL_DELIVERY.md). Public distribution acceptance is still pending.

## Documentation

| Guide | Contents |
| --- | --- |
| [Product overview](docs/PRD.md) | Product intent, user control, and success criteria |
| [MVP and milestones](docs/MVP.md) | Implemented scope, next increments, and acceptance gates |
| [Architecture](docs/ARCHITECTURE.md) | Module boundaries and technical contracts |
| [Memory and knowledge](docs/product/MEMORY_AND_KNOWLEDGE.md) | Capture, recall, sources, correction, and forgetting |
| [Development](docs/engineering/DEVELOPMENT.md) | Toolchain, builds, tests, and contribution workflow |
| [Quality standards](docs/engineering/QUALITY.md) | Evaluation methodology and release gates |
| [Visual identity](docs/product/VISUAL_IDENTITY.md) | Contour Silver logo and app identity |

Product and architecture documents currently include Chinese content; engineering evidence records each verification increment's scope.

## License

A project-wide license has not yet been declared. Bundled dependencies retain their respective licenses; see [third-party notices](Apps/MiraMac/Resources/ThirdPartyLicenses.txt).
