import Foundation

// Standalone Foundation filesystem regression model, not a production importer test.
// Run: swift ios/Tests/PortableRestoreCollisionRecoveryTests.swift
struct ArchiveTrack: Codable, Equatable {
    let id: String
    let filename: String
    let digest: String
}
struct ArchivePlaylist: Codable, Equatable {
    let id: String
    let trackIDs: [String]
}
struct ArchiveManifest: Codable {
    let tracks: [ArchiveTrack]
    let playlists: [ArchivePlaylist]
}
enum RestoreFault: Error { case interrupted, malformed }
func safeAudioFilename(_ name: String) -> Bool {
    guard !name.isEmpty, name != ".", name != "..", !name.contains("/"),
          !name.contains("\\"), !name.contains(":"), !name.hasPrefix("."),
          name.lowercased().hasSuffix(".mp3") else { return false }
    return name.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value != 127 }
}
func check(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
    guard try condition() else { throw NSError(domain: "PortableRestoreQA", code: 1, userInfo: [NSLocalizedDescriptionKey: label]) }
}
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("mp3-restore-qa-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let library = root.appendingPathComponent("library")
let incoming = root.appendingPathComponent("incoming")
try fm.createDirectory(at: library, withIntermediateDirectories: true)
try fm.createDirectory(at: incoming, withIntermediateDirectories: true)
let oldBytes = Data((0..<65536).map { UInt8(($0 * 13) % 251) })
let newBytes = Data((0..<65536).map { UInt8(($0 * 19 + 7) % 251) })
let original = library.appendingPathComponent("existing.mp3")
let candidate = incoming.appendingPathComponent("new.mp3")
try oldBytes.write(to: original)
try newBytes.write(to: candidate)
let manifestURL = library.appendingPathComponent("manifest.json")
let oldTrack = ArchiveTrack(id: "legacy:track/42", filename: "existing.mp3", digest: "old")
let newTrack = ArchiveTrack(id: "import:track/99", filename: "new.mp3", digest: "new")
let oldPlaylist = ArchivePlaylist(id: "legacy:playlist/7", trackIDs: [oldTrack.id])
let incomingPlaylist = ArchivePlaylist(id: "import:playlist/8", trackIDs: [oldTrack.id, newTrack.id, oldTrack.id])
let baseline = ArchiveManifest(tracks: [oldTrack], playlists: [oldPlaylist])
try JSONEncoder().encode(baseline).write(to: manifestURL, options: .atomic)
func load() throws -> ArchiveManifest {
    try JSONDecoder().decode(ArchiveManifest.self, from: Data(contentsOf: manifestURL))
}
func restore(_ archive: ArchiveManifest, failAfterCopy: Bool) throws {
    let ids = archive.tracks.map(\.id)
    guard Set(ids).count == ids.count,\n          archive.tracks.allSatisfy({ safeAudioFilename($0.filename) }),\n          Set(archive.tracks.map { $0.filename.lowercased() }).count == archive.tracks.count,
          Set(archive.playlists.map(\.id)).count == archive.playlists.count,
          archive.playlists.allSatisfy({ $0.trackIDs.allSatisfy(Set(ids).contains) }) else {
        throw RestoreFault.malformed
    }
    let existing = try load()
    let byID = Dictionary(uniqueKeysWithValues: existing.tracks.map { ($0.id, $0) })\n    let existingFilenames = Dictionary(uniqueKeysWithValues: existing.tracks.map { ($0.filename.lowercased(), $0.id) })\n    guard archive.tracks.allSatisfy({ item in\n        existingFilenames[item.filename.lowercased()].map { $0 == item.id } ?? true\n    }) else { throw RestoreFault.malformed }\n    for playlist in archive.playlists {\n        if let old = existing.playlists.first(where: { $0.id == playlist.id }), old != playlist {\n            throw RestoreFault.malformed\n        }\n    }
    for item in archive.tracks where byID[item.id] != nil {
        guard byID[item.id] == item else { throw RestoreFault.malformed }
    }
    let next = ArchiveManifest(
        tracks: existing.tracks + archive.tracks.filter { byID[$0.id] == nil },
        playlists: existing.playlists + archive.playlists.filter { item in !existing.playlists.contains(where: { $0.id == item.id }) }
    )
    let copied = library.appendingPathComponent(newTrack.filename)
    if !fm.fileExists(atPath: copied.path) { try fm.copyItem(at: candidate, to: copied) }
    if failAfterCopy { throw RestoreFault.interrupted }
    try JSONEncoder().encode(next).write(to: manifestURL, options: .atomic)
}
let archive = ArchiveManifest(tracks: [oldTrack, newTrack], playlists: [oldPlaylist, incomingPlaylist])
for attempt in 0..<32 {
    try JSONEncoder().encode(baseline).write(to: manifestURL, options: .atomic)
    let copied = library.appendingPathComponent(newTrack.filename)
    if fm.fileExists(atPath: copied.path) { try fm.removeItem(at: copied) }
    do { try restore(archive, failAfterCopy: true); throw RestoreFault.malformed }
    catch RestoreFault.interrupted { }
    try check(try load().tracks == baseline.tracks, "partial manifest published on attempt \(attempt)")
    try check(Data(contentsOf: original) == oldBytes, "existing audio overwritten")
    try check(Data(contentsOf: copied) == newBytes, "staged audio bytes lost")
    try restore(archive, failAfterCopy: false)
    try restore(archive, failAfterCopy: false)
    let recovered = try load()
    try check(recovered.tracks.count == 2 && recovered.playlists.count == 2, "duplicate records")
    try check(recovered.playlists[1].trackIDs == incomingPlaylist.trackIDs, "playlist order/dedup changed")
    try check(Data(contentsOf: original) == oldBytes && Data(contentsOf: copied) == newBytes, "audio mutated on retry")
}
for invalid in [
    ArchiveManifest(tracks: [oldTrack, oldTrack], playlists: []),
    ArchiveManifest(tracks: [oldTrack], playlists: [incomingPlaylist]),
    ArchiveManifest(tracks: [oldTrack], playlists: [oldPlaylist, oldPlaylist]),
    ArchiveManifest(tracks: [ArchiveTrack(id: oldTrack.id, filename: "replacement.mp3", digest: "wrong")], playlists: [])
] {
    let before = try Data(contentsOf: manifestURL)
    do { try restore(invalid, failAfterCopy: false); throw NSError(domain: "QA", code: 2) }
    catch RestoreFault.malformed { }
    try check(Data(contentsOf: manifestURL) == before, "invalid archive mutated manifest")
    try check(Data(contentsOf: original) == oldBytes, "invalid archive mutated audio")
}

// Reject untrusted archive filenames before any copy, including traversal,
// absolute paths, case-folding collisions and control characters. A restore
// must never overwrite a different recording or alter existing playlists.
let unsafeNames = ["../escape.mp3", "/tmp/escape.mp3", "subdir/song.mp3",
                   "subdir\\\\song.mp3", "..", ".hidden.mp3", "C:evil.mp3",
                   "bad\\u{0000}name.mp3", "bad\\u{000A}name.mp3"]
for (index, filename) in unsafeNames.enumerated() {
    let before = try Data(contentsOf: manifestURL)
    let invalid = ArchiveManifest(tracks: [
        oldTrack, ArchiveTrack(id: "unsafe-\\(index)", filename: filename, digest: "new")
    ], playlists: [])
    do { try restore(invalid, failAfterCopy: false); throw NSError(domain: "QA", code: 3) }
    catch RestoreFault.malformed { }
    try check(Data(contentsOf: manifestURL) == before, "unsafe filename published")
    try check(Data(contentsOf: original) == oldBytes, "unsafe filename damaged audio")
}
let conflictCases: [ArchiveManifest] = [
    ArchiveManifest(tracks: [oldTrack, ArchiveTrack(id: "different", filename: "existing.mp3", digest: "new")], playlists: []),
    ArchiveManifest(tracks: [oldTrack, ArchiveTrack(id: "different", filename: "EXISTING.MP3", digest: "new")], playlists: []),
    ArchiveManifest(tracks: [oldTrack, newTrack, ArchiveTrack(id: "third", filename: "NEW.MP3", digest: "new")], playlists: []),
    ArchiveManifest(tracks: [oldTrack], playlists: [ArchivePlaylist(id: oldPlaylist.id, trackIDs: [])])
]
for (index, invalid) in conflictCases.enumerated() {
    let before = try Data(contentsOf: manifestURL)
    do { try restore(invalid, failAfterCopy: false); throw NSError(domain: "QA", code: 4) }
    catch RestoreFault.malformed { }
    try check(Data(contentsOf: manifestURL) == before, "collision case \\(index) published")
    try check(Data(contentsOf: original) == oldBytes, "collision case damaged existing audio")
}
print("PASS: 32 interruption/retry cycles; 4 malformed archives; 9 unsafe filenames; 4 collision cases; byte preservation")
