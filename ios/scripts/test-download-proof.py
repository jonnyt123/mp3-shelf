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
import uuid
import copy
import sys

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
            "schema": "mp3-shelf-download-proof-v2", "status": "PASS", "selection": "automatic",
            "mode": "live-download", "expectedDurationSeconds": 206, "restartPlaybackSeconds": 0.4,
            "runID": str(uuid.uuid4()), "initialProcessToken": str(uuid.uuid4()),
            "restartProcessToken": str(uuid.uuid4()), "trackID": str(uuid.uuid4()), "playlistID": str(uuid.uuid4()),
            "networkMode": "foreground-http-denied; discovery-disabled; transfers-not-attached", "blockedNetworkRequests": 0, "networkGuardVerified": True,
            "filePath": str(self.audio), "fileBytes": self.audio.stat().st_size,
            "sha256": hashlib.sha256(self.audio.read_bytes()).hexdigest(),
            "decodedFrames": 9084600, "durationSeconds": 206,
            "steps": [{"stage": name} for name in ["search", "match", "resolved-and-queued",
                "saved-mp3", "full-decode", "local-playback", "storage-failure-rejected", "ready-for-restart",
                "restart", "offline-guard-verified", "restored-library", "restart-local-playback"]],
        }

    def validate(self):
        path = self.root / "result.json"
        path.write_text(json.dumps(self.report))
        VALIDATOR.validate(path, self.container, self.root / "output")

    def test_valid_receipt_copies_exact_saved_bytes(self):
        self.validate()
        self.assertEqual((self.root / "output/Carefree-Kevin-MacLeod-proof.mp3").read_bytes(), self.audio.read_bytes())

    def test_failed_or_running_result_cannot_pass(self):
        for status in ["FAIL", "RUNNING", "UNKNOWN", "READY_FOR_RESTART"]:
            self.report["status"] = status
            with self.assertRaises(ValueError): self.validate()

    def test_missing_stage_or_corrupt_file_cannot_pass(self):
        self.report["steps"].pop()
        with self.assertRaises(ValueError): self.validate()
        self.report["steps"].append({"stage": "restart-local-playback"})
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

    def test_old_receipt_same_process_or_network_attempt_cannot_pass(self):
        baseline = copy.deepcopy(self.report)
        for field, value in [("schema", "mp3-shelf-download-proof-v1"),
                             ("restartProcessToken", self.report["initialProcessToken"]),
                             ("networkMode", "network-enabled"), ("blockedNetworkRequests", 1),
                             ("networkGuardVerified", False),
                             ("blockedNetworkRequests", False), ("restartPlaybackSeconds", 0),
                             ("restartPlaybackSeconds", float("nan"))]:
            self.report = copy.deepcopy(baseline)
            self.report[field] = value
            with self.subTest(field=field, value=value), self.assertRaises(ValueError): self.validate()

    def test_missing_restart_stage_and_wrong_stage_order_cannot_pass(self):
        baseline = copy.deepcopy(self.report)
        for stage in ["storage-failure-rejected", "ready-for-restart", "restart", "offline-guard-verified", "restored-library", "restart-local-playback"]:
            self.report = copy.deepcopy(baseline)
            self.report["steps"] = [s for s in self.report["steps"] if s["stage"] != stage]
            with self.subTest(stage=stage), self.assertRaises(ValueError): self.validate()
        self.report = baseline
        self.report["steps"][0], self.report["steps"][-1] = self.report["steps"][-1], self.report["steps"][0]
        with self.assertRaises(ValueError): self.validate()

    def test_fixture_receipt_is_separate_from_live_download(self):
        self.report.update(mode="local-import-restart", selection="local-fixture", durationSeconds=0.2,
                           expectedDurationSeconds=0.2, decodedFrames=8820, restartPlaybackSeconds=0.1)
        self.report["steps"] = [{"stage": "local-fixture-import"}] + self.report["steps"][3:]
        self.validate()
        self.assertTrue((self.root / "output/Offline-restart-fixture-proof.mp3").exists())
        report_path = self.root / "result.json"
        with self.assertRaises(ValueError):
            VALIDATOR.validate(report_path, self.container, self.root / "output", expected_mode="live-download")
        with self.assertRaises(ValueError):
            VALIDATOR.validate(report_path, self.container, self.root / "output", expected_run=str(uuid.uuid4()))

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


