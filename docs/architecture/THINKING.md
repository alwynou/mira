# Thinking and provider continuation

Thinking is a first-class model output, separate from the answer and from tool authorization. Supporting a reasoning-capable model requires both its request controls and its continuation protocol. A catalog declaration is not a transport test.

## Domain and ownership

`ThinkingSettings` belongs to a model route and is copied into the immutable execution snapshot. It contains provider-default/enabled/disabled mode, optional effort, and optional token budget. `ModelProtocolMode` selects a reviewed wire policy; it no longer means that reasoning must be disabled. The pool editor exposes the controls supported by that policy and model. OpenRouter effort and token budget are alternatives; selecting one clears the other. Custom deployments can explicitly select the relevant interface; catalog matching remains exact by endpoint and model ID.

`ReasoningContent` carries visible thinking text plus provider replay material. Formats distinguish OpenAI-style reasoning text, Anthropic ordered assistant blocks, and OpenRouter reasoning details. `isComplete` distinguishes a recoverable partial draft from material that can be replayed. `CanonicalStreamEvent.reasoning` publishes cumulative snapshots (first content promptly, then approximately every 100 ms or 4 KiB while data arrives, with final/error flush); model outputs and canonical assistant messages preserve the same value.

The application runtime owns the stream. Views receive snapshots and show a collapsible Thinking section before the answer, including thinking-only interrupted replies. Opaque signatures, encrypted details and redacted blocks are preserved for the provider and never shown as readable thinking. No reasoning is invented when a service returns only an answer or hidden state.

## History boundaries

The current assistant/tool turn uses a frozen base request and fixed tool definitions. Authorization, route identity, memory and source policies are still checked before every dispatch. A policy failure stops execution; it does not silently rewrite a signed prefix.

For DeepSeek, Kimi and OpenRouter, successful same-model/same-connection/same-endpoint history containing thinking replays the complete ordered assistant/tool transcript, including intermediate decisions, only when that history remains eligible under current memory and source policy. Context budgets include reasoning and replay data. Incomplete and unsuccessful turns are excluded from future successful history, as before. Switching models or connections retains ordinary answer text without transferring provider continuation material. A forgotten or otherwise invalidated memory excludes its affected history and transitive descendants from replay.

Anthropic tool continuation echoes the complete current assistant content array in its original order, including thinking, redacted thinking, signatures, text and tool-use blocks. At a new user turn Mira rebuilds its retrieved context; it therefore omits **all** completed prior-turn Anthropic thinking blocks. Anthropic permits that boundary. Mixing old signed thinking with an edited system/tools/message prefix is not supported. The current tool loop is never stripped or reconstructed from visible thinking alone.

Non-thinking tool observations keep their existing turn-scoped behavior. Thinking history is retained only where needed for supported continuation; it inherits the originating execution's memory/source dependencies and sending policy. After memory forgetting or lifecycle invalidation, committed historical replies and their displayable reasoning remain locally visible with body-free invalidation tags, and the affected turn and its descendants are unavailable for future provider replay. Forget removes hidden tool messages, arguments, results, and tool-call identifiers; other lifecycle invalidations retain their original audit and trace data for historical inspection.

## Persistence and privacy

Schema v10 adds ordered `trace_json` to assistant drafts and messages and a `thinking_json` mirror to model routes. Step/attempt output and request snapshots also contain thinking. Checkpoints, terminal compare-and-swap, pending-save retry, process recovery and backup/restore preserve it. A partial thinking-only response is recoverable even when answer text is empty.

Thinking is model output, never user evidence for memory extraction. Extraction validates only the final answer JSON and accounts for the whole request's usage. Synthetic capability checks retain the selected thinking controls and output reservation; they cannot disable thinking just to pass a short probe.

Memory forgetting purges derived thinking from request/output snapshots, tool observations, audit caches, active drafts, and hidden tool portions of retained traces. Committed historical messages, replies, and displayable reasoning remain locally visible with body-free invalidation tags. Other lifecycle invalidations retain their original audit and trace data with tags. In both cases, affected history is omitted from rebuilt provider context, including transitive descendants; no model replay is attempted. Knowledge source deletion/revocation retains its separate generated-body purge contract. Normal logs and errors contain no thinking or opaque replay data. Old development schemas are rejected intact; there is no migration bridge or automatic deletion.

## Design references and extension boundary

LobeHub is a design reference, not a runtime dependency. Its [OpenAI-compatible factory](https://github.com/lobehub/lobehub/blob/canary/packages/model-runtime/src/core/openaiCompatibleFactory/index.ts) centralizes dispatch and stream handling while provider hooks own payload differences. Its [Moonshot adapter](https://github.com/lobehub/lobehub/blob/canary/packages/model-runtime/src/providers/moonshot/index.ts) and [model-family parser](https://github.com/lobehub/lobehub/blob/canary/packages/model-runtime/src/providers/moonshot/modelId.ts) keep Kimi-specific controls separate from the common transport. Its [model-bank types](https://github.com/lobehub/lobehub/blob/canary/packages/model-bank/src/types/aiModel.ts) separate model abilities and supported controls from provider enablement.

Mira follows those boundaries at its current scale: catalog metadata describes models; an explicit route policy selects wire controls; common bounded stream assemblers publish canonical answer, thinking, tool and usage events. Request encoding and continuation rules remain in MiraProviders. Pure configuration validation belongs to MiraCore and never imports vendor SDK types. The host reads these supported controls rather than maintaining a separate set of model checks. Extending a protocol requires payload, stream, continuation and failure fixtures together; a new catalog entry alone cannot add protocol support.

Provider activation, model discovery, pool membership, purpose eligibility and a successful live probe remain separate states. Mira currently preserves live model identifiers and overlays reviewed exact catalog metadata; it does not yet ingest every provider's live capability field. A future discovery increment may follow LobeHub's precedence of explicit live metadata, exact catalog match, then provider-scoped fallback rules. Models.dev remains advisory offline metadata.

## Protocol sources

- [DeepSeek thinking](https://api-docs.deepseek.com/guides/thinking_mode/): thinking toggle, effort and complete reasoning replay for requests carrying tools.
- [Kimi API](https://platform.kimi.ai/docs/api/chat): K2.6 preserved thinking with `keep: all` and mandatory K3 reasoning with effort and `max_completion_tokens`. [Model lifecycle](https://platform.kimi.ai/docs/models) takes precedence over stale catalog availability.
- [Anthropic thinking](https://platform.claude.com/docs/en/build-with-claude/thinking), [tool workflows](https://platform.claude.com/docs/en/build-with-claude/thinking-tool-workflows), and [preserved thinking](https://platform.claude.com/docs/en/build-with-claude/preserved-thinking): manual/adaptive controls, opaque signatures, exact active-turn replay and prefix constraints.
- [OpenRouter reasoning](https://openrouter.ai/docs/guides/best-practices/reasoning-tokens): gateway request controls and ordered reasoning details.
- [OpenAI Chat Completions](https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create): native reasoning effort and completion-token budget. Chat Completions does not expose the Responses reasoning-item workflow; Responses remains a separate adapter increment.

Synthetic and live acceptance evidence belongs in `docs/engineering`; catalog provenance remains in [MODEL_CATALOG.md](MODEL_CATALOG.md).
