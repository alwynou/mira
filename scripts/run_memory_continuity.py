#!/usr/bin/env python3
"""Run the bounded, two-process memory-continuity evaluation.

The evaluator is deliberately opt-in and requires a new output directory. It
never prints the child process environment or child output because the child
receives a live provider credential. The report and per-phase logs contain only
redacted output and synthetic run metadata.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
import uuid
from typing import Any, Callable, Iterable


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CORPUS = REPOSITORY_ROOT / "Tests/Fixtures/EverydayMemory/continuity.json"
TEST_METHOD = "MiraHostTests/MemoryContinuityLiveTests/testOptInContinuityPhase"
GLOBAL_AUTHORIZATION_LIMIT = 32
PER_CASE_AUTHORIZATION_LIMIT = 8
ESTABLISHMENT_CAP = 6


class LauncherError(RuntimeError):
    """A configuration or bounded-run failure safe to show to the caller."""


def utc_timestamp() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def atomic_write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{uuid.uuid4().hex}.tmp")
    try:
        temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        os.replace(temporary, path)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def read_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise LauncherError(f"Cannot read JSON at {path}: {error}") from error


def load_scenarios(corpus_path: Path) -> list[dict[str, Any]]:
    data = read_json(corpus_path)
    if not isinstance(data, dict) or data.get("version") != 1 or not isinstance(data.get("scenarios"), list):
        raise LauncherError("continuity.json must contain version 1 and a scenarios array")
    scenarios = data["scenarios"]
    if len(scenarios) != 4:
        raise LauncherError(f"continuity.json must contain exactly four scenarios; found {len(scenarios)}")
    required = {"en:automatic", "en:explicitSave", "zh-CN:automatic", "zh-CN:explicitSave"}
    seen: set[str] = set()
    ids: set[str] = set()
    for scenario in scenarios:
        if not isinstance(scenario, dict):
            raise LauncherError("continuity.json contains a non-object scenario")
        if not all(isinstance(scenario.get(key), str) and scenario[key].strip() for key in ("id", "language", "input", "followUp", "mode")):
            raise LauncherError("continuity.json contains an empty or malformed scenario field")
        if type(scenario.get("requiresCitation")) is not bool:
            raise LauncherError("continuity.json requires a boolean requiresCitation field")
        if not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", scenario["id"]):
            raise LauncherError(f"continuity scenario ID is not a safe lowercase kebab ID: {scenario['id']}")
        if scenario["id"] in ids:
            raise LauncherError(f"continuity.json repeats scenario ID {scenario['id']}")
        ids.add(scenario["id"])
        pair = f"{scenario['language']}:{scenario['mode']}"
        if pair not in required:
            raise LauncherError(f"continuity.json contains an unknown language/mode pair: {pair}")
        if pair in seen:
            raise LauncherError(f"continuity.json repeats language/mode pair {pair}")
        seen.add(pair)
    if seen != required:
        raise LauncherError(f"continuity.json is missing language/mode pairs: {sorted(required - seen)}")
    return scenarios


def select_scenarios(scenarios: Iterable[dict[str, Any]], case_ids: list[str] | None) -> list[dict[str, Any]]:
    values = list(scenarios)
    if case_ids is None:
        return values
    known = {scenario["id"] for scenario in values}
    if not case_ids or len(set(case_ids)) != len(case_ids) or not set(case_ids).issubset(known):
        raise LauncherError("--case-id contains an unknown or duplicate scenario ID")
    selected = set(case_ids)
    return [scenario for scenario in values if scenario["id"] in selected]


def prepare_output_directory(path: Path) -> Path:
    path = path.expanduser().resolve()
    if path.exists():
        raise LauncherError("--output-dir must name a new directory")
    path.mkdir(parents=True, exist_ok=False)
    return path


def initial_ledger() -> dict[str, Any]:
    return {"version": 1, "globalLimit": GLOBAL_AUTHORIZATION_LIMIT, "entries": []}


def load_ledger(path: Path) -> dict[str, Any]:
    if not path.exists():
        return initial_ledger()
    ledger = read_json(path)
    if not isinstance(ledger, dict) or ledger.get("version") != 1 or ledger.get("globalLimit") != GLOBAL_AUTHORIZATION_LIMIT or not isinstance(ledger.get("entries"), list):
        raise LauncherError("The budget ledger is malformed")
    return ledger


def ledger_committed(ledger: dict[str, Any]) -> int:
    total = 0
    for entry in ledger["entries"]:
        if entry.get("state") == "settled":
            value = entry.get("used")
            if type(value) is not int or value < 0:
                raise LauncherError("The budget ledger contains an invalid settled count")
            total += value
        elif entry.get("state") == "reserved":
            value = entry.get("reserved")
            if type(value) is not int or value <= 0:
                raise LauncherError("The budget ledger contains an invalid reservation")
            total += value
        elif entry.get("state") == "held":
            value = entry.get("reserved")
            if type(value) is not int or value <= 0:
                raise LauncherError("The budget ledger contains an invalid held reservation")
            total += value
        else:
            raise LauncherError("The budget ledger contains an unknown entry state")
    return total


def reserve_phase(ledger_path: Path, *, run_id: str, case_id: str, phase: str, cap: int, report: Path, log: Path, case_limit: int = PER_CASE_AUTHORIZATION_LIMIT) -> dict[str, Any]:
    if phase not in {"establish", "recall"}:
        raise LauncherError("A continuity phase must be establish or recall")
    if type(cap) is not int or not 1 <= cap <= PER_CASE_AUTHORIZATION_LIMIT:
        raise LauncherError("A phase authorization cap must be between 1 and 8")
    if type(case_limit) is not int or not 4 <= case_limit <= PER_CASE_AUTHORIZATION_LIMIT:
        raise LauncherError("A per-case authorization limit must be between 4 and 8")
    if cap > case_limit:
        raise LauncherError("The phase authorization cap exceeds the per-case authorization limit")
    if phase == "establish" and cap > ESTABLISHMENT_CAP:
        raise LauncherError("The establishment authorization cap must be at most 6")
    ledger = load_ledger(ledger_path)
    committed = ledger_committed(ledger)
    if committed + cap > GLOBAL_AUTHORIZATION_LIMIT:
        raise LauncherError(f"Global authorization limit would be exceeded by {case_id}/{phase}")
    same_case = [entry for entry in ledger["entries"] if entry.get("caseID") == case_id]
    if any(entry.get("phase") == phase for entry in same_case):
        raise LauncherError(f"The {case_id}/{phase} reservation already exists")
    case_committed = sum(
        (entry.get("used") if entry.get("state") == "settled" else entry.get("reserved", 0)) or 0
        for entry in same_case
    )
    if case_committed + cap > case_limit:
        raise LauncherError(f"Per-case authorization limit would be exceeded by {case_id}/{phase}")
    if report.exists() or log.exists():
        raise LauncherError(f"The {case_id}/{phase} report or log path already exists")
    entry = {
        "runID": run_id,
        "caseID": case_id,
        "phase": phase,
        "state": "reserved",
        "reserved": cap,
        "used": None,
        "report": str(report),
        "log": str(log),
        "reservedAt": utc_timestamp(),
    }
    ledger["entries"].append(entry)
    atomic_write_json(ledger_path, ledger)
    return entry


def settle_phase(ledger_path: Path, entry: dict[str, Any], *, report_valid: bool, used: int | None) -> None:
    ledger = load_ledger(ledger_path)
    matches = [candidate for candidate in ledger["entries"] if candidate.get("runID") == entry["runID"] and candidate.get("caseID") == entry["caseID"] and candidate.get("phase") == entry["phase"]]
    if len(matches) != 1:
        raise LauncherError("The phase reservation is missing from the budget ledger")
    target = matches[0]
    if target.get("state") != "reserved":
        raise LauncherError("The phase reservation has already been settled")
    if report_valid:
        if type(used) is not int or not 0 <= used <= target["reserved"]:
            raise LauncherError("A valid phase report has an invalid authorization count")
        target["state"] = "settled"
        target["used"] = used
        target["settledAt"] = utc_timestamp()
    else:
        target["state"] = "held"
        target["heldAt"] = utc_timestamp()
    atomic_write_json(ledger_path, ledger)


def scrubbed_environment(secret: str, values: dict[str, str]) -> dict[str, str]:
    environment = {
        key: value
        for key, value in os.environ.items()
        if key != "DEEPSEEK_API_KEY" and not key.startswith("MIRA_") and not key.startswith("TEST_RUNNER_MIRA_")
    }
    environment.update({f"TEST_RUNNER_{key}": value for key, value in values.items()})
    environment["TEST_RUNNER_MIRA_EVAL_API_KEY"] = secret
    return environment


def xcodebuild_command() -> list[str]:
    return [
        "xcodebuild", "-project", "Mira.xcodeproj", "-scheme", "Mira",
        "-configuration", "Debug", "-destination", "platform=macOS",
        "-derivedDataPath", ".build/xcode", "-onlyUsePackageVersionsFromResolvedFile",
        "CODE_SIGNING_ALLOWED=NO", f"-only-testing:{TEST_METHOD}", "test-without-building",
    ]


def valid_phase_report(report_path: Path, *, phase: str, case_id: str, run_id: str | None = None, root: Path | None = None, exit_code: int, cap: int) -> tuple[bool, int | None, str | None]:
    if exit_code != 0 or not report_path.exists():
        return False, None, "xcodebuild_failed_or_report_missing"
    try:
        report = read_json(report_path)
    except LauncherError:
        return False, None, "report_unreadable"
    if not isinstance(report, dict):
        return False, None, "report_not_an_object"
    used = report.get("requestAuthorizationCount")
    identity = report.get("identity")
    if (
        report.get("version") != 1
        or report.get("phase") != phase
        or not isinstance(identity, dict)
        or identity.get("caseID") != case_id
        or (run_id is not None and identity.get("runID") != run_id)
        or (root is not None and not same_path(identity.get("root"), root))
        or report.get("status") != "completed"
        or report.get("closeSettled") is not True
        or report.get("mismatches") != []
        or not report.get("finishedAt")
        or not isinstance(report.get("processID"), int)
        or not isinstance(report.get("processInstanceID"), str)
        or not report.get("processInstanceID")
        or report.get("requestAuthorizationCap") != cap
        or type(used) is not int
        or not 0 <= used <= cap
    ):
        return False, None, "report_not_finished_or_clean"
    return True, used, None


def same_path(value: Any, expected: Path) -> bool:
    if not isinstance(value, str) or not value.startswith("/"):
        return False
    try:
        return Path(value).resolve() == expected.resolve()
    except OSError:
        return False


def phase_summary(report_path: Path, log_path: Path, *, phase: str, case_id: str, run_id: str | None = None, root: Path | None = None, cap: int, process_id: int | None, exit_code: int | None, interrupted: bool = False) -> dict[str, Any]:
    report: dict[str, Any] = {}
    if report_path.exists():
        try:
            value = read_json(report_path)
            if isinstance(value, dict):
                report = value
        except LauncherError:
            pass
    valid, used, reason = valid_phase_report(report_path, phase=phase, case_id=case_id, run_id=run_id, root=root, exit_code=exit_code if exit_code is not None else -1, cap=cap)
    observed = report.get("requestAuthorizationCount") if type(report.get("requestAuthorizationCount")) is int else None
    return {
        "phase": phase,
        "caseID": case_id,
        "report": str(report_path),
        "log": str(log_path),
        "xcodebuildPID": process_id,
        "xcodebuildExitCode": exit_code,
        "testPID": report.get("processID"),
        "processUUID": report.get("processInstanceID"),
        "reportStatus": report.get("status"),
        "reportFinished": bool(report.get("finishedAt")),
        "requestAuthorizationCap": cap,
        "requestAuthorizationCount": used,
        "observedRequestAuthorizationCount": observed,
        "reportValid": valid,
        "invalidReason": reason,
        "interrupted": interrupted,
    }


def require_new_process(establishment: dict[str, Any], recall: dict[str, Any]) -> None:
    """A fresh recall process is part of the continuity handoff contract."""
    if not recall.get("reportValid"):
        return
    same_pid = establishment.get("testPID") is not None and establishment.get("testPID") == recall.get("testPID")
    same_uuid = establishment.get("processUUID") and establishment.get("processUUID") == recall.get("processUUID")
    if same_pid or same_uuid:
        recall["reportValid"] = False
        recall["requestAuthorizationCount"] = None
        recall["invalidReason"] = "recall_reused_establishment_process"


def recovery_caps(prior_establishment_count: int) -> tuple[int, int]:
    """Return the bounded follow-up caps for an imported establishment."""
    if type(prior_establishment_count) is not int or not 0 <= prior_establishment_count <= ESTABLISHMENT_CAP:
        raise LauncherError("The prior establishment count is outside the 0...6 bound")
    remaining = PER_CASE_AUTHORIZATION_LIMIT - prior_establishment_count
    if remaining < 1:
        raise LauncherError("The prior establishment leaves no bounded recall allowance")
    return min(ESTABLISHMENT_CAP, remaining - 1), remaining


def load_prior_establishments(prior_run: Path, scenarios: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Import only clean, completed establishment reports from a prior run."""
    prior_run = prior_run.expanduser().resolve()
    run_report_path = prior_run / "run-report.json"
    run_report = read_json(run_report_path)
    if not isinstance(run_report, dict) or run_report.get("version") != 1 or not run_report.get("finishedAt") or run_report.get("priorRun"):
        raise LauncherError("--prior-run must contain a finalized run-report.json")
    cases = run_report.get("cases")
    expected = {scenario["id"]: scenario for scenario in scenarios}
    if not isinstance(cases, list) or len(cases) != len(expected):
        raise LauncherError("--prior-run must contain exactly the four continuity cases")
    imported: list[dict[str, Any]] = []
    for case in cases:
        if not isinstance(case, dict) or case.get("caseID") not in expected:
            raise LauncherError("--prior-run contains an unknown continuity case")
        case_id = case["caseID"]
        phases = case.get("phases")
        if not isinstance(phases, list) or len(phases) != 1 or not isinstance(phases[0], dict) or phases[0].get("phase") != "establish":
            raise LauncherError(f"--prior-run must contain only one establishment phase for {case_id}")
        phase = phases[0]
        if not isinstance(phase, dict):
            raise LauncherError(f"--prior-run establishment phase is malformed for {case_id}")
        report_value = phase.get("report")
        if not isinstance(report_value, str):
            raise LauncherError(f"--prior-run establishment report path is missing for {case_id}")
        report_path = Path(report_value)
        if not report_path.is_absolute():
            report_path = prior_run / report_path
        report_path = report_path.resolve()
        root_value = case.get("root")
        if not isinstance(root_value, str):
            raise LauncherError(f"--prior-run root is missing for {case_id}")
        root = Path(root_value).resolve()
        run_id = phase.get("runID") or case.get("runID")
        if not isinstance(run_id, str) or not run_id:
            raise LauncherError(f"--prior-run run ID is missing for {case_id}")
        exit_code = phase.get("xcodebuildExitCode")
        cap = phase.get("requestAuthorizationCap")
        valid, used, reason = valid_phase_report(report_path, phase="establish", case_id=case_id, run_id=run_id, root=root, exit_code=exit_code if type(exit_code) is int else -1, cap=cap if type(cap) is int else 0)
        if not valid or used is None:
            raise LauncherError(f"The prior establishment is not clean for {case_id}: {reason}")
        raw = read_json(report_path)
        identity = raw.get("identity") if isinstance(raw, dict) else None
        scenario = expected[case_id]
        expected_requires_citation = scenario.get("requiresCitation")
        if (
            not isinstance(identity, dict)
            or identity.get("language") != scenario["language"]
            or identity.get("mode") != scenario["mode"]
            or identity.get("input") != scenario["input"]
            or identity.get("followUp") != scenario["followUp"]
            or type(expected_requires_citation) is not bool
            or type(identity.get("requiresCitation")) is not bool
            or identity.get("requiresCitation") != expected_requires_citation
        ):
            raise LauncherError(f"The prior establishment identity does not match the corpus for {case_id}")
        if identity.get("providerID") != "deepseek" or identity.get("modelID") != "deepseek-flash" or identity.get("endpoint") != "https://api.deepseek.com" or identity.get("protocolID") != "chat.completions" or identity.get("contextWindow") != 1_000_000 or identity.get("outputTokens") != 8_192 or identity.get("embeddings") != "local":
            raise LauncherError(f"The prior establishment configuration does not match the bounded continuity run for {case_id}")
        recovery_caps(used)
        imported.append({"caseID": case_id, "runID": run_id, "root": root, "report": report_path, "used": used, "processID": raw.get("processID"), "processUUID": raw.get("processInstanceID")})
    if {item["caseID"] for item in imported} != set(expected) or len({item["runID"] for item in imported}) != len(imported):
        raise LauncherError("--prior-run contains duplicate or missing continuity identities")
    return sorted(imported, key=lambda item: item["caseID"])


