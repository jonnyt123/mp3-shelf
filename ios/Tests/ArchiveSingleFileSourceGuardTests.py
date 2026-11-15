#!/usr/bin/env python3
"""Compile and execute the production Archive candidate predicate with Swift."""
import pathlib
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
SOURCE = ROOT / "ios/MP3Shelf/Services/AudioSourceFinder.swift"

class ArchiveSingleFileSourceGuardTests(unittest.TestCase):
    def test_explicit_derivative_never_auto_matches(self):
        if not shutil.which("swiftc"):
            self.skipTest("Swift compiler unavailable")
        source = SOURCE.read_text()
        start = source.index("    static func archiveFileCandidate(")
        opening = source.index("{", start)
        depth = 1
        end = opening + 1
        while depth:
            depth += (source[end] == "{") - (source[end] == "}")
            end += 1
        production = source[start:end]
        harness = r"""
import Foundation
struct PlaylistWish { let title: String; let artist: String }
enum MusicMatching {
    static func key(_ value: String) -> String {
        value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
enum AudioSourceFinder {
    static func safeMP3File(_ name: String) -> Bool {
        name.hasSuffix(".mp3") && !name.contains("/") && !name.contains("..")
    }
    static func exactMetadataMatch(title: String, creator: String, wish: PlaylistWish) -> Bool {
        MusicMatching.key(title) == MusicMatching.key(wish.title) &&
        MusicMatching.key(creator) == MusicMatching.key(wish.artist)
    }
__PRODUCTION__
}
let wish = PlaylistWish(title: "Example Song", artist: "Example Artist")
func check(_ source: String?, _ count: Int, _ expected: Bool) {
    let result = AudioSourceFinder.archiveFileCandidate(
        name: "Example Song.mp3", source: source, sizeBytes: "123456",
        itemTitle: "Example Song", itemCreator: "Example Artist",
        audioFileCount: count, wish: wish)
    precondition(result == expected, "source=\\(String(describing: source)), count=\\(count)")
}
check("original", 1, true)
check(nil, 1, true)
check("derivative", 1, false)
check("unknown", 1, false)
check("metadata", 1, false)
check("original", 2, true)
check(nil, 2, false)
check("derivative", 2, false)
print("PASS: 8 Archive source-classification cases")
""".replace("__PRODUCTION__", production)
        with tempfile.TemporaryDirectory() as directory:
            swift = pathlib.Path(directory) / "main.swift"
            binary = pathlib.Path(directory) / "archive-guard"
            swift.write_text(harness)
            subprocess.run(["swiftc", str(swift), "-o", str(binary)], check=True)
            result = subprocess.run([str(binary)], capture_output=True, text=True, check=True)
            self.assertIn("PASS: 8", result.stdout)

if __name__ == "__main__":
    unittest.main()
