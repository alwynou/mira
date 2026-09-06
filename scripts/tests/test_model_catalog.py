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
