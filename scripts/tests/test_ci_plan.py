"""Routing and event-boundary tests for the conservative CI planner."""

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "ci_plan.py"
SPEC = importlib.util.spec_from_file_location("ci_plan", SCRIPT)
ci_plan = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ci_plan)


class ClassifierTests(unittest.TestCase):
    def test_module_boundaries_route_expected_checks(self):
        cases = {
            "Packages/MiraKit/Sources/MiraCore/Thing.swift": (True, True, False, True, False),
            "Apps/MiraMac/Views/Thing.swift": (False, True, False, True, False),
            "Apps/MiraMac/DesignSystem/MiraTheme.swift": (False, True, False, True, True),
            "scripts/render_app_icon.py": (False, False, True, True, False),
            "scripts/export_design_tokens.py": (False, False, True, True, True),
            "designs/mira-ui/tokens.json": (False, False, False, False, True),
            "Tests/MiraLocalizationTests/LocaleTests.swift": (False, True, False, True, False),
            "docs/product/WORKSPACE_AND_CONVERSATION.md": (False, False, False, False, False),
        }
        for path, expected in cases.items():
            with self.subTest(path=path):
                plan = ci_plan.classify_paths([path])
                self.assertEqual(tuple(plan[key] for key in ci_plan.CHECKS), expected)
                self.assertTrue(plan["reason"])

    def test_global_and_unknown_paths_force_every_check(self):
        for path in (
            "project.yml", "Mira.xcodeproj/project.pbxproj", ".github/workflows/ci.yml",
            "Vendor/Library/file.swift", "Tests/Fixtures/input.json", "Tests/Unknown/Test.swift",
            "scripts/ci_plan.py", "scripts/tests/test_ci_plan.py", "scripts/check_language_policy.py",
            "Packages/Other/Package.swift", "docs/tool.py", "designs/demo.js", "mystery.bin", "nested/README.md",
            "nested/LICENSE", "nested/AGENTS.md",
        ):
            with self.subTest(path=path):
                plan = ci_plan.classify_paths([path])
                self.assertEqual({key: plan[key] for key in ci_plan.CHECKS}, ci_plan.FULL)

    def test_mixed_changes_union_partial_routes_and_reason_is_deduplicated(self):
        plan = ci_plan.classify_paths([
            "Apps/MiraMac/A.swift", "Apps/MiraMac/B.swift", "designs/mira-ui/tokens.json",
        ])
        self.assertEqual(
            {key: plan[key] for key in ci_plan.CHECKS},
            {"package": False, "macos": True, "scripts": False, "language": True, "tokens": True},
        )
        self.assertEqual(plan["reason"].count("macOS app source changed"), 1)

    def test_deleted_and_renamed_path_representations_are_routed(self):
        plan = ci_plan.classify_paths(["old/unknown.bin", "Apps/MiraMac/New.swift"])
        self.assertEqual({key: plan[key] for key in ci_plan.CHECKS}, ci_plan.FULL)
        self.assertEqual(ci_plan.classify_paths(["scripts/old.py"])["scripts"], True)

    def test_empty_or_unsafe_paths_fail_closed(self):
        for paths in ([], [""], ["../outside.swift"], ["/absolute/file"], ["Apps\\MiraMac\\x.swift"], [None]):
            with self.subTest(paths=paths):
                self.assertEqual({key: ci_plan.classify_paths(paths)[key] for key in ci_plan.CHECKS}, ci_plan.FULL)


