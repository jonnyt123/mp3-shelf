#!/usr/bin/env python3
"""Compile and run real downloader policy METHOD BODIES with macOS Swift.

The full app must separately pass Xcode Debug/Release builds. This small
harness is intentionally NOT a URLSession daemon / physical-iPhone test.
"""
import pathlib
import re
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
SOURCE = ROOT / "ios/MP3Shelf/Services/BackgroundAudioDownloader.swift"
POLICIES = ROOT / "ios/MP3Shelf/Models/SourceDiscoveryJob.swift"
TESTS = [
    ROOT / "ios/Tests/BackgroundRedirectNetworkPolicyTests.swift",
    ROOT / "ios/Tests/DuplicateCompletionStagingRaceTests.swift",
]

def extract(source: str, signature: str) -> str:
    # Match one well-defined function. If the production signature moves or
    # is duplicated, fail rather than silently testing an outdated copy.
    start = source.find(signature)
    if start < 0 or source.find(signature, start + len(signature)) >= 0:
        raise ValueError("Required production policy signature missing or ambiguous: " + signature)
    opening = source.find("{", start)
    if opening < 0:
        raise ValueError("Function body missing")
    depth = 0
    for i in range(opening, len(source)):
        if source[i] == "{":
            depth += 1
        elif source[i] == "}":
            depth -= 1
            if depth == 0:
                return source[start:i + 1].replace("nonisolated static", "static", 1)
    raise ValueError("Unclosed production function body")

def generated_harness() -> str:
    source = SOURCE.read_text(encoding="utf-8")
    model = POLICIES.read_text(encoding="utf-8")
    max_bytes = re.search(r"static let maxBytes:\s*Int64\s*=\s*(\d+\s*\*\s*\d+\s*\*\s*\d+)", model)
    if not max_bytes:
        raise ValueError("Production download size limit not available")
    signatures = [
        "nonisolated private static func allowedDownloadURL(",
        "nonisolated static func stagedFileSurvivesMoveFailure(",
        "nonisolated static func safeRedirectRequest("
    ]
    methods = [extract(source, signature) for signature in signatures]
    # The video-specific resolver isn't exercised by these direct-file
    # redirect fixtures. Googlevideo remains denied in this harness rather
    # than inventing an accepted signed media URL.
    return (
        "import Foundation\n"
        "enum BackgroundTransferProgressPolicy { static let maxBytes: Int64 = "
        + max_bytes.group(1) + " }\n"
        "enum AudioSourceLinks { static func isResolvedAudioURL(_ url: URL) -> Bool { false } }\n"
        "enum BackgroundAudioDownloader {\n"
        + "\n\n".join(methods) + "\n}\n"
    )

def run() -> int:
    if sys.platform != "darwin":
        raise RuntimeError("This policy suite requires the real macOS Foundation URLRequest APIs")
    with tempfile.TemporaryDirectory(prefix="mp3-shelf-native-policy-") as folder:
        harness = pathlib.Path(folder) / "DownloaderProductionPolicies.swift"
        harness.write_text(generated_harness(), encoding="utf-8")
        for source in TESTS:
            executable = pathlib.Path(folder) / source.stem
            print("Compiling production downloader policy for", source.name, flush=True)
            subprocess.run([
                "swiftc", "-swift-version", "6", "-warnings-as-errors",
                str(harness), str(source), "-o", str(executable)
            ], cwd=ROOT, check=True)
            subprocess.run([str(executable)], cwd=ROOT, check=True)
    print("PASS: both source-backed downloader policy fixtures executed")
    return 0

if __name__ == "__main__":
    try:
        sys.exit(run())
    except (ValueError, OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print("FAIL: downloader policy harness: " + str(error), file=sys.stderr)
        sys.exit(1)
