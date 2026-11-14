#!/usr/bin/env python3
"""Execute the downloader's actual Foundation-only cellular consent implementation."""
from pathlib import Path
import subprocess
import sys
import tempfile

source = Path(sys.argv[1] if len(sys.argv) > 1 else "ios/MP3Shelf/Services/BackgroundAudioDownloader.swift").read_text()
start = source.index("    private static let cellularConsentKey =")
end = source.index("    private var backgroundEventsCompletion:", start)
implementation = source[start:end].replace(
    "backgroundAudio.cellularConsent.v1", "backgroundAudio.cellularConsent.fixture.duplicateUUID"
)
program = """import Foundation
final class Harness {
""" + implementation + """
    func seed(_ entries: [String: Date]) {
        UserDefaults.standard.set(entries, forKey: Self.cellularConsentKey)
    }
    func restore(_ now: Date) { restoreCellularConsent(now: now) }
    func allowed(_ id: UUID, at now: Date) -> Bool { cellularAllowed(for: id, now: now) }
    func clear() { UserDefaults.standard.removeObject(forKey: Self.cellularConsentKey) }
}
let id = UUID(), other = UUID()
let now = Date(timeIntervalSince1970: 1800000000)
let h = Harness()
h.clear()
let early = now.addingTimeInterval(3600)
let late = now.addingTimeInterval(7200)
h.seed([id.uuidString: late, id.uuidString.lowercased(): early,
        other.uuidString: now.addingTimeInterval(-10), "not-a-uuid": late])
h.restore(now)
precondition(h.allowed(id, at: now), "Valid consent lost")
precondition(!h.allowed(other, at: now), "Expired consent restored")
precondition(!h.allowed(id, at: now.addingTimeInterval(3601)),
             "Duplicate UUID spelling extended consent beyond earliest expiry")
let again = Harness()
again.restore(now)
precondition(!again.allowed(id, at: now.addingTimeInterval(3601)),
             "Canonicalized consent did not survive another launch")
again.clear()
print("PASS: duplicate UUID restore, earliest expiry, corruption and relaunch")
"""
with tempfile.TemporaryDirectory() as directory:
    path = Path(directory) / "ConsentCollision.swift"
    path.write_text(program)
    result = subprocess.run(["swift", str(path)], capture_output=True, text=True)
    print(result.stdout, end="")
    print(result.stderr, end="", file=sys.stderr)
    sys.exit(result.returncode)
