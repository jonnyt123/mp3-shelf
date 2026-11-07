#!/usr/bin/env python3
"""Exercise the real installer with fake Apple tools; no actual signing/install."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class DeviceInstallWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="mp3-device-workflow-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.root = self.base / "candidate with spaces"
        self.script = self.root / "ios/scripts/run-on-iphone.sh"
        self.script.parent.mkdir(parents=True)
        shutil.copy2(Path(__file__).with_name("run-on-iphone.sh"), self.script)
        self.tools = self.base / "tools"
        self.tools.mkdir()
        self.env = dict(os.environ, PATH=str(self.tools) + os.pathsep + os.environ["PATH"],
                        MP3SHELF_TEAM_ID="ABCDE12345", CALL_LOG=str(self.base / "calls"))
        self.tool("uname", '#!/bin/bash\necho Darwin\n')
        self.tool("xcodebuild", '''#!/bin/bash
echo build >> "$CALL_LOG"
if [[ "${FAIL_STEP:-}" == build ]]; then
  echo 'CodeSign MP3Shelf.app'
  echo 'MP3Shelf.app: resource fork, Finder information, or similar detritus not allowed'
  echo 'Command CodeSign failed with a nonzero exit code'
  exit 65
fi
while [[ $# -gt 0 ]]; do
  if [[ "$1" == -derivedDataPath ]]; then derived="$2"; break; fi
  shift
done
mkdir -p "$derived/Build/Products/Debug-iphoneos/MP3Shelf.app"
touch "$derived/Build/Products/Debug-iphoneos/MP3Shelf.app/embedded.mobileprovision"
''')
        self.tool("codesign", '''#!/bin/bash
if [[ "$1" == --verify && "${FAIL_STEP:-}" == signature ]]; then
 echo 'errSecInternalComponent' >&2
 exit 7
fi
''')
        self.tool("xcrun", '''#!/bin/bash
if [[ "$*" == *"device install app"* ]]; then
 echo install >> "$CALL_LOG"
 if [[ "${FAIL_STEP:-}" == install ]]; then echo 'Install refused' >&2; exit 8; fi
elif [[ "$*" == *"device process launch"* ]]; then
 echo launch >> "$CALL_LOG"
 if [[ "${FAIL_STEP:-}" == launch ]]; then echo 'Launch refused' >&2; exit 9; fi
fi
''')

    def tool(self, name, body):
        path = self.tools / name
        path.write_text(body)
        path.chmod(0o755)

    def run_script(self, *args):
        return subprocess.run(["/bin/bash", str(self.script), *args], cwd=self.root,
                              env=self.env, text=True, capture_output=True, timeout=10)

    def report(self):
        return (self.root / "ios/build/iphone-device/QA_RECORD.md").read_text()

    def test_build_failure_replaces_stale_pass_and_retains_signing_reason(self):
        path = self.root / "ios/build/iphone-device/QA_RECORD.md"
        path.parent.mkdir(parents=True)
        path.write_text("STALE PASS from yesterday")
        self.env["FAIL_STEP"] = "build"
        result = self.run_script("device-1")
        self.assertNotEqual(result.returncode, 0)
        report = self.report()
        self.assertIn("FAIL", report)
        self.assertIn("resource fork", report)
        self.assertNotIn("STALE PASS", report)
        self.assertNotIn("install", Path(self.env["CALL_LOG"]).read_text())

    def test_invalid_team_does_not_leave_an_old_pass_report(self):
        path = self.root / "ios/build/iphone-device/QA_RECORD.md"
        path.parent.mkdir(parents=True)
        path.write_text("STALE PASS")
        self.env["MP3SHELF_TEAM_ID"] = "invalid"
        result = self.run_script("device-1")
        self.assertEqual(result.returncode, 2)
        self.assertIn("FAIL", self.report())
        self.assertIn("10-character Apple team ID", self.report())

    def test_diagnostic_mode_does_not_install_or_launch(self):
        result = self.run_script("--diagnose")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(Path(self.env["CALL_LOG"]).read_text(), "build\n")
        self.assertIn("Device app installation: NOT RUN", self.report())

    def test_diagnostic_mode_can_use_the_team_already_selected_in_xcode(self):
        self.env.pop("MP3SHELF_TEAM_ID")
        result = self.run_script("--diagnose")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(Path(self.env["CALL_LOG"]).read_text(), "build\n")

    def test_signature_failure_is_not_reported_as_build_or_install_success(self):
        self.env["FAIL_STEP"] = "signature"
        result = self.run_script("device-1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Signature verification", self.report())
        self.assertIn("errSecInternalComponent", self.report())
        self.assertNotIn("install", Path(self.env["CALL_LOG"]).read_text())

    def test_install_failure_never_attempts_launch(self):
        self.env["FAIL_STEP"] = "install"
        result = self.run_script("device-1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Device installation", self.report())
        self.assertNotIn("launch", Path(self.env["CALL_LOG"]).read_text())

    def test_launch_failure_does_not_leave_pass_report(self):
        self.env["FAIL_STEP"] = "launch"
        result = self.run_script("device-1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Process launch", self.report())
        self.assertIn("FAIL", self.report())

    def test_success_preserves_per_run_report(self):
        result = self.run_script("device-1")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Device app installation: PASS", self.report())
        reports = list((self.root / "ios/build/iphone-device/runs").glob("*/QA_RECORD.md"))
        self.assertEqual(len(reports), 1)
        self.assertEqual(reports[0].read_text(), self.report())


if __name__ == "__main__":
    unittest.main()