class EventAndOutputTests(unittest.TestCase):
    def test_pull_request_uses_full_three_dot_diff_and_decodes_nul_paths(self):
        base, head = "a" * 40, "B" * 40
        with tempfile.TemporaryDirectory() as directory:
            event_file = Path(directory) / "event.json"
            event_file.write_text(json.dumps({"pull_request": {"base": {"sha": base}, "head": {"sha": head}}}))
            completed = subprocess.CompletedProcess([], 0, b"Apps/MiraMac/View.swift\0", b"")
            with patch.object(ci_plan.subprocess, "run", return_value=completed) as run:
                plan = ci_plan._event_plan("pull_request", event_file)
        self.assertTrue(plan["macos"])
        self.assertTrue(plan["language"])
        run.assert_called_once_with(
            ["git", "diff", "--name-only", "--no-renames", "-z", f"{base}...{head}"],
            check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )

    def test_manual_dispatch_and_bad_event_inputs_force_full_checks(self):
        self.assertEqual(ci_plan._event_plan("workflow_dispatch", "unused"), ci_plan.full_plan("Manual workflow dispatch"))
        self.assertEqual({key: ci_plan._event_plan("push", "unused")[key] for key in ci_plan.CHECKS}, ci_plan.FULL)
        with tempfile.TemporaryDirectory() as directory:
            event_file = Path(directory) / "event.json"
            for payload in (
                "{", json.dumps({"pull_request": {"base": {"sha": "bad"}, "head": {"sha": "a" * 40}}}),
            ):
                event_file.write_text(payload)
                with self.subTest(payload=payload):
                    plan = ci_plan._event_plan("pull_request", event_file)
                    self.assertEqual({key: plan[key] for key in ci_plan.CHECKS}, ci_plan.FULL)
            missing_file = Path(directory) / "missing.json"
            missing_plan = ci_plan._event_plan("pull_request", missing_file)
            self.assertEqual({key: missing_plan[key] for key in ci_plan.CHECKS}, ci_plan.FULL)
            self.assertIn("missing or malformed", missing_plan["reason"])
        with patch.object(ci_plan.subprocess, "run", side_effect=subprocess.CalledProcessError(1, "git")):
            with tempfile.TemporaryDirectory() as directory:
                event_file = Path(directory) / "event.json"
                event_file.write_text(json.dumps({"pull_request": {"base": {"sha": "a" * 40}, "head": {"sha": "b" * 40}}}))
                plan = ci_plan._event_plan("pull_request", event_file)
        self.assertEqual({key: plan[key] for key in ci_plan.CHECKS}, ci_plan.FULL)

    def test_real_multi_commit_pr_diff_keeps_both_rename_sides_and_deletions(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)

            def git(*args):
                return subprocess.run(
                    ["git", *args], cwd=repo, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                ).stdout.decode().strip()

            git("init", "-q")
            git("config", "user.email", "ci-plan@example.invalid")
            git("config", "user.name", "CI Plan Test")
            package = repo / "Packages/MiraKit/Sources/Example/Thing.swift"
            fixture = repo / "Tests/Fixtures/removed.json"
            package.parent.mkdir(parents=True)
            fixture.parent.mkdir(parents=True)
            package.write_text("struct Thing {}\n")
            fixture.write_text("{}\n")
            git("add", "Packages", "Tests")
            git("commit", "-qm", "base")
            base = git("rev-parse", "HEAD")

            # Two commits make the test sensitive to accidentally diffing only the latest commit.
            (repo / "README.md").write_text("intermediate commit\n")
            git("add", "README.md")
            git("commit", "-qm", "intermediate")
            moved = repo / "docs/product/Thing.md"
            moved.parent.mkdir(parents=True)
            package.rename(moved)
            moved.write_text("# Thing documentation\n")
            fixture.unlink()
            git("add", "-A")
            git("commit", "-qm", "rename source and delete fixture")
            head = git("rev-parse", "HEAD")

            event_file = repo / "event.json"
            event_file.write_text(json.dumps({
                "pull_request": {"base": {"sha": base}, "head": {"sha": head}},
            }))
            raw_diff = subprocess.run(
                ["git", "diff", "--name-only", "--no-renames", "-z", f"{base}...{head}"],
                cwd=repo, check=True, stdout=subprocess.PIPE,
            ).stdout
            paths = {item.decode() for item in raw_diff[:-1].split(b"\0")}
            self.assertIn("Packages/MiraKit/Sources/Example/Thing.swift", paths)
            self.assertIn("docs/product/Thing.md", paths)
            self.assertIn("Tests/Fixtures/removed.json", paths)

            previous_cwd = Path.cwd()
            try:
                os.chdir(repo)
                plan = ci_plan._event_plan("pull_request", event_file)
            finally:
                os.chdir(previous_cwd)
            self.assertEqual({key: plan[key] for key in ci_plan.CHECKS}, ci_plan.FULL)
            self.assertIn("MiraKit source changed", plan["reason"])
            self.assertIn("Test fixtures changed", plan["reason"])

    def test_empty_truncated_and_invalid_utf8_diffs_force_full_checks(self):
        with tempfile.TemporaryDirectory() as directory:
            event_file = Path(directory) / "event.json"
            event_file.write_text(json.dumps({
                "pull_request": {"base": {"sha": "a" * 40}, "head": {"sha": "b" * 40}},
            }))
            for output in (b"", b"Apps/MiraMac/View.swift", b"Apps/MiraMac/\xff.swift\0"):
                with self.subTest(output=output), patch.object(
                    ci_plan.subprocess, "run",
                    return_value=subprocess.CompletedProcess([], 0, output, b""),
                ):
                    plan = ci_plan._event_plan("pull_request", event_file)
                    self.assertEqual({key: plan[key] for key in ci_plan.CHECKS}, ci_plan.FULL)

    def test_output_files_contain_booleans_and_summary_without_filenames(self):
        plan = ci_plan.classify_paths(["Apps/MiraMac/Some secret.swift"])
        with tempfile.TemporaryDirectory() as directory:
            output, summary = Path(directory) / "output", Path(directory) / "summary"
            with patch.dict("os.environ", {"GITHUB_OUTPUT": str(output), "GITHUB_STEP_SUMMARY": str(summary)}):
                ci_plan._write_outputs(plan)
            contents = output.read_text()
            self.assertIn("package=false\n", contents)
            self.assertIn("macos=true\n", contents)
            self.assertIn("tokens=false\n", contents)
            self.assertNotIn("Some secret.swift", contents + summary.read_text())


if __name__ == "__main__":
    unittest.main()
