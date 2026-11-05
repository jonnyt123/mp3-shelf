#!/usr/bin/env python3
"""Exercise the real release runner with a fake toolchain in temporary folders.

These tests verify shell control flow/reporting, never Swift or iOS behavior.
No builds, signing, installation, network access or Actions are performed.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


RUNNER = Path(__file__).with_name("verify-local-release.sh")


class ReleaseWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="mp3-workflow-test-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.root = self.base / "parent" / "candidate with spaces"
        self.script = self.root / "ios/scripts/verify-local-release.sh"
        self.script.parent.mkdir(parents=True)
        shutil.copy2(RUNNER, self.script)
        self.bin = self.base / "tools"
        self.bin.mkdir()
        for command in ["mkdir", "dirname", "date", "tee", "cp", "git"]:
            (self.bin / command).symlink_to(shutil.which(command))
        (self.bin / "python3").symlink_to(sys.executable)
        self.env = dict(os.environ, PATH=str(self.bin), MOCK_PLATFORM="Linux")
        self.tool("uname", '#!/bin/sh\nprintf "%s\\n" "$MOCK_PLATFORM"\n')

    def tool(self, name, body):
        path = self.bin / name
        path.write_text(body)
        path.chmod(0o755)

    def compiler(self):
        self.tool("swiftc", f"#!{sys.executable}\n" + '''
import os, pathlib, sys
args = sys.argv[1:]
output = pathlib.Path(args[args.index("-o") + 1])
if os.environ.get("FAIL_COMPILE") == output.name:
    print("Injected compiler failure", file=sys.stderr)
    sys.exit(9)
status = 7 if os.environ.get("FAIL_SUITE") == output.name else 0
output.write_text("#!/bin/sh\\nexit " + str(status) + "\\n")
output.chmod(0o755)
''')

    def xcode(self):
        self.env["MOCK_PLATFORM"] = "Darwin"
        self.tool("xcodebuild", f"#!{sys.executable}\n" + '''
import os, sys
args = sys.argv[1:]
if "-version" in args:
    print("Mock Xcode - workflow test only")
elif os.environ.get("FAIL_BUILD") and "Release" in args and "iphonesimulator" in args:
    sys.exit(11)
''')
        self.tool("xcrun", '#!/bin/sh\nprintf \'{"devices":{}}\\n\'\n')

    def run_runner(self, *args):
        return subprocess.run(["/bin/bash", str(self.script), *args], cwd=self.root,
                              env=self.env, text=True, capture_output=True, timeout=15)

    def report(self):
        return (self.root / "ios/build/local-release/QA_RECORD.md").read_text()

    def test_missing_compiler_records_failure(self):
        result = self.run_runner("--tests-only")
        self.assertEqual(result.returncode, 2)
        self.assertIn("Failure reason: Swift compiler not found", self.report())
        self.assertIn("Completed checks: none", self.report())
        self.assertIn("Overall execution: FAIL", self.report())

    def test_conflicting_modes_rejected_in_both_orders(self):
        for args in [("--tests-only", "--builds-only"), ("--builds-only", "--tests-only")]:
            with self.subTest(args=args):
                result = self.run_runner(*args)
                self.assertEqual(result.returncode, 2)
                self.assertIn("Choose either", result.stderr)

    def test_compile_failure_identifies_step_and_stops(self):
        self.compiler()
        self.env["FAIL_COMPILE"] = "playback-order"
        self.assertEqual(self.run_runner("--tests-only").returncode, 9)
        self.assertIn("Failure reason: Compile playback-order failed", self.report())
        self.assertIn("Completed checks: none", self.report())

    def test_suite_failure_identifies_step(self):
        self.compiler()
        self.env["FAIL_SUITE"] = "playback-order"
        self.assertEqual(self.run_runner("--tests-only").returncode, 7)
        self.assertIn("Failure reason: Step playback-order failed", self.report())
        self.assertIn("Completed checks: none", self.report())

    def test_test_mode_runs_all_eight_suites(self):
        self.compiler()
        self.assertEqual(self.run_runner("--tests-only").returncode, 0)
        expected = "playback-order playback-interruptions downloaded-audio-format playlist-parser lyrics-parser authorized-audio-sources discovery-resume portable-backup"
        self.assertIn("Completed checks: " + expected, self.report())
        self.assertIn("Failure reason: none", self.report())
        self.assertIn("physical iPhone acceptance: NOT TESTED", self.report())

    def test_build_only_does_not_require_separate_swift_command(self):
        self.xcode()
        self.assertEqual(self.run_runner("--builds-only").returncode, 0)
        self.assertIn("Completed checks: simulator-debug simulator-release iphoneos-arm64-release", self.report())

    def test_failed_build_preserves_prior_steps_only(self):
        self.xcode()
        self.env["FAIL_BUILD"] = "1"
        self.assertEqual(self.run_runner("--builds-only").returncode, 11)
        self.assertIn("Failure reason: Step simulator-release failed", self.report())
        self.assertIn("Completed checks: simulator-debug\n", self.report())

    def test_extracted_archive_does_not_inherit_parent_repository_revision(self):
        subprocess.run([shutil.which("git"), "init", str(self.root.parent)],
                       check=True, capture_output=True)
        commit = "a" * 40
        (self.root / "SOURCE.json").write_text(json.dumps({"commit": commit}))
        self.assertEqual(self.run_runner("--tests-only").returncode, 2)
        self.assertIn("Checked commit: " + commit, self.report())
        self.assertIn("Source provenance: archive metadata (not independently authenticated)", self.report())
        self.assertIn("Uncommitted changes: unknown", self.report())

    def test_invalid_archive_metadata_is_not_reported_as_commit(self):
        (self.root / "SOURCE.json").write_text('["not a manifest"]')
        self.assertEqual(self.run_runner("--tests-only").returncode, 2)
        self.assertIn("Checked commit: unknown", self.report())

    def test_uncommitted_repository_still_produces_a_report(self):
        subprocess.run([shutil.which("git"), "init", str(self.root)],
                       check=True, capture_output=True)
        self.assertEqual(self.run_runner("--tests-only").returncode, 2)
        self.assertIn("Checked commit: unknown", self.report())
        self.assertIn("Source provenance: repository without a commit", self.report())

    def test_each_run_has_separate_logs(self):
        self.compiler()
        self.env["FAIL_COMPILE"] = "playback-order"
        self.assertEqual(self.run_runner("--tests-only").returncode, 9)
        del self.env["FAIL_COMPILE"]
        self.assertEqual(self.run_runner("--tests-only").returncode, 0)
        runs = list((self.root / "ios/build/local-release/runs").iterdir())
        self.assertEqual(len(runs), 2)
        reports = [(run / "QA_RECORD.md").read_text() for run in runs]
        self.assertEqual(sum("Overall execution: FAIL" in report for report in reports), 1)
        self.assertEqual(sum("Overall execution: PASS" in report for report in reports), 1)

    def test_missing_simulator_records_reason(self):
        self.compiler()
        self.xcode()
        result = self.run_runner("--smoke")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("No available iPhone Simulator could be selected", self.report())


if __name__ == "__main__":
    unittest.main(verbosity=2)
