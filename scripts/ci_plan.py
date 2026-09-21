#!/usr/bin/env python3
"""Choose conservative CI checks from the complete pull request diff."""

import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys


CHECKS = ("package", "macos", "scripts", "language", "tokens")
FULL = {name: True for name in CHECKS}
FALSE = {name: False for name in CHECKS}
KNOWN_TESTS = (
    "Tests/MiraCompositionTests",
    "Tests/MiraSettingsTests",
    "Tests/MiraLocalizationTests",
    "Tests/MiraPlatformTests",
    "Tests/MiraTestSupport",
    "Tests/MiraUITests",
)
# Only known documentation and design artifact formats may bypass native checks.
DOC_EXTENSIONS = {".md", ".mmd", ".svg", ".png", ".jpg", ".jpeg", ".webp", ".pdf", ".json"}
DESIGN_EXTENSIONS = DOC_EXTENSIONS | {".html", ".css"}
SHA_PATTERN = re.compile(r"^[0-9a-fA-F]{40}$")


def full_plan(reason):
    return {**FULL, "reason": reason}


def classify_paths(paths):
    """Return conservative check flags and a concise explanation for paths."""
    if not isinstance(paths, (list, tuple)) or not paths:
        return full_plan("No changed paths were available")

    flags = dict(FALSE)
    reasons = []

    def require_full(reason):
        reasons.append(reason)
        for check in CHECKS:
            flags[check] = True

    for raw_path in paths:
        if not isinstance(raw_path, str) or not raw_path or "\x00" in raw_path:
            require_full("Malformed changed path")
            continue
        if raw_path.startswith("/") or "\\" in raw_path:
            require_full("Changed path is not a repository-relative POSIX path")
            continue
        path = PurePosixPath(raw_path)
        if any(part in ("", ".", "..") for part in raw_path.split("/")):
            require_full("Changed path contains an unsafe component")
            continue

        if path.parts[0] == ".github":
            require_full("Workflow or repository automation changed")
        elif raw_path.startswith("Tests/Fixtures/"):
            require_full("Test fixtures changed")
        elif raw_path == "project.yml" or raw_path.startswith("Mira.xcodeproj/"):
            require_full("Xcode project configuration changed")
        elif raw_path.startswith("Vendor/"):
            require_full("Vendored code changed")
        elif path.name in ("Package.swift", "Package.resolved"):
            require_full("Swift package manifest or resolution changed")
        elif raw_path.startswith("scripts/"):
            if (re.fullmatch(r"scripts/ci_[^/]+\.py", raw_path)
                    or re.fullmatch(r"scripts/tests/test_ci_[^/]+\.py", raw_path)
                    or raw_path == "scripts/check_language_policy.py"):
                require_full("CI or language policy tooling changed")
            else:
                flags["scripts"] = True
                flags["language"] = True
                reasons.append("Script tooling changed")
                if raw_path == "scripts/export_design_tokens.py":
                    flags["tokens"] = True
                    reasons.append("Design token exporter changed")
        elif raw_path.startswith("Apps/MiraMac/"):
            flags["macos"] = True
            flags["language"] = True
            reasons.append("macOS app source changed")
            if path.name == "MiraTheme.swift":
                flags["tokens"] = True
                reasons.append("Design theme tokens changed")
        elif raw_path.startswith("Packages/MiraKit/"):
            flags["package"] = True
            flags["macos"] = True
            flags["language"] = True
            reasons.append("MiraKit source changed")
        elif path.parts[0] == "Tests":
            if any(raw_path == root or raw_path.startswith(root + "/") for root in KNOWN_TESTS):
                flags["macos"] = True
                flags["language"] = True
                reasons.append("macOS tests changed")
            else:
                require_full("Unclassified test path changed")
        elif raw_path == "designs/mira-ui/tokens.json":
            flags["tokens"] = True
            reasons.append("Exported design tokens changed")
        elif raw_path.startswith("docs/"):
            if path.suffix.lower() not in DOC_EXTENSIONS:
                require_full("Unrecognized file type under docs")
            else:
                reasons.append("Documentation artifact changed")
        elif raw_path.startswith("designs/"):
            if path.suffix.lower() not in DESIGN_EXTENSIONS:
                require_full("Unrecognized file type under designs")
            else:
                reasons.append("Design artifact changed")
        elif len(path.parts) == 1 and path.name.startswith("README") and path.suffix.lower() == ".md":
            reasons.append("README documentation changed")
        elif len(path.parts) == 1 and path.name in ("LICENSE", "AGENTS.md"):
            reasons.append("Repository documentation changed")
        else:
            require_full("Unclassified repository path changed")

    # Full checks dominate any partial routing and make the reason unambiguous.
    if all(flags.values()):
        return {**FULL, "reason": "; ".join(dict.fromkeys(reasons))}
    return {**flags, "reason": "; ".join(dict.fromkeys(reasons)) or "Documentation only"}


def _event_plan(event_name, event_path):
    if event_name == "workflow_dispatch":
        return full_plan("Manual workflow dispatch")
    if event_name != "pull_request":
        return full_plan("Unsupported GitHub event")
    try:
        event = json.loads(Path(event_path).read_text(encoding="utf-8"))
        base = event["pull_request"]["base"]["sha"]
        head = event["pull_request"]["head"]["sha"]
    except (OSError, UnicodeError, json.JSONDecodeError, KeyError, TypeError):
        return full_plan("Pull request event data is missing or malformed")
    if not isinstance(base, str) or not isinstance(head, str) or not SHA_PATTERN.fullmatch(base) or not SHA_PATTERN.fullmatch(head):
        return full_plan("Pull request base or head SHA is malformed")
    try:
        result = subprocess.run(
            ["git", "diff", "--name-only", "--no-renames", "-z", f"{base}...{head}"],
            check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
    except (OSError, subprocess.CalledProcessError):
        return full_plan("Could not read the complete pull request diff")
    if not result.stdout or not result.stdout.endswith(b"\0"):
        return full_plan("Pull request diff was empty or malformed")
    try:
        paths = [item.decode("utf-8", errors="strict") for item in result.stdout[:-1].split(b"\0")]
    except UnicodeDecodeError:
        return full_plan("Pull request diff contains an invalid path encoding")
    if not paths or any(not item for item in paths):
        return full_plan("Pull request diff was empty or malformed")
    return classify_paths(paths)


def _write_outputs(plan):
    output_path = os.environ.get("GITHUB_OUTPUT")
    if output_path:
        with open(output_path, "a", encoding="utf-8") as output:
            for check in CHECKS:
                output.write(f"{check}={'true' if plan[check] else 'false'}\n")
            output.write(f"reason={plan['reason']}\n")
    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary_path:
        with open(summary_path, "a", encoding="utf-8") as summary:
            enabled = ", ".join(check for check in CHECKS if plan[check]) or "none"
            summary.write(f"CI plan: {enabled}. {plan['reason']}\n")


def main():
    plan = _event_plan(os.environ.get("GITHUB_EVENT_NAME", ""), os.environ.get("GITHUB_EVENT_PATH", ""))
    print(json.dumps(plan, sort_keys=True))
    _write_outputs(plan)
    return 0


if __name__ == "__main__":
    sys.exit(main())
