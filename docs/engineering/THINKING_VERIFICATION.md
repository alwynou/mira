# First-class thinking verification

Historical evidence: the memory-forgetting behavior described below is superseded by [natural memory and retained-history verification](NATURAL_MEMORY_VERIFICATION.md). Current memory forgetting preserves committed visible replies with status tags and excludes them from future model context; source deletion remains a separate contract.

Date: 2026-09-06. Branch: `dev`. Owning contract: [Thinking and provider continuation](../architecture/THINKING.md). This increment replaces the schema-v9 reasoning-disabled policy; it does not assert that every catalog model has passed a live request.

## Delivered scope

- Explicit route policies cover DeepSeek, Kimi, native OpenAI Chat Completions, Anthropic manual/adaptive thinking, and OpenRouter. Thinking mode, effort and budget are frozen with each execution. The pool editor exposes reviewed controls and does not automatically disable reasoning to pass a probe. OpenRouter effort and token budgets are mutually exclusive.
- Common bounded stream assemblers expose separate answer/thinking events. Thinking appears in a collapsible, localized section using the existing streaming Markdown renderer. Only provider-returned visible text is displayed; signed, encrypted and redacted payloads remain opaque.
- Anthropic thinking/signature deltas, multiple content blocks and tool-use blocks are preserved in exact order. Missing signature/redacted continuation data fails before a runnable tool batch is exposed. DeepSeek/Kimi reasoning text and OpenRouter ordered details survive tool continuation. Duplicate visible aliases do not duplicate the displayed text.
- The active assistant/tool request prefix is frozen. The next user turn rebuilds context and follows the protocol-specific history boundary described in the contract. Route, endpoint, model and credential changes prevent transferring provider continuation material.
- Schema v10 persists complete assistant/tool traces with messages and drafts, including thinking-only interrupted output. Pending-save retry, restart recovery and backup/restore retain thinking. Memory/source purges clear persisted and affected live traces; reasoning cannot become user memory evidence.
- `ProviderThinkingRules` isolates payload differences from dispatch and SSE parsing, borrowing the narrow provider-policy seam used by LobeHub. The current catalog contains eight providers and 540 advisory references. Kimi K2.5 is excluded from native endpoint recommendations following its documented retirement. Protocol suggestions do not add unsupported reasoning controls to ordinary non-reasoning models.

## Parent acceptance

| Check | Evidence |
| --- | --- |
| Full package regression | **306 tests / 34 suites** passed, including one explicitly skipped opt-in M5 benchmark. `/private/tmp/mira-thinking-package-final.log` |
| App and hostless tests | Debug macOS app build and **16 Host tests** passed: five localization XCTest cases and eleven renderer/isolated Keychain Swift Testing cases. `/private/tmp/mira-thinking-host-final.log` |
| Catalog generator | **Five offline Python tests** passed: fixed credential destinations, units, reviewed protocol profiles, retired native models and malformed metadata. |
| Localization | English source policy, **1,129 bilingual keys**, format placeholders and compiler-extracted UI keys passed. |
| Catalog reproducibility | Generated resource matches the normalized output from the previously reviewed models.dev source bytes and `2026-09-06T04:49:05Z` retrieval timestamp. |

Implementation revision `8330cc641070d294c3c7a1e1f85f4cab4d40ed08` passed all clean macOS checks in [CI 34017194398](https://github.com/alwynou/mira/actions/runs/34017194398). The first CI run exposed incorrect reuse of a JSON encoder container when replaying Anthropic blocks on its Foundation runtime. The adapter now encodes each raw object through one keyed container; the exact ordered-block fixture passes both locally and in CI.

Provider fixtures verify default and explicit request controls; K3 completion-token naming; K2.6 preserved thinking; 600 ordered OpenRouter fragments with repeated IDs and bounded snapshots; multiple Anthropic signatures split across deltas; opaque redacted blocks; malformed continuation before tool exposure; interrupted reasoning; and exact replay bodies. Runtime fixtures verify frozen tool-turn prefixes, later-user-turn boundaries, route identity, partial cancellation, pending-save retry without redispatch, and source revocation after thinking is checkpointed. Data fixtures cover recovery, typed mirrors, backup audit tampering, purge, invalid budgets before commit and terminal uniqueness.

The parent reviewed delegated diffs, corrected the protocol fixtures and request mappings, and reran the complete acceptance commands after integration. No new Host files or targets were added; Swift package files are discovered automatically. Unrelated local icon/project changes were excluded from this increment's commit.

## Remaining evidence and development data

No real credentials or paid model endpoints were used. Live DeepSeek/Kimi/OpenAI/Anthropic/OpenRouter thinking, exact provider billing, multi-turn gateway signatures, model availability, tool quality and memory-extraction quality remain unverified. Native settings clicks, live language switching, the thinking disclosure during a real stream and VoiceOver interaction remain separate acceptance work. A macOS 15 deployment target and hostless tests do not establish macOS 15 runtime coverage.

OpenAI Responses reasoning items, gateway-specific all-turn context controls and richer live model capability discovery are separate adapter increments. Unrecognized/custom deployments retain explicit configuration and fail on incompatible controls; they do not silently fall back to another provider or disable thinking.

The existing schema-v9 preview library remains intact. The schema-v10 build requires a fresh development directory (or a current-format v10 backup); older data is rejected without conversion or deletion. The app was built but the user's earlier configured preview was not silently restarted against a different library. No public binary release, signing or notarization claim is made.
