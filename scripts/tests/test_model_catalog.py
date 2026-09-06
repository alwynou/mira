"""Exercise source-data trust boundaries without network access."""

import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location(
    "catalog_generator", Path(__file__).resolve().parents[1] / "update_model_catalog.py"
)
catalog = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(catalog)


def model(model_id="fixture", **changes):
    value = {
        "id": model_id, "name": "Fixture", "family": "fixture",
        "limit": {"context": 8192, "output": 1024},
        "modalities": {"input": ["text"], "output": ["text"]},
    }
    value.update(changes)
    return value


class ModelCatalogGeneratorTests(unittest.TestCase):
    def test_downloaded_endpoint_cannot_redirect_a_template(self):
        source = {
            provider_id: {
                "id": provider_id, "name": "Fixture",
                "api": "https://untrusted.example/collect-credentials",
                "doc": "https://documentation.example/models",
                "models": {"fixture": model()},
            }
            for provider_id in catalog.PROVIDER_ORDER
        }
        source_bytes = json.dumps(source).encode()
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "source.json"
            path.write_bytes(source_bytes)
            normalized = catalog.normalize(path, "2026-09-06T04:49:05Z")
        for provider in normalized["providers"]:
            self.assertEqual(provider["baseURL"], catalog.OFFICIAL_BASE_URLS[provider["id"]])
            self.assertEqual(
                provider["models"][0]["metadata"]["sourceRevision"],
                "sha256:" + hashlib.sha256(source_bytes).hexdigest(),
            )

    def test_embedding_dimensions_never_become_chat_token_limits(self):
        raw = model("text-embedding-3-small", family="text-embedding",
                    limit={"context": 8191, "output": 1536})
        normalized = catalog.normalize_model("openai", raw["id"], raw, "fixture", "2026-09-06T00:00:00Z")
        self.assertEqual(normalized["metadata"]["task"], "embedding")
        self.assertIsNone(normalized["metadata"]["maxOutputTokens"])

    def test_flat_text_pricing_preserves_usd_rates_and_exact_endpoints(self):
        raw = model("deepseek-chat", cost={
            "input": 0.14, "output": 0.28, "cache_read": 0.0028,
        })
        normalized = catalog.normalize_model("deepseek", raw["id"], raw, "fixture", "2026-09-06T00:00:00Z")
        pricing = normalized["metadata"]["pricing"]
        self.assertEqual(pricing["input"], 0.14)
        self.assertEqual(pricing["output"], 0.28)
        self.assertEqual(pricing["cacheRead"], 0.0028)
        self.assertEqual(pricing["baseURLs"], [
            "https://api.deepseek.com", "https://api.deepseek.com/v1",
        ])
        self.assertNotIn("maxInputTokens", pricing)
        self.assertNotIn("effectiveAt", pricing)

    def test_unsupported_pricing_dimensions_are_omitted(self):
        cases = [
            {"input": 1, "output": 2, "reasoning": 0.5},
            {"input": 1, "output": 2, "reasoning": 0},
            {"input": 1, "output": 2, "input_audio": 0.5},
        ]
        for cost in cases:
            with self.subTest(cost=cost):
                raw = model(cost=cost)
                normalized = catalog.normalize_model("fixture", "fixture", raw, "fixture", "2026-09-06T00:00:00Z")
                self.assertNotIn("pricing", normalized["metadata"])

    def test_context_tiers_scope_base_pricing_one_token_below_first_boundary(self):
        raw = model(cost={
            "input": 1, "output": 2,
            "tiers": [
                {"input": 3, "output": 4, "tier": {"type": "context", "size": 200000}},
                {"input": 5, "output": 6, "tier": {"type": "context", "size": 400000}},
            ],
        })
        normalized = catalog.normalize_model("openai", "fixture", raw, "fixture", "2026-09-06T00:00:00Z")
        self.assertEqual(normalized["metadata"]["pricing"]["maxInputTokens"], 199999)

        legacy = model(cost={"input": 1, "output": 2, "context_over_200k": {"input": 3, "output": 4}})
        normalized = catalog.normalize_model("openai", "fixture", legacy, "fixture", "2026-09-06T00:00:00Z")
        self.assertEqual(normalized["metadata"]["pricing"]["maxInputTokens"], 199999)

    def test_malformed_context_tiers_are_rejected(self):
        for tiers in (
            [{"input": 3, "output": 4, "tier": {"type": "tokens", "size": 200000}}],
            [{"input": 3, "output": 4, "tier": {"type": "context", "size": 0}}],
            [{"input": 3, "output": 4, "tier": {"type": "context", "size": True}}],
            [{"input": 3, "output": 4, "tier": {"type": "context", "size": 10_000_001}}],
            [{"input": 3, "output": 4, "tier": {"type": "context", "size": 200000}},
             {"input": 5, "output": 6, "tier": {"type": "context", "size": 200000}}],
        ):
            with self.subTest(tiers=tiers), self.assertRaises(catalog.CatalogInputError):
                catalog.normalize_model("openai", "fixture", model(cost={"input": 1, "output": 2, "tiers": tiers}), "fixture", "2026-09-06T00:00:00Z")

    def test_cache_write_rate_is_omitted_but_flat_pricing_remains_available(self):
        raw = model(cost={"input": 1, "output": 2, "cache_read": 0.1, "cache_write": 0.5})
        normalized = catalog.normalize_model("openai", "fixture", raw, "fixture", "2026-09-06T00:00:00Z")
        self.assertEqual(normalized["metadata"]["pricing"], {
            "input": 1, "output": 2, "cacheRead": 0.1,
            "baseURLs": ["https://api.openai.com/v1"],
        })

    def test_pricing_rates_reject_missing_negative_boolean_and_nonfinite_values(self):
        for cost in (
            {"output": 1},
            {"input": 1, "output": -1},
            {"input": True, "output": 1},
            {"input": float("nan"), "output": 1},
        ):
            with self.subTest(cost=cost), self.assertRaises(catalog.CatalogInputError):
                catalog.normalize_model("fixture", "fixture", model(cost=cost), "fixture", "2026-09-06T00:00:00Z")

    def test_protocol_suggestions_require_reasoning_and_match_provider_contracts(self):
        self.assertEqual(catalog.suggested_mode("moonshotai", "kimi-k3", {"reasoning": True}), "kimi")
        self.assertEqual(catalog.suggested_mode("moonshotai-cn", "kimi-k2.7-code", {"reasoning": True}), "kimi")
        self.assertEqual(catalog.suggested_mode("moonshotai", "kimi-k2.6", {"reasoning": True}), "kimi")
        self.assertEqual(catalog.suggested_mode("deepseek", "deepseek-v4-flash", {"reasoning": True}), "deepSeek")
        self.assertEqual(catalog.suggested_mode("custom", "kimi-k2.6", {"reasoning": True}), "standard")
        self.assertEqual(catalog.suggested_mode("openai", "gpt-4", {"reasoning": False}), "standard")
        for model_id in ("claude-opus-5", "claude-fable-5", "claude-fable-5-1", "claude-sonnet-4-6-20260217"):
            self.assertEqual(catalog.suggested_mode("anthropic", model_id, {"reasoning": True}), "anthropicAdaptive")

    def test_retired_kimi_model_is_not_recommended_on_native_endpoints(self):
        source = {provider_id: {
            "id": provider_id, "name": "Fixture", "doc": "https://documentation.example/models",
            "models": {"kimi-k2.5": model("kimi-k2.5", reasoning=True)},
        } for provider_id in catalog.PROVIDER_ORDER}
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "source.json"
            path.write_text(json.dumps(source))
            normalized = catalog.normalize(path, "2026-09-06T04:49:05Z")
        for provider in normalized["providers"]:
            self.assertEqual(len(provider["models"]), 0 if provider["id"] in {"moonshotai", "moonshotai-cn"} else 1)

    def test_boolean_limits_and_malformed_continuations_are_rejected(self):
        for value in (False, True, -1, 10_000_001, "8192"):
            with self.subTest(value=value), self.assertRaises(catalog.CatalogInputError):
                catalog.bounded_int(value, "context")
        for interleaved in ({}, {"field": ""}, "reasoning_content"):
            raw = model(interleaved=interleaved)
            with self.subTest(interleaved=interleaved), self.assertRaises(catalog.CatalogInputError):
                catalog.normalize_model("fixture", "fixture", raw, "fixture", "2026-09-06T00:00:00Z")


if __name__ == "__main__":
    unittest.main()
