#!/usr/bin/env python3
"""Measure synthetic journal storage in fresh processes with an explicitly warm OS cache.

Build first: swift build --package-path Packages/MiraKit -c release --product MiraScaleProbe
This measures storage or the Core application runtime, not native application launch or OS-cold disk access.
"""

import argparse
import hashlib
import json
import math
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile
import time


def run(probe, *arguments):
    started = time.perf_counter()
    result = subprocess.run([str(probe), *map(str, arguments)], check=True, text=True, stdout=subprocess.PIPE)
    value = json.loads(result.stdout)
    value["processWallMs"] = (time.perf_counter() - started) * 1000
    return value


def footprint(root):
    groups = {}
    for path in root.rglob("*"):
        if not path.is_file():
            continue
        relative = path.relative_to(root)
        group = str(Path(*relative.parts[:2])) if relative.parts[0] == "Sessions" else relative.parts[0]
        entry = groups.setdefault(group, {"bytes": 0, "files": 0, "allocatedBytes": 0})
        stat = path.stat()
        entry["bytes"] += stat.st_size
        entry["allocatedBytes"] += stat.st_blocks * 512
        entry["files"] += 1
    return groups


def p95(values):
    return sorted(values)[math.ceil(len(values) * 0.95) - 1]


def save(path, report):
    stage = path.with_suffix(".writing")
    stage.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    stage.replace(path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--probe", type=Path, default=Path("Packages/MiraKit/.build/release/MiraScaleProbe"))
    parser.add_argument("--sessions", type=int, nargs="+", default=[10, 100, 1000])
    parser.add_argument("--existing-corpus", type=Path, action="append", default=[],
                        help="Measure an existing synthetic corpus; it is never deleted by this invocation.")
    parser.add_argument("--samples", type=int, default=30)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--keep-corpus", action="store_true")
    parser.add_argument("--operation", choices=["read", "runtime"], default="read",
                        help="Runtime measures real Core startup on settled sessions; it omits projection rebuild/read.")
    args = parser.parse_args()
    if args.samples < 30 or any(count < 1 or count > 1000 for count in args.sessions):
        parser.error("Use at least 30 samples and 1...1000 sessions per corpus.")
    probe = args.probe.resolve(strict=True)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    report = {
        "format": "mira-session-scale-measurement-v1",
        "timestampUTC": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "gitCommit": subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip(),
        "os": platform.platform(),
        "cpu": subprocess.check_output(["sysctl", "-n", "machdep.cpu.brand_string"], text=True).strip(),
        "memoryBytes": int(subprocess.check_output(["sysctl", "-n", "hw.memsize"], text=True)),
        "toolchain": subprocess.check_output(["swift", "--version"], text=True).strip(),
        "probeSHA256": hashlib.sha256(probe.read_bytes()).hexdigest(),
        "build": "SwiftPM release; record dirty source revisions separately",
        "cache": "new process per sample; warm OS filesystem cache; no purge or native UI measurement",
        "warmups": 5,
        "operation": args.operation,
        "projectionRebuildIncluded": args.operation == "read",
        "corpora": [],
    }
    targets = []
    for root in args.existing_corpus:
        manifest = json.loads((root / "scale.json").read_text())
        if manifest.get("format") != "mira-session-scale-v1" or not 1 <= manifest.get("sessions", 0) <= 1000:
            parser.error("Existing paths must contain a valid synthetic scale corpus manifest.")
        targets.append((manifest["sessions"], root.resolve()))
    if not targets:
        targets = [(count, None) for count in args.sessions]
    for count, existing in targets:
        container = None if existing else Path(tempfile.mkdtemp(prefix="mira-session-scale-"))
        root = existing or container / "corpus"
        corpus = {"sessions": count, "messages": count * 100, "directory": str(root), "samples": [], "warmupSamples": []}
        report["corpora"].append(corpus)
        try:
            if existing:
                print(f"Reusing {count * 100} synthetic messages at {root}", flush=True)
            else:
                print(f"Seeding {count * 100} messages in {count} sessions at {root}", flush=True)
                corpus["seed"] = run(probe, "seed", root, count)
            corpus["afterSeed"] = footprint(root)
            if args.operation == "read":
                corpus["rebuild"] = run(probe, "rebuild", root)
                corpus["afterRebuild"] = footprint(root)
            save(args.output, report)
            for index in range(5 + args.samples):
                result = run(probe, args.operation, root)
                if index >= 5:
                    corpus["samples"].append(result)
                else:
                    corpus["warmupSamples"].append(result)
                save(args.output, report)
                ready_key = "localStoreReady" if args.operation == "read" else "runtimeReady"
                print(f"{count * 100} messages, {'warmup' if index < 5 else 'sample'} {index + 1}: "
                      f"{ready_key} {result['milliseconds'][ready_key]:.2f} ms", flush=True)
            corpus["p95Milliseconds"] = {
                key: p95([sample["milliseconds"][key] for sample in corpus["samples"]])
                for key in corpus["samples"][0]["milliseconds"]
            }
            corpus["p95ProcessWallMs"] = p95([sample["processWallMs"] for sample in corpus["samples"]])
            corpus["afterSamples"] = footprint(root)
        finally:
            # Only this invocation's isolated temporary directory is eligible for cleanup.
            if container is not None and not args.keep_corpus:
                shutil.rmtree(container)
                corpus["corpusRemoved"] = True
            else:
                corpus["corpusRemoved"] = False
            save(args.output, report)


if __name__ == "__main__":
    main()
