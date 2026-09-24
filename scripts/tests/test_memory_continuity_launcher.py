#!/usr/bin/env python3
"""Focused offline tests for the continuity launcher safety boundaries."""

import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "run_memory_continuity.py"
SPEC = importlib.util.spec_from_file_location("run_memory_continuity", SCRIPT)
assert SPEC and SPEC.loader
launcher = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(launcher)


def scenario(case_id="en-automatic-writing-plan"):
    return {"id": case_id, "language": "en", "input": "A preference.", "followUp": "A question.", "mode": "automatic", "asksForSource": False}


class CorpusAndBudgetTests(unittest.TestCase):
    def test_case_selection_rejects_unknown_and_duplicate_ids(self):
        values = [scenario("one"), scenario("two")]
        self.assertEqual([item["id"] for item in launcher.select_scenarios(values, ["two"])], ["two"])
        with self.assertRaises(launcher.LauncherError):
            launcher.select_scenarios(values, ["unknown"])
        with self.assertRaises(launcher.LauncherError):
            launcher.select_scenarios(values, ["one", "one"])

    def test_case_cap_must_be_between_four_and_eight(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(launcher.LauncherError):
                launcher.run_cases(output_dir=Path(directory), corpus_path=Path("continuity.json"), scenarios=[scenario("case")], case_cap=3)
            with self.assertRaises(launcher.LauncherError):
                launcher.run_cases(output_dir=Path(directory), corpus_path=Path("continuity.json"), scenarios=[scenario("case")], case_cap=9)

    def test_output_directory_must_be_new(self):
        with tempfile.TemporaryDirectory() as directory:
            existing = Path(directory) / "run"
            existing.mkdir()
            with self.assertRaises(launcher.LauncherError):
                launcher.prepare_output_directory(existing)

    def test_unknown_and_duplicate_corpus_pairs_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "continuity.json"
            scenarios = [scenario("one"), scenario("two"), scenario("three"), scenario("four")]
            path.write_text(json.dumps({"version": 1, "scenarios": scenarios}), encoding="utf-8")
            with self.assertRaises(launcher.LauncherError):
                launcher.load_scenarios(path)

    def test_corpus_requires_boolean_source_request_flag(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "continuity.json"
            corpus = json.loads(launcher.DEFAULT_CORPUS.read_text(encoding="utf-8"))
            del corpus["scenarios"][0]["asksForSource"]
            path.write_text(json.dumps(corpus), encoding="utf-8")
            with self.assertRaises(launcher.LauncherError):
                launcher.load_scenarios(path)

            corpus["scenarios"][0]["asksForSource"] = 0
            path.write_text(json.dumps(corpus), encoding="utf-8")
            with self.assertRaises(launcher.LauncherError):
                launcher.load_scenarios(path)

    def test_budget_reservation_is_atomic_and_held_on_invalid_report(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            ledger = root / "budget.json"
            entry = launcher.reserve_phase(ledger, run_id="run", case_id="case", phase="establish", cap=6, report=root / "report", log=root / "log")
            launcher.settle_phase(ledger, entry, report_valid=False, used=None)
            value = json.loads(ledger.read_text(encoding="utf-8"))
            self.assertEqual(value["entries"][0]["state"], "held")
            self.assertEqual(launcher.ledger_committed(value), 6)
            with self.assertRaises(launcher.LauncherError):
                launcher.reserve_phase(ledger, run_id="run2", case_id="case2", phase="establish", cap=27, report=root / "report2", log=root / "log2")

    def test_settled_count_releases_unused_reservation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            ledger = root / "budget.json"
            entry = launcher.reserve_phase(ledger, run_id="run", case_id="case", phase="establish", cap=6, report=root / "report", log=root / "log")
            launcher.settle_phase(ledger, entry, report_valid=True, used=4)
            self.assertEqual(launcher.ledger_committed(json.loads(ledger.read_text(encoding="utf-8"))), 4)


class ReportAndProcessGateTests(unittest.TestCase):
    def test_report_requires_clean_finished_close_and_zero_xcode_exit(self):
        with tempfile.TemporaryDirectory() as directory:
            report = Path(directory) / "report.json"
            base = {"version": 1, "phase": "establish", "identity": {"caseID": "case"}, "status": "completed", "closeSettled": True, "mismatches": [], "finishedAt": "now", "processID": 42, "processInstanceID": "process", "requestAuthorizationCap": 6, "requestAuthorizationCount": 3}
            report.write_text(json.dumps(base), encoding="utf-8")
            self.assertEqual(launcher.valid_phase_report(report, phase="establish", case_id="case", exit_code=0, cap=6), (True, 3, None))
            self.assertFalse(launcher.valid_phase_report(report, phase="establish", case_id="case", exit_code=1, cap=6)[0])
            base["mismatches"] = ["state_changed"]
            report.write_text(json.dumps(base), encoding="utf-8")
            self.assertFalse(launcher.valid_phase_report(report, phase="establish", case_id="case", exit_code=0, cap=6)[0])
            report.write_text(json.dumps(["not", "a", "report"]), encoding="utf-8")
            self.assertFalse(launcher.valid_phase_report(report, phase="establish", case_id="case", exit_code=0, cap=6)[0])

    def test_environment_scrubs_inherited_mira_values_and_secret(self):
        with patch.dict(launcher.os.environ, {"DEEPSEEK_API_KEY": "secret", "MIRA_EVAL_REPORT": "old", "TEST_RUNNER_MIRA_EVAL_REPORT": "older", "PATH": "/bin"}, clear=True):
            environment = launcher.scrubbed_environment("secret", {"MIRA_EVAL_REPORT": "/new/report"})
        self.assertNotIn("DEEPSEEK_API_KEY", environment)
        self.assertEqual(environment["TEST_RUNNER_MIRA_EVAL_REPORT"], "/new/report")
        self.assertNotIn("MIRA_EVAL_REPORT", environment)

    def test_same_test_process_cannot_qualify_recall(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)

            def fake_phase(_command, *, environment, report_path, **_kwargs):
                phase = environment["TEST_RUNNER_MIRA_CONTINUITY_PHASE"]
                cap = int(environment["TEST_RUNNER_MIRA_EVAL_REQUEST_AUTHORIZATION_CAP"])
                report = {
                    "version": 1, "phase": phase,
                    "identity": {"caseID": "case", "runID": environment["TEST_RUNNER_MIRA_CONTINUITY_RUN_ID"], "root": environment["TEST_RUNNER_MIRA_CONTINUITY_ROOT"]},
                    "status": "completed", "closeSettled": True, "mismatches": [], "finishedAt": "now",
                    "processID": 42, "processInstanceID": "same-process", "requestAuthorizationCap": cap,
                    "requestAuthorizationCount": 4,
                }
                report_path.write_text(json.dumps(report), encoding="utf-8")
                return {"pid": 7, "exitCode": 0, "interrupted": False}

            with patch.dict(launcher.os.environ, {"DEEPSEEK_API_KEY": "secret"}, clear=True):
                result = launcher.run_cases(output_dir=root, corpus_path=Path("continuity.json"), scenarios=[scenario("case")], run_phase_fn=fake_phase)
            phases = result["cases"][0]["phases"]
            self.assertTrue(phases[0]["reportValid"])
            self.assertFalse(phases[1]["reportValid"])
            self.assertEqual(phases[1]["invalidReason"], "recall_reused_establishment_process")

    def test_unknown_exit_keeps_owned_root(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)

            def still_running(_command, **_kwargs):
                return {"pid": 99, "exitCode": None, "interrupted": False}

            with patch.dict(launcher.os.environ, {"DEEPSEEK_API_KEY": "secret"}, clear=True):
                with self.assertRaises(launcher.LauncherError):
                    launcher.run_cases(output_dir=output, corpus_path=Path("continuity.json"), scenarios=[scenario("case")], run_phase_fn=still_running)
            result = json.loads((output / "run-report.json").read_text(encoding="utf-8"))
            owned_root = Path(result["cases"][0]["root"])
            self.assertTrue(owned_root.exists())
            shutil.rmtree(owned_root)

    def test_per_case_and_global_limits_are_enforced(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            ledger = root / "budget.json"
            first = launcher.reserve_phase(ledger, run_id="one", case_id="one", phase="establish", cap=6, report=root / "one-a", log=root / "one-a.log")
            launcher.settle_phase(ledger, first, report_valid=True, used=6)
            with self.assertRaises(launcher.LauncherError):
                launcher.reserve_phase(ledger, run_id="one", case_id="one", phase="recall", cap=3, report=root / "one-b", log=root / "one-b.log")
            phase = launcher.reserve_phase(ledger, run_id="one", case_id="one", phase="recall", cap=2, report=root / "one-b", log=root / "one-b.log")
            launcher.settle_phase(ledger, phase, report_valid=True, used=2)
            for index in range(2, 5):
                case = str(index)
                phase = launcher.reserve_phase(ledger, run_id=case, case_id=case, phase="establish", cap=6, report=root / f"{case}-a", log=root / f"{case}-a.log")
                launcher.settle_phase(ledger, phase, report_valid=True, used=6)
                phase = launcher.reserve_phase(ledger, run_id=case, case_id=case, phase="recall", cap=2, report=root / f"{case}-b", log=root / f"{case}-b.log")
                launcher.settle_phase(ledger, phase, report_valid=True, used=2)
            with self.assertRaises(launcher.LauncherError):
                launcher.reserve_phase(ledger, run_id="five", case_id="five", phase="establish", cap=1, report=root / "five", log=root / "five.log")

    def test_case_cap_four_reserves_two_for_each_phase(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            ledger = root / "budget.json"
            establish = launcher.reserve_phase(ledger, run_id="run", case_id="case", phase="establish", cap=2, case_limit=4, report=root / "establish", log=root / "establish.log")
            launcher.settle_phase(ledger, establish, report_valid=True, used=2)
            recall = launcher.reserve_phase(ledger, run_id="run", case_id="case", phase="recall", cap=2, case_limit=4, report=root / "recall", log=root / "recall.log")
            launcher.settle_phase(ledger, recall, report_valid=True, used=2)
            self.assertEqual(launcher.ledger_committed(json.loads(ledger.read_text(encoding="utf-8"))), 4)

    def test_failed_final_report_keeps_observed_usage_separate_from_held_budget(self):
        with tempfile.TemporaryDirectory() as directory:
            def failed_phase(_command, *, environment, report_path, **_kwargs):
                report_path.write_text(json.dumps({
                    "status": "failed", "finishedAt": "now", "requestAuthorizationCount": 3,
                }), encoding="utf-8")
                return {"pid": 99, "exitCode": 65, "interrupted": False}

            with patch.dict(launcher.os.environ, {"DEEPSEEK_API_KEY": "secret"}, clear=True):
                result = launcher.run_cases(output_dir=Path(directory), corpus_path=Path("continuity.json"),
                                            scenarios=[scenario("case")], run_phase_fn=failed_phase)
            self.assertEqual(result["settledAuthorizations"], 0)
            self.assertEqual(result["heldAuthorizations"], 6)
            self.assertEqual(result["accountedAuthorizations"], 6)
            self.assertEqual(result["reportedAuthorizations"], 3)
            self.assertTrue(result["reportedAuthorizationsComplete"])
            self.assertEqual(len(result["cases"][0]["phases"]), 1)

    def test_recovery_imports_alias_paths_and_preserves_historical_budget(self):
        scenarios = launcher.load_scenarios(launcher.DEFAULT_CORPUS)
        prior_actual = {scenario["id"]: (2 if scenario["mode"] == "automatic" else 4) for scenario in scenarios}
        self.assertEqual(launcher.recovery_caps(2), (5, 6))
        self.assertEqual(launcher.recovery_caps(4), (3, 4))
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            prior = base / "prior"
            prior.mkdir()
            cases = []
            raw_paths = []
            roots = []
            for index, scenario_value in enumerate(scenarios):
                case_id = scenario_value["id"]
                root = base / f"root-{index}"
                (root / "Library").mkdir(parents=True)
                (root / "identity.json").write_text("{}", encoding="utf-8")
                alias = base / f"alias-{index}"
                alias.symlink_to(root, target_is_directory=True)
                run_id = f"00000000-0000-4000-8000-{index + 1:012d}"
                raw = {
                    "version": 1, "phase": "establish", "identity": {
                        "caseID": case_id, "runID": run_id, "root": str(alias), "language": scenario_value["language"],
                        "mode": scenario_value["mode"], "input": scenario_value["input"], "followUp": scenario_value["followUp"],
                        "asksForSource": scenario_value["asksForSource"],
                        "providerID": "deepseek", "modelID": "deepseek-flash", "endpoint": "https://api.deepseek.com",
                        "protocolID": "chat.completions", "contextWindow": 1000000, "outputTokens": 8192, "embeddings": "local",
                    }, "phase": "establish", "status": "completed", "closeSettled": True, "mismatches": [], "finishedAt": "now",
                    "processID": 100 + index, "processInstanceID": f"prior-{index}", "requestAuthorizationCap": 6,
                    "requestAuthorizationCount": prior_actual[case_id],
                }
                raw_path = prior / f"{case_id}.establish.json"
                raw_path.write_text(json.dumps(raw), encoding="utf-8")
                raw_paths.append(raw_path)
                roots.append(root)
                cases.append({"caseID": case_id, "runID": run_id, "root": str(root), "phases": [{"phase": "establish", "report": str(raw_path), "xcodebuildExitCode": 0, "requestAuthorizationCap": 6}]})
            (prior / "run-report.json").write_text(json.dumps({"version": 1, "finishedAt": "now", "cases": cases}), encoding="utf-8")

            def fake_recovery(_command, *, environment, report_path, **_kwargs):
                cap = int(environment["TEST_RUNNER_MIRA_EVAL_REQUEST_AUTHORIZATION_CAP"])
                report_path.write_text(json.dumps({
                    "version": 1, "phase": environment["TEST_RUNNER_MIRA_CONTINUITY_PHASE"], "identity": {"caseID": environment["TEST_RUNNER_MIRA_EVAL_CASE_IDS"], "runID": environment["TEST_RUNNER_MIRA_CONTINUITY_RUN_ID"], "root": environment["TEST_RUNNER_MIRA_CONTINUITY_ROOT"]},
                    "status": "completed", "closeSettled": True, "mismatches": [], "finishedAt": "now", "processID": 500 + cap,
                    "processInstanceID": f"recall-{cap}", "requestAuthorizationCap": cap, "requestAuthorizationCount": cap,
                }), encoding="utf-8")
                return {"pid": 700 + cap, "exitCode": 0, "interrupted": False}

            for root in roots:
                shutil.rmtree(root)
            output = base / "recovery-output"
            output.mkdir()
            with patch.dict(launcher.os.environ, {"DEEPSEEK_API_KEY": "secret"}, clear=True):
                result = launcher.run_cases(output_dir=output, corpus_path=launcher.DEFAULT_CORPUS, scenarios=scenarios, prior_run=prior, run_phase_fn=fake_recovery)
            self.assertEqual(result["settledAuthorizations"], 32)
            self.assertEqual(result["accountedAuthorizations"], 32)
            self.assertEqual(result["reportedAuthorizations"], 32)
            self.assertTrue(result["reportedAuthorizationsComplete"])
            self.assertEqual(len(json.loads((output / "budget-ledger.json").read_text(encoding="utf-8"))["entries"]), 12)
            self.assertTrue(all(path.exists() for path in raw_paths))
            original = json.loads(raw_paths[0].read_text(encoding="utf-8"))
            missing_flag = json.loads(json.dumps(original))
            del missing_flag["identity"]["asksForSource"]
            raw_paths[0].write_text(json.dumps(missing_flag), encoding="utf-8")
            with self.assertRaises(launcher.LauncherError):
                launcher.load_prior_establishments(prior, scenarios)
            mismatched_flag = json.loads(json.dumps(original))
            mismatched_flag["identity"]["asksForSource"] = not original["identity"]["asksForSource"]
            raw_paths[0].write_text(json.dumps(mismatched_flag), encoding="utf-8")
            with self.assertRaises(launcher.LauncherError):
                launcher.load_prior_establishments(prior, scenarios)
            raw_paths[0].write_text(json.dumps(original), encoding="utf-8")
            with patch.dict(launcher.os.environ, {"DEEPSEEK_API_KEY": "secret"}, clear=True):
                second = base / "second-recovery"
                second.mkdir()
                with self.assertRaises(FileExistsError):
                    launcher.run_cases(output_dir=second, corpus_path=launcher.DEFAULT_CORPUS, scenarios=scenarios, prior_run=prior, run_phase_fn=fake_recovery)
            self.assertTrue(all(not root.exists() for root in roots))
            self.assertTrue(all(not Path(case["root"]).exists() for case in result["cases"]))


if __name__ == "__main__":
    unittest.main()
