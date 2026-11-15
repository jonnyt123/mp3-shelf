#!/usr/bin/env python3
"""Compile the actual production duration predicates and exercise exact-recording evidence."""
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
SOURCE = ROOT / "ios/MP3Shelf/Services/AudioSourceFinder.swift"

def extract(source, signature):
    start = source.index(signature)
    opening = source.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        if end >= len(source):
            raise AssertionError("Unbalanced Swift function")
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]

class AutomaticWebDurationEvidenceTests(unittest.TestCase):
    def test_production_duration_predicates(self):
        if not shutil.which("swiftc"):
            self.skipTest("Swift compiler unavailable")
        source = SOURCE.read_text()
        methods = "\n".join([
            extract(source, "    private static func durationMatches("),
            extract(source, "    static func recordingDurationEvidenceMatches("),
        ])
        harness = """
import Foundation
struct PlaylistWish { let durationSeconds: Double? }
enum AutomaticWebAudioFinder {
""" + methods + """
}
let wish = PlaylistWish(durationSeconds: 180)
let unknown = PlaylistWish(durationSeconds: nil)
func check(_ value: Bool, _ expected: Bool, _ name: String) {
    guard value == expected else { fatalError("FAIL: \\(name)") }
}
func match(_ parent: Any?, _ child: Any?, _ wish: PlaylistWish = wish) -> Bool {
    AutomaticWebAudioFinder.recordingDurationEvidenceMatches(
        recording: parent, audio: child, wish: wish)
}
check(match(nil, nil), false, "missing duration")
check(match(180.0, nil), true, "parent duration")
check(match(nil, "PT3M"), true, "audio duration")
check(match(180.0, "PT3M"), true, "consistent claims")
check(match(180.0, "PT4M"), false, "contradictory audio")
check(match(240.0, "PT3M"), false, "contradictory recording")
check(match(nil, "PT3M10S"), false, "wrong version")
check(match(nil, "PT3M4S"), true, "four second tolerance")
check(match(nil, "PT3M5S"), false, "outside tolerance")
check(match(nil, nil, unknown), true, "legacy no-duration metadata")
check(match(nil, "invalid"), false, "malformed duration")
print("PASS: 11 production duration evidence cases")
"""
        with tempfile.TemporaryDirectory() as directory:
            swift = pathlib.Path(directory) / "main.swift"
            executable = pathlib.Path(directory) / "duration-test"
            swift.write_text(harness)
            subprocess.run(["swiftc", str(swift), "-o", str(executable)],
                           check=True, capture_output=True, text=True)
            result = subprocess.run([str(executable)], check=True,
                                    capture_output=True, text=True)
            self.assertIn("PASS: 11", result.stdout)

if __name__ == "__main__":
    unittest.main()
