"""Focused tests for the final GitHub Actions CI result gate."""

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "ci_result.py"
SPEC = importlib.util.spec_from_file_location("ci_result", SCRIPT)
ci_result = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ci_result)


def needs(package="success", macos="success", package_plan="true", macos_plan="true"):
    return {
        "plan": {"result": "success", "outputs": {
            "package": package_plan, "macos": macos_plan,
        }},
        "lightweight": {"result": "success"},
        "package": {"result": package},
        "macos": {"result": macos},
    }


class CIResultTests(unittest.TestCase):
    def test_full_success(self):
        self.assertEqual(ci_result.check_results(needs()), [])

    def test_app_only_package_skipped(self):
        value = needs(package="skipped", package_plan="false", macos_plan="true")
        self.assertEqual(ci_result.check_results(value), [])

    def test_docs_only_both_checks_skipped(self):
        value = needs(package="skipped", macos="skipped", package_plan="false", macos_plan="false")
        self.assertEqual(ci_result.check_results(value), [])

    def test_unplanned_job_may_run_successfully(self):
        value = needs(package="success", package_plan="false")
        self.assertEqual(ci_result.check_results(value), [])

    def test_missing_jobs_and_plan_outputs_fail(self):
        value = needs()
        del value["package"]
        del value["macos"]["result"]
        del value["plan"]["outputs"]["macos"]
        errors = ci_result.check_results(value)
        self.assertTrue(any("job: package" in error for error in errors))
        self.assertTrue(any("result for job: macos" in error for error in errors))
        self.assertTrue(any("plan output: macos" in error for error in errors))

    def test_missing_job_outputs_and_non_object_needs_fail(self):
        self.assertTrue(ci_result.check_results({"plan": {"result": "success"}}))
        self.assertTrue(ci_result.check_results([]))

    def test_plan_flags_must_be_exact_strings(self):
        for invalid in (True, False, "TRUE", "yes", None, 1):
            with self.subTest(invalid=invalid):
                value = needs(package_plan=invalid)
                self.assertTrue(any("plan output: package" in error
                                    for error in ci_result.check_results(value)))

    def test_required_planned_jobs_cannot_be_skipped(self):
        value = needs(package="skipped", macos="skipped")
        errors = ci_result.check_results(value)
        self.assertTrue(any("Planned job package" in error for error in errors))
        self.assertTrue(any("Planned job macos" in error for error in errors))

    def test_failed_cancelled_and_skipped_required_jobs_fail(self):
        for result in ("failure", "cancelled", "skipped"):
            with self.subTest(result=result):
                value = needs()
                value["plan"]["result"] = result
                value["lightweight"]["result"] = result
                value["package"]["result"] = result
                value["macos"]["result"] = result
                errors = ci_result.check_results(value)
                self.assertTrue(any("plan did not succeed" in error for error in errors))
                self.assertTrue(any("lightweight did not succeed" in error for error in errors))
                self.assertTrue(any("Planned job package" in error for error in errors))
                self.assertTrue(any("Planned job macos" in error for error in errors))

    def test_malformed_ci_needs_json_fails_cli(self):
        with tempfile.TemporaryDirectory() as directory:
            env = dict(os.environ, CI_NEEDS="{bad json", GITHUB_STEP_SUMMARY=str(Path(directory) / "summary.md"))
            result = subprocess.run(
                [sys.executable, str(SCRIPT)], env=env,
                text=True, capture_output=True, check=False,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("malformed JSON", result.stderr)
            self.assertIn("| Job | Result | Plan |", result.stdout)
            self.assertIn("## CI results", Path(env["GITHUB_STEP_SUMMARY"]).read_text())


if __name__ == "__main__":
    unittest.main()
