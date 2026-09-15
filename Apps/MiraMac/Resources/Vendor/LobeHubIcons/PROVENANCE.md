# LobeHub provider and model icons

The vector assets use the official LobeHub static SVG package:

- Package: `@lobehub/icons-static-svg`
- Version: `1.95.0`
- License: MIT
- Source repository: https://github.com/lobehub/lobe-icons
- Package metadata: https://registry.npmjs.org/@lobehub/icons-static-svg/1.95.0
- CDN source: https://unpkg.com/@lobehub/icons-static-svg@1.95.0/icons/

The colored SVG paths retain their published fills. LobeHub's
published colored variants are used where available; otherwise the published
monochrome path data is retained and its `currentColor` fill is adapted to
explicit light/dark asset variants using the published neutral brand palette
for macOS appearance selection. No invented colors are added to the marks.

| Mira asset | Provider IDs | LobeHub file |
| --- | --- | --- |
| `ProviderOpenAI` | `openai` | `openai.svg` (light/dark adaptations) |
| `ProviderAnthropic` | `anthropic` | `anthropic.svg` with LobeHub palette adaptations |
| `ProviderDeepSeek` | `deepseek` | `deepseek-color.svg` |
| `ProviderMoonshot` | `kimi-for-coding`, `moonshotai-cn`, `moonshotai` | `moonshot.svg` (black/white appearance variants) |
| `ProviderOpenRouter` | `openrouter` | `openrouter-color.svg` |

At version 1.95.0, LobeHub publishes no `openai-color.svg` or
`anthropic-color.svg`. The React package `@lobehub/icons` 5.18.0 exports
`OpenAI.COLOR_PRIMARY = "#000"` and `Anthropic.COLOR_PRIMARY = "#F1F0E8"`
from its official `es/OpenAI/style.js` and `es/Anthropic/style.js`
metadata. OpenAI remains a black/white theme adaptation because its published
primary is neutral; Anthropic uses `#141413` in light mode and the published
`#F1F0E8` primary in dark mode.

## Moonshot shared service icon

At the user's request, Kimi Code and Moonshot use the same published Moonshot mark. The original `moonshot.svg` geometry is unchanged. Its `currentColor` fill becomes black (`#000000`) for light appearance and white (`#FFFFFF`) for dark appearance, selected by the asset catalog. No custom black enclosure or inset is added. The prior adapted `kimi.svg` is removed.

- Original: https://unpkg.com/@lobehub/icons-static-svg@1.95.0/icons/moonshot.svg
- Only the two required Moonshot SVG variants are stored in `ProviderMoonshot.imageset`; the complete icon library is not bundled.

## Model marks

`MiraModelIcon` maps the bundled model catalog's explicit provider IDs, explicit model IDs on custom proxies, and
OpenRouter vendor namespaces to model-family marks. These remain separate from
provider connection marks: an OpenRouter Claude model receives Claude while
the connection itself continues to use the OpenRouter mark.

| Mira asset | Catalog family | LobeHub file |
| --- | --- | --- |
| `ProviderOpenAI` (reused) | `openai`, `openai/*` | `openai.svg` |
| `ModelClaude` | Anthropic `claude-*`, `anthropic/claude*` | `claude-color.svg` |
| `ProviderDeepSeek` (reused) | DeepSeek IDs and `deepseek/*` | `deepseek-color.svg` |
| `ModelKimi` | Kimi/Moonshot IDs and `moonshotai/kimi*` | `kimi-color.svg` (adapted enclosure) |
| `ModelQwen` | `qwen/*` | `qwen-color.svg` |
| `ModelGemma` / `ModelGemini` | `google/gemma*` / `google/gemini*` | `gemma-color.svg` / `gemini-color.svg` |
| `ModelMeta` | `meta-llama/*` | `meta-color.svg` |
| `ModelMistral` | `mistralai/*` | `mistral-color.svg` |
| `ModelGrok` | `x-ai/grok*` | `grok.svg` (black/white appearance variants) |
| `ModelGLM` | `z-ai/glm*` | `zhipu-color.svg` |
| `ModelMiniMax`, `ModelCohere`, `ModelNova` | matching OpenRouter namespaces | matching `*-color.svg` |
| `ModelByteDance`, `ModelBaidu`, `ModelMicrosoft`, `ModelNvidia`, `ModelPerplexity` | matching OpenRouter namespaces | matching `*-color.svg` |
| `ModelHunyuan`, `ModelStepfun` | matching OpenRouter model families | `hunyuan-color.svg`, `stepfun-color.svg` |

Each SVG was fetched individually from the pinned package URL; unrelated
library assets are not bundled:
`https://unpkg.com/@lobehub/icons-static-svg@1.95.0/icons/`.

`ModelKimi.svg` adapts the published `kimi-color.svg` with a black rounded
24×24 enclosure and scales its original paths to 72% with a 14% inset, as
authorized for the white-path variant. Unknown or service-only IDs use Mira's
generic cube fallback.
