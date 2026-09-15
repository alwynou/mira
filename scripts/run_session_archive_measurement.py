#!/usr/bin/env python3
"""Measure one real archive round trip over an existing synthetic session corpus.

Build MiraScaleProbe in Release first. This is a correctness/capacity observation,
not a latency percentile or a joint domain-library benchmark.
"""

import argparse
import hashlib
import json
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile
import time

from run_session_scale_measurement import footprint, save


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--probe", type=Path, default=Path("Packages/MiraKit/.build/release/MiraScaleProbe"))
    parser.add_argument("--existing-corpus", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--keep-output", action="store_true")
    args = parser.parse_args()
    probe = args.probe.resolve(strict=True)
    corpus = args.existing_corpus.resolve(strict=True)
    manifest = json.loads((corpus / "scale.json").read_text())
    if manifest.get("format") != "mira-session-scale-v1" or not 1 <= manifest.get("sessions", 0) <= 1000:
        parser.error("The source must be a synthetic scale corpus with 1...1000 sessions.")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    container = Path(tempfile.mkdtemp(prefix="mira-session-archive-"))
    destination = container / "roundtrip"
    report = {
        "format": "mira-session-archive-measurement-v1",
        "timestampUTC": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "gitCommit": subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip(),
        "probeSHA256": hashlib.sha256(probe.read_bytes()).hexdigest(),
        "toolchain": subprocess.check_output(["swift", "--version"], text=True).strip(),
        "os": platform.platform(),
        "build": "SwiftPM Release; record dirty source revisions separately",
        "scope": "single observation; settled sessions and minimal business schema; no native UI or provider",
        "sourceDirectory": str(corpus),
        "outputDirectory": str(container),
        "sessions": manifest["sessions"],
        "messages": manifest["sessions"] * manifest["messagesPerSession"],
    }
    save(args.output, report)
    try:
        started = time.perf_counter()
        result = subprocess.run([str(probe), "archive", str(corpus), str(destination)],
                                text=True, stdout=subprocess.PIPE)
        report["returnCode"] = result.returncode
        report["processWallMs"] = (time.perf_counter() - started) * 1000
        report["archivePublished"] = (destination / "archive").is_dir()
        report["restoredPublished"] = (destination / "restored").is_dir()
        if result.returncode == 0:
            report["measurement"] = json.loads(result.stdout)
            report["archiveFootprint"] = footprint(destination / "archive")
            report["restoredFootprintAfterVerification"] = footprint(destination / "restored")
        save(args.output, report)
        result.check_returncode()
    finally:
        # Never delete the caller's retained corpus, even if the round trip fails.
        if not args.keep_output:
            shutil.rmtree(container)
        report["outputRemoved"] = not args.keep_output
        save(args.output, report)


if __name__ == "__main__":
    main()
