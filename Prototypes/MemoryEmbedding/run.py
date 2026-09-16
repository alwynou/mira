#!/usr/bin/env python3
"""Build and execute the isolated native prototype, sequentially per checkpoint."""

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
PROJECT = Path(__file__).resolve().parent
WORK = ROOT / ".build/memory-embedding"


def command(args, log):
    print("Running " + " ".join(map(str, args)), flush=True)
    with log.open("w") as output:
        subprocess.run(list(map(str, args)), cwd=ROOT, stdout=output, stderr=subprocess.STDOUT, check=True)


def summarize(reports):
    summary = {}
    for model in reports:
        report = json.loads((WORK / f"{model}.json").read_text())
        answerable = [q for q in report["queries"] if q["expected"]]
        quality = {}
        for method in ["lexical", "semantic", "hybrid"]:
            for k in [1, 6]:
                hits = sum(bool(set(q["expected"]) & {hit["id"] for hit in q[method][:k]}) for q in answerable)
                quality[f"{method}HitAt{k}"] = {"hits": hits, "queries": len(answerable)}
        summary[model] = {
            **{key: report[key] for key in ["model", "operatingSystem", "physicalMemoryBytes", "metalDeviceName", "modelLoadMs", "firstInferenceMs", "warmQueryTiming", "scan10KTiming",
                "sqlite10KReadMs", "sqlite10KBytes", "mlxPeakActiveBytes", "mlxActiveBytes", "mlxCacheBytes", "processPeakRSSBytes",
                "batchMinimumCosine", "batchMaximumAbsoluteError", "normMaximumError", "publicReferenceScores",
                "publicReferenceMaximumError", "checks", "batches"]},
            "quality": quality,
            "misses": {method: [q["id"] for q in answerable if not set(q["expected"]) & {hit["id"] for hit in q[method]}]
                       for method in ["lexical", "semantic", "hybrid"]},
            "noAnswerTopScores": {q["id"]: q["semantic"][0]["score"] for q in report["queries"] if not q["expected"]},
        }
    if "4bit" in reports and "bf16" in reports:
        a = json.loads((WORK / "4bit.json").read_text())
        b = json.loads((WORK / "bf16.json").read_text())
        def cosine(x, y):
            return sum(v*w for v, w in zip(x, y)) / (sum(v*v for v in x) * sum(w*w for w in y))**0.5
        similarities = [cosine(x, y) for x, y in zip(a["documentVectors"], b["documentVectors"])]
        summary["comparison"] = {
            "documentCosineMinimum": min(similarities),
            "documentCosineMean": sum(similarities) / len(similarities),
            "semanticTop1Agreement": sum(x["semantic"][0]["id"] == y["semantic"][0]["id"] for x, y in zip(a["queries"], b["queries"])),
            "queries": len(a["queries"]),
        }
    summary["fixtureSHA256"] = hashlib.sha256((PROJECT / "Fixtures/recall.json").read_bytes()).hexdigest()
    (WORK / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", choices=["all", "4bit", "bf16"], default="all")
    parser.add_argument("--skip-download", action="store_true")
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--summarize-only", action="store_true")
    args = parser.parse_args()
    WORK.mkdir(parents=True, exist_ok=True)
    names = ["4bit", "bf16"] if args.model == "all" else [args.model]
    if not args.summarize_only:
        if not args.skip_download:
            command([sys.executable, PROJECT / "download_models.py", "--root", WORK / "models", "--model", args.model], WORK / "download.log")
        if not args.skip_build:
            command(["xcodegen", "generate", "--spec", PROJECT / "project.yml"], WORK / "generate.log")
            command(["xcodebuild", "-project", PROJECT / "MemoryEmbeddingPrototype.xcodeproj", "-scheme", "MemoryEmbeddingPrototype",
                "-configuration", "Release", "-destination", "platform=macOS,arch=arm64", "-derivedDataPath", WORK / "xcode",
                "-onlyUsePackageVersionsFromResolvedFile", "CODE_SIGNING_ALLOWED=NO", "build"], WORK / "build.log")
        binary = WORK / "xcode/Build/Products/Release/MemoryEmbeddingPrototype"
        failed = []
        for name in names:
            output = WORK / f"{name}.json"
            output.unlink(missing_ok=True)
            try:
                command([binary, WORK / "models" / name, PROJECT / "Fixtures/recall.json", output, WORK / "temporary"], WORK / f"{name}.log")
            except subprocess.CalledProcessError:
                if not output.exists():
                    raise
                failed.append(name)
        summarize(names)
        if failed:
            raise SystemExit("Prototype gates failed for: " + ", ".join(failed) + "; inspect summary.json and model logs")
        raise SystemExit(0)
    summarize(names)
