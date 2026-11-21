import Foundation

// Run from repo root: swift ios/Tests/CorruptManifestOrphanSweepTests.swift --fixture-only
// Production source inspection: swift ios/Tests/CorruptManifestOrphanSweepTests.swift
// The fixture models a fail-closed recovery gate, not a real URLSession invocation.
enum ManifestState: Equatable { case absent, valid(Set<UUID>), corrupt }
func load(_ url: URL) throws -> ManifestState {
    guard FileManager.default.fileExists(atPath: url.path) else { return .absent }
    let bytes = try Data(contentsOf: url)
    guard let ids = try? JSONDecoder().decode([UUID].self, from: bytes),
          Set(ids).count == ids.count else { return .corrupt }
    return .valid(Set(ids))
}
func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
}
func sweep(_ manifest: URL, _ staged: [UUID: URL]) throws -> Int {
    // Never interpret an unreadable manifest as an empty authoritative queue.
    switch try load(manifest) {
    case .corrupt: return 0
    case .absent: return 0 // no ownership proof for pre-existing user audio
    case .valid(let ids):
        var removed = 0
        for (id, url) in staged where !ids.contains(id) {
            try FileManager.default.removeItem(at: url)
            removed += 1
        }
        return removed
    }
}
let fm = FileManager.default
let dir = fm.temporaryDirectory.appendingPathComponent("mp3-orphan-\(UUID())")
try fm.createDirectory(at: dir, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: dir) }
let manifest = dir.appendingPathComponent("tickets.json")
let first = UUID(), second = UUID()
let a = dir.appendingPathComponent("a.mp3"), b = dir.appendingPathComponent("b.mp3")
let aBytes = Data(repeating: 0xA1, count: 32768)
let bBytes = Data(repeating: 0xB2, count: 32768)
try aBytes.write(to: a)
try bBytes.write(to: b)
let staged = [first: a, second: b]
for corrupt in [Data(), Data("null".utf8), Data("[{".utf8), try JSONEncoder().encode([first, first])] {
    try corrupt.write(to: manifest, options: .atomic)
    try check(load(manifest) == .corrupt, "invalid journal was accepted")
    for _ in 0..<8 {
        try check(sweep(manifest, staged) == 0, "corrupt queue triggered destructive orphan sweep")
        try check(Data(contentsOf: a) == aBytes && Data(contentsOf: b) == bBytes,
                  "orphan sweep removed user audio after decode failure")
        try check(Data(contentsOf: manifest) == corrupt, "corrupt evidence overwritten")
    }
}
try fm.removeItem(at: manifest)
try check(sweep(manifest, staged) == 0, "missing manifest authorized deletion")
try check(Data(contentsOf: a) == aBytes && Data(contentsOf: b) == bBytes,
          "missing journal removed staged audio")
try JSONEncoder().encode([first, second]).write(to: manifest, options: .atomic)
try check(sweep(manifest, staged) == 0, "valid queue removed owned recordings")
try check(Data(contentsOf: a) == aBytes && Data(contentsOf: b) == bBytes,
          "valid recovery damaged audio")
print("PASS: 32 corrupt-manifest recovery sweeps, missing journal, valid two-ticket recovery")
if !CommandLine.arguments.contains("--fixture-only") {
    let path = "ios/MP3Shelf/Services/BackgroundAudioDownloader.swift"
    guard fm.fileExists(atPath: path) else {
        fputs("UNVERIFIED: production downloader missing\n", stderr); exit(2)
    }
    let source = try String(contentsOfFile: path, encoding: .utf8)
    // The importer must not treat decode failure as an empty ticket collection.
    let hasRecoveryGate = source.contains("manifestRecoveryBlocked") || source.contains("manifestRecoveryState")
    try check(hasRecoveryGate, "P0: no explicit corrupt-manifest gate before staged recovery")
    print("PASS: production recovery gate detected (source inspection only)")
}
