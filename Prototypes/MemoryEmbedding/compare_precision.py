#!/usr/bin/env python3
"""Counterbalanced offline precision experiment with frozen labels and ranking."""

import argparse
import hashlib
import json
import math
from pathlib import Path
import random
import statistics
import subprocess

ROOT = Path(__file__).resolve().parents[2]
PROJECT = Path(__file__).resolve().parent
WORK = ROOT / ".build/memory-embedding/precision"
CORPUS = PROJECT / "Fixtures/precision-comparison.json"
ORDER = ["4bit-1", "bf16-1", "bf16-2", "4bit-2"]


def metrics(query, method):
    expected = set(query["expected"])
    ids = [x["id"] for x in query[method]][:6]
    hits = expected & set(ids)
    ranks = [i + 1 for i, item in enumerate(ids) if item in expected]
    dcg = sum(1 / math.log2(rank + 1) for rank in ranks)
    ideal = sum(1 / math.log2(i + 2) for i in range(min(len(expected), 6)))
    return {"hit1": int(ids[0] in expected) if ids else 0, "hit6": int(bool(hits)),
            "recall6": len(hits) / len(expected), "allFacts6": int(hits == expected),
            "mrr6": 1 / min(ranks) if ranks else 0, "ndcg6": dcg / ideal}


def timing(values):
    ordered = sorted(values)
    return {"samples": len(values), "p50Ms": statistics.median(values),
            "p95Ms": ordered[math.ceil(len(values) * 0.95) - 1], "maxMs": max(values)}


