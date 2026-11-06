#!/usr/bin/env python3
"""Receipt/workflow tests only; these do not stand in for a native download."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

HERE = Path(__file__).parent
SPEC = importlib.util.spec_from_file_location("proof_validator", HERE / "validate-download-proof.py")
VALIDATOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VALIDATOR)


class DownloadProofTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="mp3-proof-tests-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.container = self.root / "container"
        self.container.mkdir()
        self.audio = self.container / "saved.mp3"
        self.audio.write_bytes(b"test bytes for receipt validation, not an actual MP3")
        self.report = {
            "schema": "mp3-shelf-download-proof-v1", "status": "PASS", "selection": "automatic",
            "filePath": str(self.audio), "fileBytes": self.audio.stat().st_size,
            "sha256": hashlib.sha256(self.audio.read_bytes()).hexdigest(),
            "decodedFrames": 9084600, "durationSeconds": 206,
            "steps": [{"stage": name} for name in ["search", "match", "resolved-and-queued",
                                                   "saved-mp3", "full-decode", "local-playback"]],
        }

    def validate(self):
        path = self.root / "result.json"
        path.write_text(json.dumps(self.report))
        VALIDATOR.validate(path, self.container, self.root / "output")

    def test_valid_receipt_copies_exact_saved_bytes(self):
        self.validate()
        self.assertEqual((self.root / "output/Carefree-Kevin-MacLeod-proof.mp3").read_bytes(), self.audio.read_bytes())

    def test_failed_or_running_result_cannot_pass(self):
        for status in ["FAIL", "RUNNING", "UNKNOWN"]:
            self.report["status"] = status
            with self.assertRaises(ValueError): self.validate()

    def test_missing_stage_or_corrupt_file_cannot_pass(self):
        self.report["steps"].pop()
        with self.assertRaises(ValueError): self.validate()
        self.report["steps"].append({"stage": "local-playback"})
        self.audio.write_bytes(b"x" * self.audio.stat().st_size)
        with self.assertRaises(ValueError): self.validate()

    def test_path_outside_test_container_is_rejected(self):
        outside = self.root / "private.mp3"
        outside.write_bytes(self.audio.read_bytes())
        self.report["filePath"] = str(outside)
        with self.assertRaises(ValueError): self.validate()

    def test_missing_selection_wrong_duration_or_nan_is_rejected(self):
        self.report["selection"] = "unknown"
        with self.assertRaises(ValueError): self.validate()
        self.report["selection"] = "reference-review"
        for duration in [0, 30, float("nan")]:
            self.report["durationSeconds"] = duration
            with self.assertRaises(ValueError): self.validate()
        self.report["durationSeconds"] = 206
        self.report["decodedFrames"] = float("nan")
        with self.assertRaises(ValueError): self.validate()

    def test_failed_preflight_replaces_stale_pass_report(self):
        candidate = self.root / "candidate with spaces"
        script = candidate / "ios/scripts/prove-download-path.sh"
        script.parent.mkdir(parents=True)
        shutil.copy2(HERE / script.name, script)
        report = candidate / "ios/build/download-proof/QA_RECORD.md"
        report.parent.mkdir(parents=True)
        report.write_text("STALE PASS")
        tools = self.root / "tools"
        tools.mkdir()
        (tools / "uname").write_text("#!/bin/sh\necho Linux\n")
        (tools / "uname").chmod(0o755)
        result = subprocess.run(["/bin/bash", str(script)], cwd=candidate,
            env=dict(os.environ, PATH=str(tools) + os.pathsep + os.environ["PATH"]),
            capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 2)
        self.assertIn("Result: FAIL", report.read_text())
        self.assertNotIn("STALE PASS", report.read_text())


if __name__ == "__main__": unittest.main()
