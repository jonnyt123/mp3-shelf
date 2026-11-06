#!/usr/bin/env python3
"""Validate a native proof receipt and copy its verified file from that container."""
import hashlib
import json
import math
from pathlib import Path
import shutil
import sys


def validate(report_path, container, destination):
    report = json.loads(Path(report_path).read_text())
    if report.get("schema") != "mp3-shelf-download-proof-v1" or report.get("status") != "PASS":
        raise ValueError(report.get("error", "Native download proof has not passed"))
    required = {"search", "match", "resolved-and-queued", "saved-mp3", "full-decode", "local-playback"}
    actual = {item.get("stage") for item in report.get("steps", [])}
    if not required <= actual:
        raise ValueError("The native receipt is missing required pipeline stages")
    if report.get("selection") not in {"automatic", "reference-review"}:
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
    frames = report.get("decodedFrames", 0)
    if not isinstance(frames, int) or isinstance(frames, bool) or frames <= 0 or not math.isfinite(duration) or abs(duration - 206) > 4:
        raise ValueError("Native full-decode evidence is invalid")
    destination = Path(destination)
    destination.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination / "Carefree-Kevin-MacLeod-proof.mp3")
    print("PASS: native receipt stages and saved-file checksum verified; selection=" + report["selection"])


if __name__ == "__main__":
    try:
        validate(*sys.argv[1:])
    except (ValueError, KeyError, OSError, TypeError) as error:
        print("FAIL: " + str(error), file=sys.stderr)
        raise SystemExit(1)
