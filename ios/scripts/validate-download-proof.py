#!/usr/bin/env python3
"""Validate a native proof receipt and copy its verified file from that container."""
import hashlib
import json
import math
from pathlib import Path
import sys
from tempfile import TemporaryDirectory
from urllib.parse import urlsplit
import uuid


def validate(report_path, container, destination, expected_run=None, expected_mode=None):
    report = json.loads(Path(report_path).read_text())
    if report.get("schema") != "mp3-shelf-download-proof-v2" or report.get("status") != "PASS":
        raise ValueError(report.get("error", "Native download proof has not passed"))
    mode = report.get("mode")
    first_stages = {
        "live-download": ["queue-write-failure-rejected", "search", "match", "resolved-and-queued"],
        "local-import-restart": ["local-fixture-import"],
        "fixture-transfer": ["queue-write-failure-rejected", "obsolete-fixture-cancelled", "fixture-queued", "fixture-downloaded"],
    }
    if mode not in first_stages or (expected_mode is not None and mode != expected_mode):
        raise ValueError("The proof mode is missing or does not match this runner")
    required = first_stages[mode] + ["saved-mp3", "full-decode", "local-playback", "existing-recording-reused", "storage-failure-rejected",
        "ready-for-restart", "restart", "offline-guard-verified", "restored-library", "restart-local-playback"]
    actual = [item.get("stage") for item in report.get("steps", [])]
    if not set(required) <= set(actual):
        raise ValueError("The native receipt is missing required pipeline stages")
    positions = [actual.index(stage) for stage in required]
    if positions != sorted(positions):
        raise ValueError("The native receipt stages are out of order")
    for field in ["runID", "initialProcessToken", "restartProcessToken", "trackID", "playlistID"]:
        value = report.get(field)
        if not isinstance(value, str):
            raise ValueError("The native receipt is missing a valid " + field)
        uuid.UUID(value)
    if expected_run is not None and report["runID"] != expected_run:
        raise ValueError("The native receipt belongs to a different run")
    if report["initialProcessToken"] == report["restartProcessToken"]:
        raise ValueError("Playback was not tested in a fresh process")
    if report.get("networkMode") != "foreground-http-denied; discovery-disabled; transfers-not-attached":
        raise ValueError("The restart phase did not enable its isolated offline guard")
    if report.get("networkGuardVerified") is not True:
        raise ValueError("The restart phase did not verify that its HTTP guard works")
    if type(report.get("blockedNetworkRequests")) is not int or report["blockedNetworkRequests"] != 0:
        raise ValueError("The restart phase attempted an HTTP request")
    selections = {"live-download": {"automatic", "reference-review"},
                  "local-import-restart": {"local-fixture"}, "fixture-transfer": {"fixture-transfer"}}
    if report.get("selection") not in selections[mode]:
        raise ValueError("The recording-selection mode is missing")
    source = Path(report["filePath"]).resolve()
    if not source.is_relative_to(Path(container).resolve()) or source.suffix.lower() != ".mp3":
        raise ValueError("MP3 path is outside the isolated test container")
    size = source.stat().st_size
    if not 0 < size <= 100 * 1024 * 1024 or size != report.get("fileBytes"):
        raise ValueError("Saved file size does not match the native receipt")
    duration = report.get("durationSeconds", 0)
    expected_duration = report.get("expectedDurationSeconds", 0)
    frames = report.get("decodedFrames", 0)
    if mode == "live-download":
        if expected_duration != 206:
            raise ValueError("The live proof did not use the expected reference recording")
        tolerance = 4
    elif mode == "fixture-transfer":
        if expected_duration != 2:
            raise ValueError("The transfer proof did not use the two-second AAC fixture")
        tolerance = 0.15
        evidence = Path(destination) / "fixture-served.json"
        if not evidence.is_file():
            raise ValueError("No successful fixture response was recorded for this run")
        served = json.loads(evidence.read_text())
        url = urlsplit(served["url"])
        fixture = (Path(__file__).resolve().parents[1] / "Tests/Fixtures/transfer-tone.m4a").read_bytes()
        if (served["runID"] != report["runID"] or served["url"] != report.get("sourcePage")
                or url.scheme != "http" or not url.port or url.netloc != f"127.0.0.1:{url.port}"
                or url.path != f"/{report['runID']}/fixture.m4a" or url.query or url.fragment
                or served["bytes"] != len(fixture) or served["sha256"] != hashlib.sha256(fixture).hexdigest()):
            raise ValueError("The fixture response does not match the queued source and AAC bytes")
    else:
        if not math.isfinite(expected_duration) or not 0.05 <= expected_duration <= 10:
            raise ValueError("The local fixture duration is invalid")
        tolerance = 0.1
    if not isinstance(frames, int) or isinstance(frames, bool) or frames <= 0 or not math.isfinite(duration) or abs(duration - expected_duration) > tolerance:
        raise ValueError("Native full-decode evidence is invalid")
    advance = report.get("restartPlaybackSeconds", 0)
    if not math.isfinite(advance) or advance <= min(0.25, duration / 4):
        raise ValueError("Production playback did not advance after restart")
    destination = Path(destination)
    destination.mkdir(parents=True, exist_ok=True)
    names = {"live-download": "Carefree-Kevin-MacLeod-proof.mp3",
             "local-import-restart": "Offline-restart-fixture-proof.mp3",
             "fixture-transfer": "AAC-transfer-proof.mp3"}
    exported = destination / names[mode]
    # Hash the bytes as they are staged. Publish only the checked copy.
    with TemporaryDirectory(prefix=".proof-export-", dir=destination) as staging:
        staged = Path(staging) / exported.name
        digest = hashlib.sha256()
        written = 0
        with source.open("rb") as file, staged.open("wb") as output:
            for chunk in iter(lambda: file.read(65536), b""):
                written += len(chunk)
                if written > size:
                    raise ValueError("Saved file size changed during export")
                output.write(chunk)
                digest.update(chunk)
        if written != size:
            raise ValueError("Saved file size changed during export")
        if digest.hexdigest() != report.get("sha256"):
            raise ValueError("Saved MP3 does not match its native checksum")
        staged.replace(exported)
    print("PASS: native receipt stages and saved-file checksum verified; mode=" + mode + "; selection=" + report["selection"])


if __name__ == "__main__":
    try:
        validate(*sys.argv[1:])
    except (ValueError, KeyError, OSError, TypeError) as error:
        print("FAIL: " + str(error), file=sys.stderr)
        raise SystemExit(1)