def run_phase(command: list[str], *, cwd: Path, environment: dict[str, str], report_path: Path, log_path: Path, secret: str) -> dict[str, Any]:
    process = subprocess.Popen(command, cwd=str(cwd), env=environment, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    interrupted = False
    try:
        output, _ = process.communicate()
    except KeyboardInterrupt:
        interrupted = True
        output = b""
    if isinstance(output, str):
        output = output.encode()
    redacted = output.replace(secret.encode(), b"[REDACTED]")
    log_path.write_bytes(redacted)
    exit_code = process.poll()
    if exit_code is None and interrupted:
        raise KeyboardInterrupt
    return {"process": process, "pid": process.pid, "exitCode": exit_code, "interrupted": interrupted}


def record_prior_establishment(ledger_path: Path, item: dict[str, Any]) -> None:
    ledger = load_ledger(ledger_path)
    ledger["entries"].append({
        "runID": item["runID"], "caseID": item["caseID"], "phase": "establish_prior",
        "state": "settled", "reserved": item["used"], "used": item["used"],
        "report": str(item["report"]), "log": None, "reservedAt": utc_timestamp(),
    })
    atomic_write_json(ledger_path, ledger)


def child_values(*, corpus: Path, report: Path, case_id: str, cap: int, root: Path, phase: str, run_id: str, handoff: Path | None) -> dict[str, str]:
    values = {
        "MIRA_RUN_LIVE_MEMORY_CONTINUITY_EVAL": "1",
        "MIRA_CONTINUITY_ROOT": str(root),
        "MIRA_CONTINUITY_PHASE": phase,
        "MIRA_CONTINUITY_RUN_ID": run_id,
        "MIRA_EVAL_CORPUS": str(corpus),
        "MIRA_EVAL_REPORT": str(report),
        "MIRA_EVAL_ENDPOINT": "https://api.deepseek.com",
        "MIRA_EVAL_PROVIDER_ID": "deepseek",
        "MIRA_EVAL_PROTOCOL": "chat.completions",
        "MIRA_EVAL_CONVERSATION_MODEL": "deepseek-flash",
        "MIRA_EVAL_CASE_IDS": case_id,
        "MIRA_EVAL_EMBEDDINGS": "local",
        "MIRA_EVAL_CONTEXT_WINDOW": "1000000",
        "MIRA_EVAL_CONVERSATION_OUTPUT": "8192",
        "MIRA_EVAL_REQUEST_AUTHORIZATION_CAP": str(cap),
    }
    if handoff is not None:
        values["MIRA_CONTINUITY_HANDOFF"] = str(handoff)
    return values


def run_cases(*, output_dir: Path, corpus_path: Path, scenarios: Iterable[dict[str, Any]], case_cap: int = PER_CASE_AUTHORIZATION_LIMIT, prior_run: Path | None = None, repository_root: Path = REPOSITORY_ROOT, run_phase_fn: Callable[..., dict[str, Any]] = run_phase) -> dict[str, Any]:
    output_dir = output_dir.expanduser().resolve()
    if not output_dir.is_dir() or any(output_dir.iterdir()):
        raise LauncherError("run_cases requires a new, empty output directory")
    if type(case_cap) is not int or not 4 <= case_cap <= PER_CASE_AUTHORIZATION_LIMIT:
        raise LauncherError("The case authorization cap must be between 4 and 8")
    if prior_run and case_cap != PER_CASE_AUTHORIZATION_LIMIT:
        raise LauncherError("--prior-run requires the historical case cap of 8")
    secret = os.environ.get("DEEPSEEK_API_KEY", "")
    if not secret.strip():
        raise LauncherError("DEEPSEEK_API_KEY is required for an explicitly enabled live run")
    scenarios = list(scenarios)
    imported = load_prior_establishments(prior_run, scenarios) if prior_run else []
    prior_counts = {item["caseID"]: item["used"] for item in imported}
    ledger_path = output_dir / "budget-ledger.json"
    if prior_run:
        # A recovery is explicit and one-shot; old reports and ledger stay intact.
        claim = prior_run.resolve() / "recovery-claim.json"
        with claim.open("x", encoding="utf-8") as handle:
            json.dump({"output": str(output_dir), "claimedAt": utc_timestamp()}, handle)
        for item in imported:
            record_prior_establishment(ledger_path, item)
    command = xcodebuild_command()
    run_report: dict[str, Any] = {
        "version": 1,
        "startedAt": utc_timestamp(),
        "corpus": str(corpus_path),
        "globalAuthorizationLimit": GLOBAL_AUTHORIZATION_LIMIT,
        "caseAuthorizationCap": case_cap,
        "cases": [],
    }
    if prior_run:
        run_report["priorRun"] = str(prior_run.resolve())
    interrupted_root: Path | None = None
    try:
        for scenario in scenarios:
            case_id = scenario["id"]
            if not isinstance(case_id, str) or not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", case_id):
                raise LauncherError(f"continuity scenario ID is not a safe lowercase kebab ID: {case_id}")
            prior_used = prior_counts.get(case_id, 0)
            establish_cap = min(ESTABLISHMENT_CAP, case_cap - prior_used - 1) if prior_run else min(ESTABLISHMENT_CAP, case_cap - 2)
            if establish_cap < 1:
                raise LauncherError(f"No establishment allowance remains for {case_id}")
            case_run_id = str(uuid.uuid4())
            root = Path(tempfile.mkdtemp(prefix="Mira-Continuity-")).resolve()
            interrupted_root = root
            case_result: dict[str, Any] = {"caseID": case_id, "runID": case_run_id, "root": str(root), "caseAuthorizationCap": case_cap, "phases": []}
            establish_report = output_dir / f"{case_id}.establish.json"
            establish_log = output_dir / f"{case_id}.establish.log"
            try:
                establish_entry = reserve_phase(ledger_path, run_id=case_run_id, case_id=case_id, phase="establish", cap=establish_cap, report=establish_report, log=establish_log, case_limit=case_cap)
            except LauncherError as error:
                case_result["skipped"] = str(error)
                run_report["cases"].append(case_result)
                try:
                    import shutil
                    shutil.rmtree(root)
                finally:
                    interrupted_root = None
                continue
            environment = scrubbed_environment(secret, child_values(corpus=corpus_path, report=establish_report, case_id=case_id, cap=establish_cap, root=root, phase="establish", run_id=case_run_id, handoff=None))
            phase_process: dict[str, Any] | None = None
            try:
                print(json.dumps({"event": "phase_start", "caseID": case_id, "phase": "establish", "cap": establish_cap}, sort_keys=True), flush=True)
                phase_process = run_phase_fn(command, cwd=repository_root, environment=environment, report_path=establish_report, log_path=establish_log, secret=secret)
                if phase_process.get("exitCode") is None:
                    raise LauncherError("The establishment process did not exit")
                establishment = phase_summary(establish_report, establish_log, phase="establish", case_id=case_id, run_id=case_run_id, root=root, cap=establish_cap, process_id=phase_process["pid"], exit_code=phase_process["exitCode"], interrupted=phase_process.get("interrupted", False))
                print(json.dumps({"event": "phase_finish", "caseID": case_id, "phase": "establish", "exitCode": establishment["xcodebuildExitCode"], "reportValid": establishment["reportValid"]}, sort_keys=True), flush=True)
            except KeyboardInterrupt:
                settle_phase(ledger_path, establish_entry, report_valid=False, used=None)
                case_result["interrupted"] = True
                run_report["cases"].append(case_result)
                raise
            except Exception:
                settle_phase(ledger_path, establish_entry, report_valid=False, used=None)
                if phase_process is not None and phase_process.get("exitCode") is None:
                    case_result["phases"].append({"phase": "establish", "caseID": case_id, "report": str(establish_report), "log": str(establish_log), "reportValid": False, "invalidReason": "phase_process_still_alive"})
                    case_result["rootRetained"] = True
                    run_report["cases"].append(case_result)
                    raise LauncherError("The establishment process did not exit; its owned root was retained")
                case_result["phases"].append({"phase": "establish", "caseID": case_id, "report": str(establish_report), "log": str(establish_log), "reportValid": False, "invalidReason": "phase_process_failed"})
                case_result["recallSkipped"] = "establishment_process_failed"
                run_report["cases"].append(case_result)
                import shutil
                shutil.rmtree(root)
                interrupted_root = None
                continue
            case_result["phases"].append(establishment)
            settle_phase(ledger_path, establish_entry, report_valid=establishment["reportValid"], used=establishment["requestAuthorizationCount"])
            if not establishment["reportValid"]:
                case_result["recallSkipped"] = "establishment_report_not_finished_or_clean"
                run_report["cases"].append(case_result)
                import shutil
                shutil.rmtree(root)
                interrupted_root = None
                continue
            establish_used = establishment["requestAuthorizationCount"]
            recall_cap = case_cap - prior_used - establish_used
            recall_report = output_dir / f"{case_id}.recall.json"
            recall_log = output_dir / f"{case_id}.recall.log"
            try:
                recall_entry = reserve_phase(ledger_path, run_id=case_run_id, case_id=case_id, phase="recall", cap=recall_cap, report=recall_report, log=recall_log, case_limit=case_cap)
            except LauncherError as error:
                case_result["recallSkipped"] = str(error)
                run_report["cases"].append(case_result)
                import shutil
                shutil.rmtree(root)
                interrupted_root = None
                continue
            environment = scrubbed_environment(secret, child_values(corpus=corpus_path, report=recall_report, case_id=case_id, cap=recall_cap, root=root, phase="recall", run_id=case_run_id, handoff=establish_report))
            try:
                print(json.dumps({"event": "phase_start", "caseID": case_id, "phase": "recall", "cap": recall_cap}, sort_keys=True), flush=True)
                phase_process = run_phase_fn(command, cwd=repository_root, environment=environment, report_path=recall_report, log_path=recall_log, secret=secret)
                if phase_process.get("exitCode") is None:
                    raise LauncherError("The recall process did not exit")
                recall = phase_summary(recall_report, recall_log, phase="recall", case_id=case_id, run_id=case_run_id, root=root, cap=recall_cap, process_id=phase_process["pid"], exit_code=phase_process["exitCode"], interrupted=phase_process.get("interrupted", False))
                require_new_process(establishment, recall)
                print(json.dumps({"event": "phase_finish", "caseID": case_id, "phase": "recall", "exitCode": recall["xcodebuildExitCode"], "reportValid": recall["reportValid"]}, sort_keys=True), flush=True)
            except KeyboardInterrupt:
                settle_phase(ledger_path, recall_entry, report_valid=False, used=None)
                case_result["interrupted"] = True
                run_report["cases"].append(case_result)
                raise
            except Exception:
                settle_phase(ledger_path, recall_entry, report_valid=False, used=None)
                if phase_process is not None and phase_process.get("exitCode") is None:
                    case_result["phases"].append({"phase": "recall", "caseID": case_id, "report": str(recall_report), "log": str(recall_log), "reportValid": False, "invalidReason": "phase_process_still_alive"})
                    case_result["rootRetained"] = True
                    run_report["cases"].append(case_result)
                    raise LauncherError("The recall process did not exit; its owned root was retained")
                case_result["phases"].append({"phase": "recall", "caseID": case_id, "report": str(recall_report), "log": str(recall_log), "reportValid": False, "invalidReason": "phase_process_failed"})
                run_report["cases"].append(case_result)
                import shutil
                shutil.rmtree(root)
                interrupted_root = None
                continue
            case_result["phases"].append(recall)
            settle_phase(ledger_path, recall_entry, report_valid=recall["reportValid"], used=recall["requestAuthorizationCount"])
            run_report["cases"].append(case_result)
            import shutil
            shutil.rmtree(root)
            interrupted_root = None
    except KeyboardInterrupt:
        run_report["interrupted"] = True
        run_report["ownedRootRetained"] = str(interrupted_root) if interrupted_root else None
        raise
    finally:
        ledger = load_ledger(ledger_path)
        run_report["finishedAt"] = utc_timestamp()
        run_report["settledAuthorizations"] = sum(entry.get("used", 0) or 0 for entry in ledger["entries"] if entry.get("state") == "settled")
        run_report["sumPhaseCaps"] = sum(entry.get("reserved", 0) or 0 for entry in ledger["entries"])
        run_report["accountedAuthorizations"] = ledger_committed(ledger)
        run_report["heldAuthorizations"] = run_report["accountedAuthorizations"] - run_report["settledAuthorizations"]
        observed = [phase.get("observedRequestAuthorizationCount")
                    for case in run_report["cases"] for phase in case.get("phases", [])]
        run_report["reportedAuthorizations"] = sum(prior_counts.values()) + sum(value for value in observed if type(value) is int)
        run_report["reportedAuthorizationsComplete"] = all(type(value) is int for value in observed) and all(phase.get("reportFinished") and phase.get("xcodebuildExitCode") is not None for case in run_report["cases"] for phase in case.get("phases", [])) and not run_report.get("interrupted", False)
        run_report["ledger"] = str(ledger_path)
        atomic_write_json(output_dir / "run-report.json", run_report)
    return run_report


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, required=True, help="new directory for reports, logs, and the budget ledger")
    parser.add_argument("--corpus", type=Path, default=DEFAULT_CORPUS)
    parser.add_argument("--prior-run", type=Path, help="recover only a finalized establishment handoff from this prior run directory")
    parser.add_argument("--case-id", action="append", dest="case_ids", help="select one or more known scenario IDs; defaults to all four")
    parser.add_argument("--case-cap", type=int, default=PER_CASE_AUTHORIZATION_LIMIT, help="per-case authorization cap from 4 through 8")
    args = parser.parse_args(argv)
    try:
        output_dir = prepare_output_directory(args.output_dir)
        if type(args.case_cap) is not int or not 4 <= args.case_cap <= PER_CASE_AUTHORIZATION_LIMIT:
            raise LauncherError("--case-cap must be between 4 and 8")
        if args.prior_run and (args.case_ids or args.case_cap != PER_CASE_AUTHORIZATION_LIMIT):
            raise LauncherError("--prior-run requires all four cases and --case-cap 8")
        corpus = args.corpus.expanduser().resolve(strict=True)
        scenarios = load_scenarios(corpus)
        scenarios = select_scenarios(scenarios, args.case_ids)
        result = run_cases(output_dir=output_dir, corpus_path=corpus, scenarios=scenarios, case_cap=args.case_cap, prior_run=args.prior_run)
        print(json.dumps({"report": str(output_dir / 'run-report.json'), "reportedAuthorizations": result["reportedAuthorizations"], "accountedAuthorizations": result["accountedAuthorizations"], "caseCount": len(result["cases"])}, sort_keys=True))
        successful = len(result["cases"]) == len(scenarios) and all(
            len(case.get("phases", [])) == 2
            and not case.get("recallSkipped")
            and all(phase.get("reportValid") for phase in case["phases"])
            for case in result["cases"]
        )
        return 0 if successful else 1
    except (LauncherError, OSError) as error:
        print(f"memory continuity launcher: {error}", file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        print("memory continuity launcher interrupted; any live owned root is retained", file=sys.stderr)
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