class RestartWorkflowTests(unittest.TestCase):
    """Fake Apple commands/receipts exercise the shell only; no native app runs."""
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="mp3-restart-workflow-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.candidate = self.root / "candidate with spaces"
        self.scripts = self.candidate / "ios/scripts"
        self.scripts.mkdir(parents=True)
        for name in ["prove-download-path.sh", "validate-download-proof.py"]:
            shutil.copy2(HERE / name, self.scripts / name)
        fixtures = self.candidate / "ios/Tests/Fixtures"
        fixtures.mkdir(parents=True)
        (fixtures / "valid-mp3.mp3").write_bytes(b"fake fixture for shell staging only")
        self.tools = self.root / "tools"
        self.tools.mkdir()
        self.env = dict(os.environ, PATH=str(self.tools) + os.pathsep + os.environ["PATH"],
                        MOCK_PROOF_CONTAINER=str(self.root / "container"), MOCK_PROOF_LOG=str(self.root / "calls.jsonl"))
        self.tool("uname", "#!/bin/sh\necho Darwin\n")
        self.tool("xcodebuild", f"#!{sys.executable}\n" + '''
import pathlib, plistlib, sys
args=sys.argv[1:]
root=pathlib.Path(args[args.index('-derivedDataPath')+1])
app=root/'Build/Products/Debug-iphonesimulator/MP3Shelf.app'
app.mkdir(parents=True)
(app/'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'com.jonnyt.mp3shelf.downloadproof'}))
''')
        self.tool("xcrun", f"#!{sys.executable}\n" + '''
import hashlib, json, os, pathlib, sys, uuid
args=sys.argv[1:]
with open(os.environ['MOCK_PROOF_LOG'],'a') as log: log.write(json.dumps(args)+'\\n')
container=pathlib.Path(os.environ['MOCK_PROOF_CONTAINER'])
documents=container/'Documents'; documents.mkdir(parents=True,exist_ok=True)
command=args[1]
mode=os.environ.get('MOCK_PROOF_FAILURE','')
if command=='list': print(json.dumps({'devices':{'test':[{'udid':'test-phone','name':'iPhone Test','isAvailable':True,'state':'Booted'}]}}))
elif command=='get_app_container': print(container)
elif command=='launch':
    result=documents/'MP3ShelfDownloadProof.json'
    if '--mp3shelf-prove-offline-restart' in args:
        report=json.loads(result.read_text())
        report.update(status='FAIL' if mode=='restart-fails' else 'PASS',restartProcessToken=str(uuid.uuid4()),
            networkMode='foreground-http-denied; discovery-disabled; transfers-not-attached',
            blockedNetworkRequests=1 if mode=='network-attempt' else 0,networkGuardVerified=True,
            restartPlaybackSeconds=0.1 if report['mode']=='local-import-restart' else 0.4)
        report['steps'] += [{'stage':s} for s in ['restart','offline-guard-verified','restored-library','restart-local-playback']]
        if mode=='same-process': report['restartProcessToken']=report['initialProcessToken']
        if mode=='restart-fails': report['error']='Injected restart playback failure'
        if mode=='corrupt-file': pathlib.Path(report['filePath']).write_bytes(b'bad')
    else:
        local='--mp3shelf-prove-local-restart' in args
        audio=documents/'saved.mp3'; audio.write_bytes(b'fake saved bytes, not an actual MP3')
        first=['local-fixture-import'] if local else ['search','match','resolved-and-queued']
        report={'schema':'mp3-shelf-download-proof-v2','status':'PASS' if mode=='premature-pass' else 'READY_FOR_RESTART',
            'mode':'local-import-restart' if local else 'live-download','selection':'local-fixture' if local else 'automatic',
            'runID':args[args.index('--mp3shelf-proof-run')+1],'initialProcessToken':str(uuid.uuid4()),
            'trackID':str(uuid.uuid4()),'playlistID':str(uuid.uuid4()),'filePath':str(audio),'fileBytes':audio.stat().st_size,
            'sha256':hashlib.sha256(audio.read_bytes()).hexdigest(),'decodedFrames':8820 if local else 9084600,
            'durationSeconds':0.2 if local else 206,'expectedDurationSeconds':0.2 if local else 206,
            'steps':[{'stage':s} for s in first+['saved-mp3','full-decode','local-playback','storage-failure-rejected','ready-for-restart']]}
    result.write_text(json.dumps(report))
''')

    def tool(self, name, content):
        path = self.tools / name
        path.write_text(content)
        path.chmod(0o755)

    def run_proof(self, *arguments, failure=""):
        return subprocess.run(["/bin/bash", str(self.scripts / "prove-download-path.sh"), *arguments],
            cwd=self.candidate, env=dict(self.env, MOCK_PROOF_FAILURE=failure), text=True,
            capture_output=True, timeout=20)

    def test_both_modes_require_terminate_and_second_launch(self):
        for arguments, folder, mode in [((), "download-proof", "live-download"),
                                        (("--offline-restart",), "offline-restart-proof", "local-import-restart")]:
            with self.subTest(mode=mode):
                result = self.run_proof(*arguments)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                report = self.candidate / "ios/build" / folder / "QA_RECORD.md"
                self.assertIn("Result: PASS", report.read_text())
                self.assertIn("Proof mode: " + mode, report.read_text())
        calls = [json.loads(line) for line in (self.root / "calls.jsonl").read_text().splitlines()]
        launches = [i for i, call in enumerate(calls) if call[1] == "launch"]
        self.assertEqual(len(launches), 4)
        for first, second in [(launches[0], launches[1]), (launches[2], launches[3])]:
            self.assertTrue(any(call[1] == "terminate" for call in calls[first + 1:second]))
            self.assertIn("--mp3shelf-prove-offline-restart", calls[second])
            token_index = calls[first].index("--mp3shelf-proof-run") + 1
            second_index = calls[second].index("--mp3shelf-proof-run") + 1
            self.assertEqual(calls[first][token_index], calls[second][second_index])
        for call in calls:
            if call[1] in {"uninstall", "terminate"}:
                self.assertEqual(call[-1], "com.jonnyt.mp3shelf.downloadproof")

    def test_first_launch_cannot_pass_without_restart(self):
        result = self.run_proof(failure="premature-pass")
        self.assertEqual(result.returncode, 1)
        self.assertIn("fresh-process restart is required", result.stderr)

    def test_restart_failure_network_or_changed_file_never_pass(self):
        for failure in ["restart-fails", "same-process", "network-attempt", "corrupt-file"]:
            with self.subTest(failure=failure):
                result = self.run_proof(failure=failure)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                report = self.candidate / "ios/build/download-proof/QA_RECORD.md"
                self.assertIn("Result: FAIL", report.read_text())


if __name__ == "__main__": unittest.main()
