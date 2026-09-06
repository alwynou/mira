"""Process ownership checks must survive macOS temporary-directory aliases."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "rendering_benchmark", Path(__file__).resolve().parents[1] / "run_rendering_benchmark.py"
)
benchmark = importlib.util.module_from_spec(spec)
spec.loader.exec_module(benchmark)


class ProcessOwnershipTests(unittest.TestCase):
    def test_matches_canonical_executable_through_directory_alias(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            real = root / "actual directory"
            real.mkdir()
            alias = root / "alias"
            alias.symlink_to(real, target_is_directory=True)
            executable = real / "MiraPerformanceCheck.app/Contents/MacOS/Mira"
            output = f"123 {executable.resolve()} --demo --native-rendering-benchmark --data-directory /fixture\n"
            with patch.object(benchmark, "run", return_value=subprocess.CompletedProcess([], 0, stdout=output)):
                self.assertEqual(benchmark.matching_processes(alias / "MiraPerformanceCheck.app/Contents/MacOS/Mira"), [123])

    def test_never_targets_another_app_or_a_nonbenchmark_launch(self):
        executable = Path("/tmp/owned/MiraPerformanceCheck.app/Contents/MacOS/Mira")
        output = "\n".join([
            f"123 {executable} --demo --native-rendering-benchmark --data-directory /owned",
            "124 /tmp/other/MiraPerformanceCheck.app/Contents/MacOS/Mira --demo --native-rendering-benchmark --data-directory /other",
            f"125 {executable} --demo --data-directory /owned",
            f"126 {executable} --native-rendering-benchmark --data-directory /owned",
            "127 /Applications/Mira.app/Contents/MacOS/Mira",
        ])
        with patch.object(benchmark, "run", return_value=subprocess.CompletedProcess([], 0, stdout=output)):
            self.assertEqual(benchmark.matching_processes(executable), [123])

    def test_process_inspection_failure_is_not_treated_as_no_process(self):
        with patch.object(benchmark, "run", side_effect=subprocess.CalledProcessError(1, ["ps"])):
            with self.assertRaises(subprocess.CalledProcessError):
                benchmark.matching_processes(Path("/tmp/owned/Mira"))


if __name__ == "__main__":
    unittest.main()
