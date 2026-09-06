#!/usr/bin/env python3
"""Build Mira's bounded, advisory model catalog from a local models.dev JSON snapshot."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import math
import unicodedata
from pathlib import Path
from typing import Any

SOURCE_URL = "https://models.dev/api.json"
PROVIDER_ORDER = [
    "openai",
    "anthropic",
    "deepseek",
    "moonshotai-cn",
    "moonshotai",
    "siliconflow-cn",
    "siliconflow",
    "openrouter",
]
PROVIDER_KINDS = {"openai": "openAICompatible", "anthropic": "anthropic"}
PROVIDER_NAMES = {
    "moonshotai-cn": "Kimi / Moonshot (China)",
    "moonshotai": "Kimi / Moonshot (International)",
}
OFFICIAL_BASE_URLS = {
    "openai": "https://api.openai.com/v1",
    "anthropic": "https://api.anthropic.com/v1",
    "deepseek": "https://api.deepseek.com",
    "moonshotai-cn": "https://api.moonshot.cn/v1",
    "moonshotai": "https://api.moonshot.ai/v1",
    "siliconflow-cn": "https://api.siliconflow.cn/v1",
    "siliconflow": "https://api.siliconflow.com/v1",
    "openrouter": "https://openrouter.ai/api/v1",
}
OFFICIAL_PRICING_BASE_URLS = {
    **{provider_id: [base_url] for provider_id, base_url in OFFICIAL_BASE_URLS.items()},
    # The adapter accepts both forms for the native DeepSeek endpoint.
    "deepseek": ["https://api.deepseek.com", "https://api.deepseek.com/v1"],
}
OFFICIAL_DOCUMENTATION_URLS = {
    "openai": "https://developers.openai.com/api/reference/resources/models/methods/list",
    "anthropic": "https://platform.claude.com/docs/en/api/models/list",
}
MAX_INPUT_BYTES = 16 * 1024 * 1024
MAX_MODELS_PER_PROVIDER = 2_000
ANTHROPIC_ADAPTIVE_IDS = {
    "claude-sonnet-4-6", "claude-opus-4-6", "claude-opus-4-7", "claude-opus-4-8", "claude-sonnet-5",
    "claude-opus-5", "claude-fable-5", "claude-fable-5-1", "claude-mythos-5",
}


class CatalogInputError(ValueError):
    pass


def fail(message: str) -> None:
    raise CatalogInputError(message)


def text(value: Any, field: str, maximum: int = 300) -> str:
    if not isinstance(value, str) or not value or len(value) > maximum or any(unicodedata.category(c) == "Cc" for c in value):
        fail(f"invalid {field}")
    return value


def token(value: Any, field: str, maximum: int = 300) -> str:
    result = text(value, field, maximum)
    if any(c.isspace() for c in result):
        fail(f"invalid {field}")
    return result


def optional_text(value: Any, field: str, maximum: int = 300) -> str | None:
    if value is None:
        return None
    return text(value, field, maximum)


def optional_bool(value: Any, field: str) -> bool | None:
    if value is None:
        return None
    if not isinstance(value, bool):
        fail(f"invalid {field}")
    return value


def pricing_rate(value: Any, field: str) -> int | float:
    """Validate a models.dev USD/MTok rate without treating missing as zero."""
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        fail(f"invalid {field}")
    if value < 0 or value > 1_000_000:
        fail(f"invalid {field}")
    return value


def catalog_pricing(provider_id: str, model_id: str, raw: dict[str, Any], task: str) -> dict[str, Any] | None:
    """Keep only below-threshold text-token pricing supported by Mira's estimator.

    models.dev also publishes context tiers, reasoning-specific rates, audio
    rates and cache-write rates. Only the base tariff below the first verified
    context threshold is retained; the higher bands remain unsupported.
    """
    cost = raw.get("cost")
    if cost is None:
        return None
    if not isinstance(cost, dict):
        fail(f"invalid cost {provider_id}/{model_id}")
    input_rate = pricing_rate(cost.get("input"), f"input price {provider_id}/{model_id}")
    output_rate = pricing_rate(cost.get("output"), f"output price {provider_id}/{model_id}")
    for key in ("reasoning", "cache_read", "cache_write", "input_audio", "output_audio"):
        if key in cost:
            pricing_rate(cost[key], f"{key} price {provider_id}/{model_id}")
    tiers = cost.get("tiers")
    maximum_input_tokens: int | None = None
    if "tiers" in cost:
        if not isinstance(tiers, list):
            fail(f"invalid pricing tiers {provider_id}/{model_id}")
        tier_sizes: list[int] = []
        for index, tier in enumerate(tiers):
            if not isinstance(tier, dict):
                fail(f"invalid pricing tier {provider_id}/{model_id}/{index}")
            tier_info = tier.get("tier")
            if not isinstance(tier_info, dict) or tier_info.get("type") != "context":
                fail(f"invalid pricing tier {provider_id}/{model_id}/{index}")
            size = tier_info.get("size")
            if isinstance(size, bool) or not isinstance(size, int) or not 0 < size <= 10_000_000:
                fail(f"invalid pricing tier size {provider_id}/{model_id}/{index}")
            # CostTier has the same required/optional rates as Cost. Validate
            # them even though this increment does not apply higher bands.
            for key in ("input", "output"):
                pricing_rate(tier.get(key), f"tier {key} price {provider_id}/{model_id}/{index}")
            for key in ("reasoning", "cache_read", "cache_write", "input_audio", "output_audio"):
                if key in tier:
                    pricing_rate(tier[key], f"tier {key} price {provider_id}/{model_id}/{index}")
            tier_sizes.append(size)
        if len(set(tier_sizes)) != len(tier_sizes):
            fail(f"duplicate pricing tier size {provider_id}/{model_id}")
        if tier_sizes:
            # The tier size is the first token count at which the higher
            # tariff starts. Stop one token earlier to avoid pricing equality
            # at an unsupported boundary with the base rate.
            maximum_input_tokens = min(tier_sizes) - 1

    legacy = cost.get("context_over_200k")
    if "context_over_200k" in cost:
        if not isinstance(legacy, dict):
            fail(f"invalid legacy pricing tier {provider_id}/{model_id}")
        for key in ("input", "output"):
            pricing_rate(legacy.get(key), f"legacy {key} price {provider_id}/{model_id}")
        for key in ("reasoning", "cache_read", "cache_write", "input_audio", "output_audio"):
            if key in legacy:
                pricing_rate(legacy[key], f"legacy {key} price {provider_id}/{model_id}")
        # This field represents the legacy >200k band. Keep only its proven
        # base range, even when a modern tier list is also present.
        maximum_input_tokens = min(maximum_input_tokens or 199_999, 199_999)
    # Reasoning is a separate billable dimension in the upstream schema and
    # is not represented by Mira's current usage contract.
    if "reasoning" in cost:
        return None
    # This increment is text-generation only. Do not attach token prices to
    # non-text tasks or models carrying separate audio tariffs.
    if task != "textGeneration" or any(cost.get(key) is not None for key in ("input_audio", "output_audio")):
        return None
    # Cache-write rates are deliberately not copied into ModelPricing. The
    # runtime still prices calls with no reported writes; a positive reported
    # write count returns unsupportedCacheWrite instead of using this tariff.
    result = {
        "input": input_rate,
        "output": output_rate,
        "baseURLs": OFFICIAL_PRICING_BASE_URLS[provider_id],
    }
    if maximum_input_tokens is not None:
        if maximum_input_tokens < 1:
            return None
        result["maxInputTokens"] = maximum_input_tokens
    cache_read = cost.get("cache_read")
    if cache_read is not None:
        result["cacheRead"] = pricing_rate(cache_read, f"cache_read price {provider_id}/{model_id}")
    return result


def bounded_int(value: Any, field: str) -> int | None:
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, int):
        fail(f"invalid {field}")
    # models.dev uses zero for an unknown limit on non-text model families.
    if value == 0:
        return None
    if not 0 < value <= 10_000_000:
        fail(f"invalid {field}")
    return value


def modalities(value: Any, field: str) -> list[str]:
    if value is None:
        return []
    if not isinstance(value, list) or len(value) > 32:
        fail(f"invalid {field}")
    result = sorted({text(item, f"{field} item", 32) for item in value})
    return result


def suggested_mode(provider_id: str, model_id: str, raw: dict[str, Any], task: str = "textGeneration") -> str:
    # Provider protocol controls are only safe for models whose upstream
    # metadata explicitly advertises reasoning. Other models remain generic
    # OpenAI-compatible/Anthropic routes even when their provider supports a
    # thinking API.
    reasoning = raw.get("reasoning")
    if task != "textGeneration" or reasoning is not True:
        return "standard"
    if provider_id == "deepseek":
        return "deepSeek"
    if provider_id in {"moonshotai-cn", "moonshotai"}:
        return "kimi"
    if provider_id == "anthropic":
        return "anthropicAdaptive" if any(model_id == base or model_id.startswith(base + "-20") for base in ANTHROPIC_ADAPTIVE_IDS) else "anthropicManual"
    if provider_id == "openai":
        return "openAI"
    if provider_id == "openrouter":
        return "openRouter"
    return "standard"


def model_task(raw: dict[str, Any], output_modalities: list[str]) -> str:
    """Classify only from upstream family/modalities facts, never an ID guess."""
    family = raw.get("family")
    if family == "text-embedding":
        return "embedding"
    if family == "gpt-image":
        return "imageGeneration"
    if "audio" in output_modalities:
        return "audio"
    if "image" in output_modalities:
        return "imageGeneration"
    if "text" in output_modalities:
        return "textGeneration"
    return "unknown"


def normalize_model(provider_id: str, raw_id: str, raw: Any, source_revision: str, retrieved_at: str) -> dict[str, Any]:
    if not isinstance(raw, dict):
        fail(f"invalid model {provider_id}/{raw_id}")
    model_id = token(raw.get("id"), f"model id {provider_id}/{raw_id}")
    if model_id != raw_id:
        fail(f"model key/id mismatch {provider_id}/{raw_id}")
    limit = raw.get("limit")
    if not isinstance(limit, dict):
        fail(f"missing limit {provider_id}/{model_id}")
    modalities_value = raw.get("modalities")
    if not isinstance(modalities_value, dict):
        fail(f"missing modalities {provider_id}/{model_id}")
    input_modalities = modalities(modalities_value.get("input"), f"input modalities {provider_id}/{model_id}")
    output_modalities = modalities(modalities_value.get("output"), f"output modalities {provider_id}/{model_id}")
    task = model_task(raw, output_modalities)
    output_limit = bounded_int(limit.get("output"), f"output {provider_id}/{model_id}")
    interleaved = raw.get("interleaved")
    if isinstance(interleaved, bool):
        requires_continuation = interleaved
    elif interleaved is None:
        requires_continuation = False
    elif isinstance(interleaved, dict):
        field = interleaved.get("field")
        if not isinstance(field, str) or not field or len(field) > 100 or any(ord(c) < 32 or ord(c) == 127 for c in field):
            fail(f"invalid interleaved metadata {provider_id}/{model_id}")
        requires_continuation = True
    else:
        fail(f"invalid interleaved metadata {provider_id}/{model_id}")
    metadata = {
        "providerID": provider_id,
        "modelID": model_id,
        "displayName": optional_text(raw.get("name"), f"display name {provider_id}/{model_id}"),
        "sourceURL": SOURCE_URL,
        "sourceRevision": source_revision,
        "retrievedAt": retrieved_at,
        "contextWindow": bounded_int(limit.get("context"), f"context {provider_id}/{model_id}"),
        "maxOutputTokens": output_limit if task == "textGeneration" else None,
        "inputModalities": input_modalities,
        "outputModalities": output_modalities,
        "toolCall": optional_bool(raw.get("tool_call"), f"tool_call {provider_id}/{model_id}"),
        "structuredOutput": optional_bool(raw.get("structured_output"), f"structured_output {provider_id}/{model_id}"),
        "reasoning": optional_bool(raw.get("reasoning"), f"reasoning {provider_id}/{model_id}"),
        "requiresReasoningContinuation": requires_continuation,
        "task": task,
    }
    pricing = catalog_pricing(provider_id, model_id, raw, task)
    if pricing is not None:
        metadata["pricing"] = pricing
    return {
        "metadata": metadata,
        "suggestedProtocolMode": suggested_mode(provider_id, model_id, raw, task),
    }


def normalize(input_path: Path, retrieved_at: str) -> dict[str, Any]:
    try:
        retrieved = dt.datetime.fromisoformat(retrieved_at.replace("Z", "+00:00"))
    except ValueError as exc:
        fail(f"retrieved-at must be ISO-8601: {exc}")
    if retrieved.tzinfo is None:
        fail("retrieved-at must include a timezone")
    source_bytes = input_path.read_bytes()
    if len(source_bytes) > MAX_INPUT_BYTES:
        fail("input exceeds 16 MiB")
    try:
        source = json.loads(source_bytes)
    except json.JSONDecodeError as exc:
        fail(f"invalid JSON: {exc}")
    if not isinstance(source, dict):
        fail("top-level source must be an object")
    source_revision = "sha256:" + hashlib.sha256(source_bytes).hexdigest()
    providers: list[dict[str, Any]] = []
    for provider_id in PROVIDER_ORDER:
        raw = source.get(provider_id)
        if not isinstance(raw, dict):
            fail(f"missing provider {provider_id}")
        if raw.get("id") != provider_id:
            fail(f"provider key/id mismatch {provider_id}")
        raw_models = raw.get("models")
        if not isinstance(raw_models, dict) or not raw_models:
            fail(f"missing models {provider_id}")
        if len(raw_models) > MAX_MODELS_PER_PROVIDER:
            fail(f"too many models {provider_id}")
        api = OFFICIAL_BASE_URLS[provider_id]
        upstream_documentation = text(raw.get("doc"), f"documentation URL {provider_id}", 500)
        if not upstream_documentation.startswith("https://"):
            fail(f"documentation URL must use HTTPS {provider_id}")
        documentation = OFFICIAL_DOCUMENTATION_URLS.get(provider_id, upstream_documentation)
        # K2.5 was retired on 2026-08-31 according to Kimi's official lifecycle.
        # Keep stale upstream records out of new-model recommendations.
        models = [normalize_model(provider_id, model_id, raw_model, source_revision, retrieved_at)
                  for model_id, raw_model in raw_models.items()
                  if not (provider_id in {"moonshotai", "moonshotai-cn"} and model_id == "kimi-k2.5")]
        models.sort(key=lambda model: model["metadata"]["modelID"])
        provider_name = PROVIDER_NAMES.get(provider_id)
        if provider_name is None:
            provider_name = text(raw.get("name"), f"provider name {provider_id}", 100)
        providers.append({
            "id": provider_id,
            "name": provider_name,
            "baseURL": api,
            "documentationURL": documentation,
            "providerKind": PROVIDER_KINDS.get(provider_id, "openAICompatible"),
            "models": models,
        })
    return {"providers": providers}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--retrieved-at", required=True)
    parser.add_argument("--output", type=Path, default=Path("Packages/MiraKit/Sources/MiraProviders/Resources/ModelCatalog.json"))
    args = parser.parse_args()
    try:
        document = normalize(args.input, args.retrieved_at)
    except CatalogInputError as exc:
        parser.error(str(exc))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(document, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
