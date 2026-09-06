# Model catalog and purpose selection

The catalog is reference data. Provider activation, account availability, applied model configuration and probe observations are separate facts.

## Sources and matching

Mira bundles a reviewed subset of [models.dev's provider catalog](https://models.dev/api.json). Its [source repository](https://github.com/anomalyco/models.dev) maintains model facts and provider-specific serving facts separately. The bundled snapshot records the input SHA-256, source URL and retrieval date. Updating the snapshot is a development operation; opening Settings never contacts models.dev.

The first templates are OpenAI, Anthropic, DeepSeek, Kimi / Moonshot China and international, SiliconFlow China and international, and OpenRouter. Protocol/authentication requirements define this scope. LobeHub's much larger provider registry is a reference, not a claim that Mira implements every provider adapter.

Metadata joins use a registered protocol plus exact normalized service endpoint and exact model ID. Display names, substrings, similarly named models and custom proxy origins cannot select an official catalog. Regions are distinct. User-supplied endpoints and credentials never come from downloaded metadata.

Explicit provider discovery remains a bounded, cancellable request to that connection's `/models` endpoint. It supplies IDs and optional display names, not account-independent capability proof. Saved models, remote discoveries and bundled entries appear separately; duplicate IDs are not offered twice. Catalog models may be unavailable to an account; manually entered deployment IDs remain supported.

## Applied references and overrides

`ModelCatalogMetadata` contains provider/model identity, display name, source URL/revision/date, model task, context/output limits, input/output modalities, tool-call, structured-output, reasoning and continuation hints. No model descriptions or prompts are imported. Pricing is outside this increment and is not used for billing estimates.

New exact matches prefill reviewable context/output settings, text/tool declarations and the reviewed protocol mode. Saving is explicit. Existing descriptors are never silently refreshed. Apply Catalog Suggestions replaces the editor's suggestions and resets the extraction declaration. Applying or removing metadata invalidates previous probe observations when saved.

An applied reference constrains output size and excludes non-generation tasks and advertised non-text modalities. This separate task check matters because some upstream embedding entries advertise text input/output and list embedding dimensions as output limits; those values must not become chat output budgets. These are conservative configuration restrictions, not successful probe observations. Users can clear the reference and confirm their deployment's values manually. Capability states remain `unknown`, `declared`, `verified` or `failed`; catalog metadata never writes `verified`. Provider credential/endpoint/protocol changes make text, tools and extraction stale. Historical snapshots retain their original metadata and restrictions.

## Thinking capability and request controls

[Thinking and provider continuation](THINKING.md) owns the first-class reasoning contract. Catalog suggestions select a wire policy for supported interfaces; they never force thinking off to bypass an incomplete parser. Mode, effort and budget are saved on the selected route and frozen for an execution. Model-specific mandatory thinking and supported controls are validated separately from text/tool/extraction declarations.

## Eligibility and verification

`modelPool` lists enabled models with enabled connections and persisted canonical routes for management. `models(for:)` adds the following requirements:

| Use | Requirements |
| --- | --- |
| Conversation | Current declared/verified streaming text, valid context/output budget, supported protocol and applied catalog restrictions |
| Agent tools | Conversation requirements plus current declared/verified tool-call capability |
| Memory extraction | Conversation requirements plus current declared/verified JSON extraction capability |

The persisted routing purposes remain conversation and memory extraction. Agent tools is an eligibility filter for the existing conversation runtime, not a new background job or implicit default. Native strict structured output is optional because the extraction worker consumes JSON text with deterministic local validation. Embeddings, image generation, vision input, speech and compact selectors are introduced only with their features.

Conversation and default-purpose pickers use eligible candidates. A previously selected incompatible model remains visibly unavailable; no fallback is selected. The resolver and provider recheck the configuration independently of the UI.

Text, tools and JSON extraction have separate synthetic probes. The JSON probe requires the exact requested object, a complete stop and no tool calls; plain text, extra fields, Markdown fences and truncated output fail. It sends no conversation history and changes only extraction capability after the frozen configuration check. Passing this probe does not certify extraction quality on real conversations. Cancellation and stale results cannot certify any capability.

## Reference boundary

LobeHub maintains [built-in model cards and loader hooks](https://github.com/lobehub/lobehub/blob/main/packages/model-bank/src/aiModels/index.ts), a [provider registry](https://github.com/lobehub/lobehub/blob/main/packages/model-bank/src/modelProviders/index.ts), and separate runtime discovery. The inspected model-bank paths do not directly reference models.dev; this is not a repository-wide absence claim. Mira uses models.dev as its own reviewed metadata source and retains independent native contracts.
