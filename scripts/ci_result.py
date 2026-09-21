#!/usr/bin/env python3
"""Validate that every CI job completed according to the CI plan."""

import json
import os
import sys


JOB_NAMES = ("plan", "lightweight", "package", "macos")
CHECK_NAMES = ("package", "macos")


def check_results(needs):
    """Return validation errors for GitHub Actions' serialized ``needs`` map."""
    errors = []
    if not isinstance(needs, dict):
        return ["CI needs data must be a JSON object"]

    jobs = {}
    for name in JOB_NAMES:
        job = needs.get(name)
        if not isinstance(job, dict):
            errors.append(f"Missing or malformed job: {name}")
            continue
        result = job.get("result")
        if not isinstance(result, str) or result not in ("success", "failure", "cancelled", "skipped"):
            errors.append(f"Missing or malformed result for job: {name}")
        jobs[name] = job

    plan_job = jobs.get("plan")
    plan = plan_job.get("outputs") if plan_job else None
    if not isinstance(plan, dict):
        errors.append("Missing or malformed plan outputs")
        plan = {}
    for name in CHECK_NAMES:
        if plan.get(name) not in ("true", "false"):
            errors.append(f"Missing or invalid plan output: {name} (expected 'true' or 'false')")

    if plan_job and plan_job.get("result") != "success":
        errors.append("Required job plan did not succeed")
    lightweight = jobs.get("lightweight")
    if lightweight and lightweight.get("result") != "success":
        errors.append("Required job lightweight did not succeed")

    for name in CHECK_NAMES:
        job = jobs.get(name)
        if job is None:
            continue
        result = job.get("result")
        enabled = plan.get(name)
        if enabled == "true" and result != "success":
            errors.append(f"Planned job {name} did not succeed (result: {result})")
        elif enabled == "false" and result not in ("skipped", "success"):
            errors.append(f"Unplanned job {name} did not skip or succeed (result: {result})")

    return errors


def _outcome_table(needs):
    rows = ["| Job | Result | Plan |", "| --- | --- | --- |"]
    if not isinstance(needs, dict):
        return "\n".join(rows)
    for name in JOB_NAMES:
        job = needs.get(name)
        if not isinstance(job, dict):
            result = "missing"
        else:
            result = job.get("result", "missing")
            if not isinstance(result, str):
                result = "malformed"
        planned = "—"
        if name in CHECK_NAMES:
            planner = needs.get("plan")
            outputs = planner.get("outputs") if isinstance(planner, dict) else None
            value = outputs.get(name) if isinstance(outputs, dict) else None
            planned = value if value in ("true", "false") else "invalid/missing"
        rows.append(f"| {name} | {result} | {planned} |")
    return "\n".join(rows)


def main():
    raw = os.environ.get("CI_NEEDS")
    needs = None
    parse_error = None
    try:
        needs = json.loads(raw) if raw is not None else None
    except (json.JSONDecodeError, TypeError):
        parse_error = "CI_NEEDS is missing or contains malformed JSON"

    errors = [parse_error] if parse_error else check_results(needs)
    table = _outcome_table(needs)
    print(table)
    if errors:
        for error in errors:
            print(f"CI result error: {error}", file=sys.stderr)

    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary_path:
        with open(summary_path, "a", encoding="utf-8") as summary:
            summary.write("## CI results\n\n")
            summary.write(table + "\n")
            if errors:
                summary.write("\n" + "\n".join(f"- {error}" for error in errors) + "\n")

    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
