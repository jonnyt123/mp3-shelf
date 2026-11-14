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
    guard Set(ids).count == ids.count,
          Set(archive.playlists.map(\.id)).count == archive.playlists.count,
          archive.playlists.allSatisfy({ $0.trackIDs.allSatisfy(Set(ids).contains) }) else {
        throw RestoreFault.malformed
    }
    let existing = try load()
    let byID = Dictionary(uniqueKeysWithValues: existing.tracks.map { ($0.id, $0) })
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
print("PASS: 32 interruption/retry cycles; 4 invalid archives; non-UUID IDs, ordered playlists and byte preservation")