def summarize():
    reports = {name: json.loads((WORK / f"{name}.json").read_text()) for name in ORDER}
    metadata = json.loads((WORK / "metadata.json").read_text())
    fixture_hash = hashlib.sha256(CORPUS.read_bytes()).hexdigest()
    dataset = json.loads(CORPUS.read_text())
    assert metadata["fixtureSHA256"] == fixture_hash, "Fixture changed after the experiment"
    for label, report in reports.items():
        model = label.rsplit("-", 1)[0]
        assert report["model"]["revision"] == metadata["modelManifests"][model]["revision"]
        assert report["documentCount"] == len(dataset["memories"])
        assert len(report["queries"]) == len(dataset["queries"])
        for measured, expected in zip(report["queries"], dataset["queries"]):
            assert all(measured[key] == expected[key] for key in ["id", "category", "expected"])
    output = {"fixtureSHA256": fixture_hash, "runOrder": ORDER, "metadata": metadata, "models": {}}
    for model in ["4bit", "bf16"]:
        first, second = reports[f"{model}-1"], reports[f"{model}-2"]
        answerable = [q for q in first["queries"] if q["expected"]]
        quality = {}
        for method in ["semantic", "hybrid", "lexical"]:
            per_query = [metrics(q, method) for q in answerable]
            quality[method] = {metric: statistics.mean(q[metric] for q in per_query) for metric in per_query[0]}
            quality[method]["firstHits"] = sum(q["hit1"] for q in per_query)
            quality[method]["hit6Count"] = sum(q["hit6"] for q in per_query)
            quality[method]["allFacts6Count"] = sum(q["allFacts6"] for q in per_query)
        categories = sorted({q["category"] for q in answerable})
        groups = {c: {metric: statistics.mean(metrics(q, "semantic")[metric] for q in answerable if q["category"] == c)
                      for metric in ["hit1", "recall6", "ndcg6"]} for c in categories}
        stable = all([h["id"] for h in a["semantic"][:6]] == [h["id"] for h in b["semantic"][:6]]
                     for a, b in zip(first["queries"], second["queries"]))
        batch = []
        for a, b in zip(first["batches"], second["batches"]):
            batch.append({"kind": a["kind"], "count": a["count"], "tokenCounts": a["tokenCounts"],
                          "indexP50MsRuns": [a["indexTiming"]["p50Ms"], b["indexTiming"]["p50Ms"]],
                          "combinedP95MsRuns": [a["combinedTiming"]["p95Ms"], b["combinedTiming"]["p95Ms"]]})
        output["models"][model] = {
            "quality": quality, "answerableQueries": len(answerable), "groups": groups, "stableTop6AcrossRuns": stable,
            "queryTiming": timing([q["embeddingMs"] for r in [first, second] for q in r["queries"]]),
            "tokenRange": [min(q["tokenCount"] for q in first["queries"]), max(q["tokenCount"] for q in first["queries"])],
            "loadMsRuns": [first["loadMs"], second["loadMs"]], "indexMsRuns": [first["documentIndexMs"], second["documentIndexMs"]],
            "memory": [{k: r[k] for k in ["normalActiveBytes", "normalCacheBytes", "normalPeakActiveBytes",
                "normalProcessResidentBytes", "clearedActiveBytes", "clearedCacheBytes", "clearedProcessResidentBytes", "finalPeakActiveBytes"]} for r in [first, second]],
            "batches": batch,
            "noAnswerScores": {q["id"]: q["semantic"][0]["score"] for q in first["queries"] if not q["expected"]},
            "queryResults": [{"id": q["id"], "category": q["category"], "expected": q["expected"],
                "expectedRanks": q["expectedRanks"], "expectedScores": q["expectedScores"],
                "semantic": [h["id"] for h in q["semantic"][:6]], "topScore": q["semantic"][0]["score"],
                "hybrid": [h["id"] for h in q["hybrid"][:6]]} for q in first["queries"]],
        }
    a, b = reports["4bit-1"]["queries"], reports["bf16-1"]["queries"]
    output["disagreements"] = [{"id": x["id"], "expected": x["expected"],
        "4bitRanks": x["expectedRanks"], "bf16Ranks": y["expectedRanks"],
        "4bitTop1": x["semantic"][0]["id"], "bf16Top1": y["semantic"][0]["id"]}
        for x, y in zip(a, b) if x["expected"] and
        (x["expectedRanks"] != y["expectedRanks"] or x["semantic"][0]["id"] != y["semantic"][0]["id"])]
    pairs = [(metrics(x, "semantic"), metrics(y, "semantic")) for x, y in zip(a, b) if x["expected"]]
    output["pairedDifference4bitMinusBF16"] = {
        metric: statistics.mean(x[metric] - y[metric] for x, y in pairs) for metric in pairs[0][0]}
    # Paired resampling describes this authored set only, not population non-inferiority.
    generator = random.Random(20260916)
    bootstrap = []
    differences = [x["recall6"] - y["recall6"] for x, y in pairs]
    for _ in range(5000):
        bootstrap.append(statistics.mean(generator.choices(differences, k=len(differences))))
    bootstrap.sort()
    output["pairedQueryBootstrapRecall6Difference95Percent"] = [bootstrap[125], bootstrap[4874]]
    (WORK / "summary.json").write_text(json.dumps(output, indent=2) + "\n")
    print(json.dumps({"quality": {k: v["quality"] for k, v in output["models"].items()},
                      "difference": output["pairedDifference4bitMinusBF16"],
                      "disagreements": output["disagreements"]}, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--summarize-only", action="store_true")
    args = parser.parse_args()
    WORK.mkdir(parents=True, exist_ok=True)
    if not args.summarize_only:
        dataset = json.loads(CORPUS.read_text())
        ids = {m["id"] for m in dataset["memories"]}
        assert len(ids) == len(dataset["memories"])
        assert all(set(q["expected"]) <= ids for q in dataset["queries"])
        metadata = {"fixtureSHA256": hashlib.sha256(CORPUS.read_bytes()).hexdigest(),
                    "memories": len(ids), "queries": len(dataset["queries"]), "runOrder": ORDER,
                    "networkDenied": True, "mlXCacheLimitBytes": 128 * 1024 * 1024,
                    "modelManifests": {name: json.loads((WORK.parent / "models" / name / "prototype-manifest.json").read_text()) for name in ["4bit", "bf16"]}}
        (WORK / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
        binary = WORK.parent / "xcode/Build/Products/Release/MemoryEmbeddingPrototype"
        for label in ORDER:
            model = label.rsplit("-", 1)[0]
            print("Running " + label, flush=True)
            output = WORK / f"{label}.json"
            output.unlink(missing_ok=True)
            command = ["/usr/bin/sandbox-exec", "-p", "(version 1)(allow default)(deny network*)",
                str(binary), str(WORK.parent / "models" / model), str(CORPUS), str(output), str(WORK / "temporary"), "--compare"]
            with (WORK / f"{label}.log").open("w") as log:
                subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, check=True)
        assert metadata["fixtureSHA256"] == hashlib.sha256(CORPUS.read_bytes()).hexdigest()
    summarize()
