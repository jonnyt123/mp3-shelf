#!/usr/bin/env python3
"""Compile and execute the downloader's actual Foundation-only cellular consent logic."""
from pathlib import Path
import subprocess
import sys
import tempfile

source = Path(sys.argv[1]).read_text()
start = source.index("    private static let cellularConsentKey =")
end = source.index("    private lazy var session:", start)
implementation = source[start:end].replace(
    "backgroundAudio.cellularConsent.v1", "backgroundAudio.cellularConsent.fixture.8eae21"
)
program = """import Foundation
final class Harness {
""" + implementation + """
    func approve(_ id: UUID, at now: Date) {
        cellularApprovedPlaylists.insert(id)
        cellularConsentExpirations[id] = now.addingTimeInterval(Self.cellularConsentLifetime)
        persistCellularConsent()
    }
    func restore(_ now: Date) { restoreCellularConsent(now: now) }
    func allowed(_ id: UUID, at now: Date) -> Bool { cellularAllowed(for: id, now: now) }
    func clear() { UserDefaults.standard.removeObject(forKey: Self.cellularConsentKey) }
    func raw(_ value: [String: Date]) { UserDefaults.standard.set(value, forKey: Self.cellularConsentKey) }
}
let id = UUID(), other = UUID(), now = Date(timeIntervalSince1970: 1800000000)
let first = Harness()
first.clear()
first.approve(id, at: now)
let second = Harness()
second.restore(now)
precondition(second.allowed(id, at: now), "Consent must survive relaunch")
precondition(!second.allowed(other, at: now), "Consent must remain playlist-specific")
precondition(!second.allowed(id, at: now.addingTimeInterval(86401)), "Consent must expire")
let third = Harness()
third.raw([id.uuidString: now.addingTimeInterval(86401), "invalid-uuid": now.addingTimeInterval(100)])
third.restore(now)
precondition(!third.allowed(id, at: now), "Overlong consent must be rejected")
let fourth = Harness()
fourth.raw([id.uuidString: now.addingTimeInterval(-1)])
fourth.restore(now)
precondition(!fourth.allowed(id, at: now), "Expired consent must be rejected")
fourth.clear()
print("PASS: 5 consent persistence, scope, expiry and corruption assertions")
"""
with tempfile.TemporaryDirectory() as directory:
    path = Path(directory) / "ConsentFixture.swift"
    path.write_text(program)
    result = subprocess.run(["swift", str(path)], capture_output=True, text=True)
    print(result.stdout, end="")
    print(result.stderr, end="", file=sys.stderr)
    sys.exit(result.returncode)
