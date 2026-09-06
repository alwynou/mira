# Provider activation and model pool verification

Date: 2026-09-06. Branch: `dev`. This increment follows the user-requested provider activation → provider models → model pool → final model selection flow. It does not establish real-provider or release acceptance.

## Implemented behavior

Settings offers provider management, the shared model pool, and default model selection. New OpenAI, Anthropic, or custom protocol connections are saved inactive; activation is separate from credential presence and verified capabilities. An active provider supports explicit model-list fetching and manual private model IDs. Selecting a model saves its descriptor and canonical output preset atomically. Adding a pool model does not bind a purpose or authorize background extraction.

Disabling a provider retains its enabled model choices but hides them from the pool. Disabled model/provider selections fail closed. The conversation preserves an unavailable explicit selection and disables Send; default selection cannot save an unavailable pool entry. Model IDs are unique within a connection. No-op/name/activation-only connection edits preserve current attestations, while endpoint/key/protocol edits require reconfirmation and old stale observations remain stale.

Model discovery uses explicit, bounded GET requests with injected transport, per-request cancellation, same-endpoint Anthropic pagination, and sanitized errors. Discovery never sends local content, enables a model, or claims verified capabilities. Switching or editing a provider discards stale discovery responses. Probe completion uses frozen revisions and presentation generations; cancellation/mutation cannot overwrite a newly selected configuration or publish stale status. Text/tool capability icons have localized accessibility values.

## Acceptance evidence

- Full package acceptance passed **271 executed tests**, plus one deliberately skipped opt-in M5 scale test (**272 registered / 33 suites**): `/private/tmp/mira-provider-pool-tests-accepted.log`.
- Host acceptance passed **16 tests** (five localization XCTest cases and eleven renderer/Keychain Swift Testing cases): `/private/tmp/mira-provider-pool-host-accepted.log`.
- English source policy and **1,035 bilingual catalog entries** passed. Compiler-extracted coverage is checked against the final Host build.
- Debug app build and host tests passed with pinned package versions. The local worktree build includes concurrent icon work; exact-commit CI and packaging use only committed inputs.

The parent corrected an adapter path bug for Anthropic versus OpenAI, missing Anthropic pagination metadata, incomplete transport cancellation, a synthesized missing canonical route, and a now-invalid duplicate-ID fixture. Additional regressions make disabled-model/provider checks non-vacuous with an available alternative and prove that no-op saves preserve attestations while key rotation and stale activation do not restore them. UI review addressed unavailable selections, stale probe tasks, disabled-model removal, and capability accessibility values.

Exact revision, CI, and local package evidence will be recorded after completion.

## Remaining evidence

Native inspection through Computer Use timed out again (`-10005 timeoutReached`). No provider/model setup clicks, live language switching, or VoiceOver walkthrough is claimed for this increment. Real endpoint credentials were not configured and no generation or live model-catalog requests were made during acceptance; discovery tests use synthetic transports. Real OpenAI-compatible and Anthropic acceptance remains in the [execution ledger](MVP_EXECUTION.md).

This is fresh schema v8. Schema v7 and older development libraries are rejected intact; use a separate `--data-directory` instead of converting or deleting data. Previous M5 scale measurements and the schema-v7 package remain historical evidence of their recorded revision; this increment does not claim those source fingerprints match its new schema.

## Reference boundary

The interaction reference is LobeHub's [provider activation](https://github.com/lobehub/lobehub/blob/main/src/features/Settings/provider/features/ProviderConfig/EnableSwitch.tsx), [per-provider model list](https://github.com/lobehub/lobehub/blob/main/src/features/Settings/provider/features/ModelList/index.tsx), and [model selection](https://github.com/lobehub/lobehub/blob/main/src/features/ModelSelect/index.tsx). Mira uses its own native implementation and keeps explicit background authorization. Protocol behavior follows the official [OpenAI Models list](https://developers.openai.com/api/reference/resources/models/methods/list) and [Anthropic Models list](https://platform.claude.com/docs/en/api/models/list) references.
