# English source and bilingual UI verification

Date: 2026-09-05. Branch: `dev`.

## Delivered behavior

- First-party implementation, comments, diagnostics, tool descriptions, and built-in prompts use English. CI checks the source policy, documented Unicode fixtures, catalog completeness, format placeholders, and compiler-extracted UI keys.
- Settings → General switches Mira-owned UI between `en` and `zh-CN` immediately and persists the selection. English keys and both translations live in the app's string catalog.
- Display language does not rewrite user content, model output, workspace background, saved titles, or request snapshots. Prompts remain English and ask the model to follow the user's requested language or message language.
- The pinned Microsoft SwiftStreamingMarkdown runtime has a narrowly scoped locale patch for copy controls, text-selection menus, and list/table accessibility labels. Its source, license, provenance, and focused tests are in `Vendor/SwiftStreamingMarkdown`.
- Early development uses the current v3 schema directly. Old schemas are rejected without deleting them; there are no historical backup upgrades, translated-error aliases, title sentinels, or text-based omission parsers. New conversations store an empty title until the first user message. Request snapshots belong to model attempts, and tool capability starts explicitly at `unknown`.

## Automated evidence

Local environment: macOS 26.6.2, Apple Silicon, Xcode 26.6, Swift 6.3.3. Deployment target: macOS 15.

| Check | Result |
|---|---|
| MiraKit package tests | 75 tests in 6 suites passed |
| Hostless localization tests | 5 XCTest tests and 3 Swift Testing renderer tests passed using compiled localization bundles |
| Debug app and tests | `xcodebuild ... -scheme Mira -configuration Debug ... test` passed |
| Release app | `xcodebuild ... -scheme Mira -configuration Release ... build` passed |
| Language policy and compiler-extracted UI coverage | 326 complete bilingual keys passed |
| Git whitespace check | `git diff --check` passed |
| GitHub Actions | Pending verification of the implementation commit |

Regression coverage includes locale selection and fallback, preference persistence, explicit locale lookup independent of process language, formatted arguments, both compiled resource bundles, renderer copy/list/table/menu labels, original user text preservation, prompt identity and reply-language instructions, typed omissions, direct empty-title storage, first-message title selection, and rejection of unsupported libraries/backups without deleting their contents. Existing request, stream, audit, cancellation, backup-integrity, and tool-boundary tests remain in the package suite.

## Native UI evidence

All UI checks used `--demo` and isolated temporary libraries; no real provider endpoint or credential was used.

- Switching Chinese → English updated the open Settings and conversation UI while preserving an unsent mixed Chinese/English draft.
- Sending the synthetic conversation, switching back to Chinese, and reopening the app retained the selected language. User-derived titles and original mixed-language content remained unchanged.
- A fresh v3 library rendered the synthetic Markdown response in Chinese UI. Switching the existing response to English updated its Copy control and list/table accessibility labels without changing message content.
- The final build reopened in English with the saved preference. Workspace creation sheets displayed correctly in both languages; their locale is passed explicitly because a native macOS sheet otherwise used the system locale during verification.
- A synthetic workspace with sending disabled produced the English restriction message. Switching to Chinese translated that same saved error immediately while preserving the original message and mixed-language workspace name.

macOS-owned menus and file-dialog controls follow the operating system language. This increment does not claim signed-distribution, real-provider, or macOS 15 native UI acceptance. Platform errors have resource coverage; the native UI error sample was the workspace send restriction, not every possible platform failure.

## Review

The parent reviewed the bounded GPT-5.6 Luna changes and independently reran acceptance checks. Review corrections included preserving the app-owned prompt identity and quoted user background, localizing dynamic SwiftUI labels at display time, explicitly propagating locale into native sheets and the inspector, removing old-format adapters, avoiding per-render catalog JSON parsing, and testing actual compiled renderer resources through Xcode.
