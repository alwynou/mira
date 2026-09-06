#!/usr/bin/env python3
"""Run the Debug native fixture in a disposable, uniquely identified macOS app.

Build Mira first. The report contains synthetic metrics only. The isolated app and
library are removed on exit; the existing user's Mira process is never targeted.
"""
import argparse
import json
import os
from pathlib import Path
import plistlib
import signal
import shutil
import subprocess
import tempfile
import time
import uuid


def run(command, **kwargs):
    return subprocess.run(command, check=True, **kwargs)


def matching_processes(executable):
    output = run(["ps", "-axo", "pid=,command="], capture_output=True, text=True).stdout
    matches = []
    for line in output.splitlines():
        fields = line.strip().split(None, 1)
        if len(fields) != 2:
            continue
        binary, marker, _ = fields[1].partition(" --demo --native-rendering-benchmark ")
        # Launch Services may canonicalize /var to /private/var on macOS.
        if marker and Path(binary).resolve() == executable.resolve():
            matches.append(int(fields[0]))
    return matches


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=Path(".build/xcode/Build/Products/Debug/Mira.app"))
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--expand-thinking", action="store_true")
    parser.add_argument("--timeout", type=int, default=600)
    args = parser.parse_args()
    output = args.output.resolve()
    if not args.app.is_dir() or output.exists() or not output.parent.is_dir() or args.timeout <= 0:
        parser.error("Provide a built Debug app, a new report path in an existing directory, and a positive timeout.")
    binaries = list((args.app / "Contents/MacOS").glob("*"))
    if not any(path.is_file() and b"--native-rendering-benchmark" in path.read_bytes() for path in binaries):
        parser.error("The app does not contain the opt-in Debug rendering benchmark.")
    directory = Path(tempfile.mkdtemp(prefix="mira-rendering-")).resolve()
    executable = directory / "MiraPerformanceCheck.app/Contents/MacOS/Mira"
    try:
        app = directory / "MiraPerformanceCheck.app"
        run(["ditto", str(args.app.resolve()), str(app)])
        info = app / "Contents/Info.plist"
        metadata = plistlib.loads(info.read_bytes())
        metadata["CFBundleIdentifier"] = "com.alwynou.mira.performance-check." + uuid.uuid4().hex
        metadata["CFBundleDisplayName"] = "Mira Performance Check"
        info.write_bytes(plistlib.dumps(metadata))
        # Permission applies only to this disposable local Debug fixture.
        entitlements = directory / "entitlements.plist"
        entitlements.write_bytes(plistlib.dumps({"com.apple.security.get-task-allow": True}))
        run(["codesign", "--force", "--deep", "--sign", "-", "--entitlements", str(entitlements), str(app)])
        executable = app / "Contents/MacOS" / metadata["CFBundleExecutable"]
        if not executable.is_file():
            raise ValueError("The copied app has no executable.")
        app_log = directory / "app.log"
        app_log.touch()
        command = ["open", "-n", "--stdout", str(app_log), "--stderr", str(app_log), str(app), "--args", "--demo", "--native-rendering-benchmark",
                   "--data-directory", str(directory / "library"), "--benchmark-report", str(output)]
        if args.expand_thinking:
            command.append("--benchmark-expand-thinking")
        try:
            run(command)
            print(f"Synthetic benchmark launched: {app}", flush=True)
            deadline = time.monotonic() + args.timeout
            log_cursor = 0
            while time.monotonic() < deadline:
                log = app_log.read_text(errors="replace")
                for line in log[log_cursor:].splitlines():
                    if line.startswith("Benchmark phase:"):
                        print(line, flush=True)
                log_cursor = len(log)
                if output.exists():
                    try:
                        report = json.loads(output.read_text())
                    except (OSError, json.JSONDecodeError):
                        time.sleep(0.2)
                        continue
                    print(json.dumps({"report": str(output), "summaries": report["summaries"],
                                      "elapsedSeconds": report["elapsedSeconds"],
                                      "nativeScrollViewFound": report["nativeScrollViewFound"]}, indent=2))
                    if not report["nativeScrollViewFound"] or len(report["scrollPositions"]) != 30:
                        raise RuntimeError("The report is incomplete: the transcript scroll probe did not run 30 times.")
                    if any(phase["count"] < 30 for phase in report["summaries"]):
                        raise RuntimeError("The report is incomplete: a phase has fewer than 30 service samples.")
                    return
                time.sleep(0.5)
            raise TimeoutError("The synthetic benchmark did not finish before its deadline.")
        finally:
            # Match both our unique temporary executable path and benchmark flags.
            # No process-name-only kill and no writes to another Mira data directory.
            for pid in matching_processes(executable):
                try:
                    os.kill(pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
            for _ in range(20):
                if not matching_processes(executable):
                    break
                time.sleep(0.1)
            if matching_processes(executable):
                raise RuntimeError(f"The fixture process did not exit. Preserved for inspection: {directory}")
    finally:
        # If inspection fails or the fixture is still alive, leave its directory intact.
        if not matching_processes(executable):
            shutil.rmtree(directory)


if __name__ == "__main__":
    main()
