#!/usr/bin/env python3
"""Validate a native proof receipt and copy its verified file from that container."""
import hashlib
import json
import math
from pathlib import Path
import shutil
import sys
import uuid


def validate(report_path, container, destination, expected_run=None, expected_mode=None):
    report = json.loads(Path(report_path).read_text())
    if report.get("schema") != "mp3-shelf-download-proof-v2" or report.get("status") != "PASS":
        raise ValueError(report.get("error", "Native download proof has not passed"))
    mode = report.get("mode")
    if mode not in {"live-download", "local-import-restart"} or (expected_mode is not None and mode != expected_mode):
        raise ValueError("The proof mode is missing or does not match this runner")
    required = (["queue-write-failure-rejected", "search", "match", "resolved-and-queued"]
                if mode == "live-download" else ["local-fixture-import"])
    required += ["saved-mp3", "full-decode", "local-playback", "storage-failure-rejected", "ready-for-restart",
                 "restart", "offline-guard-verified", "restored-library", "restart-local-playback"]
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
    selections = {"automatic", "reference-review"} if mode == "live-download" else {"local-fixture"}
    if report.get("selection") not in selections:
        raise ValueError("The recording-selection mode is missing")
    source = Path(report["filePath"]).resolve()
    if not source.is_relative_to(Path(container).resolve()) or source.suffix.lower() != ".mp3":
        raise ValueError("MP3 path is outside the isolated test container")
    size = source.stat().st_size
    if not 0 < size <= 100 * 1024 * 1024 or size != report.get("fileBytes"):
        raise ValueError("Saved file size does not match the native receipt")
    digest = hashlib.sha256()
    with source.open("rb") as file:
        for chunk in iter(lambda: file.read(65536), b""):
            digest.update(chunk)
    if digest.hexdigest() != report.get("sha256"):
        raise ValueError("Saved MP3 does not match its native checksum")
    duration = report.get("durationSeconds", 0)
    expected_duration = report.get("expectedDurationSeconds", 0)
    frames = report.get("decodedFrames", 0)
    if mode == "live-download":
        if expected_duration != 206:
            raise ValueError("The live proof did not use the expected reference recording")
        tolerance = 4
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
    name = "Carefree-Kevin-MacLeod-proof.mp3" if mode == "live-download" else "Offline-restart-fixture-proof.mp3"
    shutil.copy2(source, destination / name)
    print("PASS: native receipt stages and saved-file checksum verified; mode=" + mode + "; selection=" + report["selection"])


if __name__ == "__main__":
    try:
        validate(*sys.argv[1:])
    except (ValueError, KeyError, OSError, TypeError) as error:
        print("FAIL: " + str(error), file=sys.stderr)
        raise SystemExit(1)
