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
func restore(_ archive: ArchiveManifest, failAfterCopy: Bool, failOnCopy: Int? = nil) throws {
    let ids = archive.tracks.map(\.id)
    guard Set(ids).count == ids.count,
          archive.tracks.allSatisfy({ safeAudioFilename($0.filename) }),
          Set(archive.tracks.map { $0.filename.lowercased() }).count == archive.tracks.count,
          Set(archive.playlists.map(\.id)).count == archive.playlists.count,
          archive.playlists.allSatisfy({ $0.trackIDs.allSatisfy(Set(ids).contains) }) else {
        throw RestoreFault.malformed
    }
    let existing = try load()
    let byID = Dictionary(uniqueKeysWithValues: existing.tracks.map { ($0.id, $0) })
    let existingFilenames = Dictionary(uniqueKeysWithValues: existing.tracks.map { ($0.filename.lowercased(), $0.id) })
    guard archive.tracks.allSatisfy({ item in
        existingFilenames[item.filename.lowercased()].map { $0 == item.id } ?? true
    }) else { throw RestoreFault.malformed }
    for playlist in archive.playlists {
        if let old = existing.playlists.first(where: { $0.id == playlist.id }), old != playlist {
            throw RestoreFault.malformed
        }
    }
    for item in archive.tracks where byID[item.id] != nil {
        guard byID[item.id] == item else { throw RestoreFault.malformed }
    }
    let next = ArchiveManifest(
        tracks: existing.tracks + archive.tracks.filter { byID[$0.id] == nil },
        playlists: existing.playlists + archive.playlists.filter { item in !existing.playlists.contains(where: { $0.id == item.id }) }
    )
    // Preflight every incoming recording before any filesystem mutation.
    // A late missing/corrupt source must not leave earlier tracks copied.
    var pendingCopies: [(URL, URL)] = []
    for item in archive.tracks where byID[item.id] == nil {
        let source = incoming.appendingPathComponent(item.filename)
        let destination = library.appendingPathComponent(item.filename)
        guard (try? fm.destinationOfSymbolicLink(atPath: source.path)) == nil,
              (try? fm.destinationOfSymbolicLink(atPath: destination.path)) == nil,
              fm.fileExists(atPath: source.path),
              let sourceAttributes = try? fm.attributesOfItem(atPath: source.path),
              sourceAttributes[.type] as? FileAttributeType == .typeRegular,
              (sourceAttributes[.referenceCount] as? NSNumber)?.intValue == 1,
              (sourceAttributes[.size] as? NSNumber)?.int64Value ?? 0 > 0,
              let expected = try? Data(contentsOf: source) else {
            throw RestoreFault.malformed
        }
        if fm.fileExists(atPath: destination.path) {
            guard let actual = try? Data(contentsOf: destination),
                  actual == expected else { throw RestoreFault.malformed }
        } else {
            pendingCopies.append((source, destination))
        }
    }
    // A mid-batch filesystem failure must not strand earlier uncommitted files.
    // Only remove destinations created by this invocation, never pre-existing audio.
    var created: [URL] = []
    do {
        for (index, pair) in pendingCopies.enumerated() {
            if failOnCopy == index { throw RestoreFault.interrupted }
            try fm.copyItem(at: pair.0, to: pair.1)
            created.append(pair.1)
        }
    } catch {
        for destination in created.reversed() { try? fm.removeItem(at: destination) }
        throw error
    }
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
                   "bad\u{0000}name.mp3", "bad\u{000A}name.mp3"]
for (index, filename) in unsafeNames.enumerated() {
    let before = try Data(contentsOf: manifestURL)
    let invalid = ArchiveManifest(tracks: [
        oldTrack, ArchiveTrack(id: "unsafe-\(index)", filename: filename, digest: "new")
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
    try check(Data(contentsOf: manifestURL) == before, "collision case \(index) published")
    try check(Data(contentsOf: original) == oldBytes, "collision case damaged existing audio")
}
// Rewind only the manifest to the pre-import snapshot. The destination audio
// remains on disk, exactly as it would after a crash between copy and commit.
// Previously these checks ran against an already committed manifest, causing
// byID to skip the destination entirely and masking the collision.
try JSONEncoder().encode(baseline).write(to: manifestURL, options: .atomic)
// Interrupted recovery must not trust a pre-existing destination filename.
// Simulate a foreign recording and a truncated staged copy, then retry with
// the correct bytes. The manifest must remain byte-identical on rejection.
let baselineBeforeCollision = try Data(contentsOf: manifestURL)
let copiedPath = library.appendingPathComponent(newTrack.filename)
for (name, foreignBytes) in [
    ("foreign-recording", oldBytes),
    ("truncated-copy", Data(newBytes.prefix(1024))),
    ("empty-copy", Data())
] {
    try foreignBytes.write(to: copiedPath, options: .atomic)
    var rejected = false
    do { try restore(archive, failAfterCopy: false) }
    catch RestoreFault.malformed { rejected = true }
    try check(rejected, "pre-existing collision accepted: \(name)")
    try check(Data(contentsOf: manifestURL) == baselineBeforeCollision,
              "collision modified manifest: \(name)")
    try check(Data(contentsOf: copiedPath) == foreignBytes,
              "collision erased forensic bytes: \(name)")
    try check(Data(contentsOf: original) == oldBytes,
              "collision damaged existing recording: \(name)")
}
try newBytes.write(to: copiedPath, options: .atomic)
try restore(archive, failAfterCopy: false)
try check((try load()).tracks.count == 2 && (try load()).playlists.count == 2,
          "valid retry failed to commit recovered manifest")
try check(Data(contentsOf: copiedPath) == newBytes,
          "valid retry did not preserve restored audio")
// A metadata-only restore must not re-copy or validate unrelated staged files.
// The old model unconditionally copied new.mp3 even when it was absent from
// the archive; this scenario detects that false-positive reference behavior.
let metadataOnly = ArchiveManifest(tracks: [oldTrack], playlists: [oldPlaylist])
let committedBeforeMetadata = try Data(contentsOf: manifestURL)
let foreignAfterCommit = Data(repeating: 0xA5, count: 4096)
try foreignAfterCommit.write(to: copiedPath, options: .atomic)
try restore(metadataOnly, failAfterCopy: false)
try check(Data(contentsOf: copiedPath) == foreignAfterCommit,
          "metadata-only restore touched unrelated destination audio")
try check(Data(contentsOf: manifestURL) == committedBeforeMetadata,
          "metadata-only restore changed library manifest")

// A missing incoming recording must fail before publishing its track metadata.
// Use a distinct ID and filename to ensure the copy path is actually exercised.
let missingTrack = ArchiveTrack(id: "missing:track/100", filename: "missing.mp3", digest: "missing")
let missingArchive = ArchiveManifest(tracks: [missingTrack], playlists: [])
var missingRejected = false
do { try restore(missingArchive, failAfterCopy: false) }
catch RestoreFault.malformed { missingRejected = true }
try check(missingRejected, "missing archive audio accepted")
try check(Data(contentsOf: manifestURL) == committedBeforeMetadata,
          "missing source published orphan track metadata")
try check(Data(contentsOf: original) == oldBytes &&
          Data(contentsOf: copiedPath) == foreignAfterCommit,
          "missing source modified existing audio")

// A valid first source followed by a missing second source must not create
// a partially copied library. Preflight all inputs before writing any track.
let firstNew = ArchiveTrack(id: "batch:first", filename: "batch-first.mp3", digest: "first")
let secondNew = ArchiveTrack(id: "batch:second", filename: "batch-second.mp3", digest: "second")
let firstSource = incoming.appendingPathComponent(firstNew.filename)
let firstDestination = library.appendingPathComponent(firstNew.filename)
let secondSource = incoming.appendingPathComponent(secondNew.filename)
let secondDestination = library.appendingPathComponent(secondNew.filename)
let batch = ArchiveManifest(tracks: [firstNew, secondNew], playlists: [
    ArchivePlaylist(id: "batch:playlist", trackIDs: [firstNew.id, secondNew.id])
])
try newBytes.write(to: firstSource)
let manifestBeforeBatch = try Data(contentsOf: manifestURL)
var batchRejected = false
do { try restore(batch, failAfterCopy: false) }
catch RestoreFault.malformed { batchRejected = true }
try check(batchRejected, "batch with missing second source accepted")
try check(!fm.fileExists(atPath: firstDestination.path) &&
          !fm.fileExists(atPath: secondDestination.path),
          "invalid batch copied a partial library")
try check(Data(contentsOf: manifestURL) == manifestBeforeBatch,
          "invalid batch published metadata")
try newBytes.write(to: secondSource)
try restore(batch, failAfterCopy: false)
try check(Data(contentsOf: firstDestination) == newBytes &&
          Data(contentsOf: secondDestination) == newBytes,
          "valid batch retry did not preserve both recordings")
try check((try load()).playlists.last?.trackIDs == [firstNew.id, secondNew.id],
          "valid batch retry lost playlist order")

// Simulate a failure after the first successful copy in a two-track batch.
// A retry must be able to recover without orphan files or changed playlists.
let rollbackFirst = ArchiveTrack(id: "rollback:first", filename: "rollback-first.mp3", digest: "r1")
let rollbackSecond = ArchiveTrack(id: "rollback:second", filename: "rollback-second.mp3", digest: "r2")
let rollbackArchive = ArchiveManifest(tracks: [rollbackFirst, rollbackSecond], playlists: [
    ArchivePlaylist(id: "rollback:playlist", trackIDs: [rollbackSecond.id, rollbackFirst.id])
])
let rollbackOne = library.appendingPathComponent(rollbackFirst.filename)
let rollbackTwo = library.appendingPathComponent(rollbackSecond.filename)
try oldBytes.write(to: incoming.appendingPathComponent(rollbackFirst.filename))
try newBytes.write(to: incoming.appendingPathComponent(rollbackSecond.filename))
let beforeRollback = try Data(contentsOf: manifestURL)
for iteration in 0..<48 {
    var interrupted = false
    do { try restore(rollbackArchive, failAfterCopy: false, failOnCopy: 1) }
    catch RestoreFault.interrupted { interrupted = true }
    try check(interrupted, "injected second-copy failure was ignored \\(iteration)")
    try check(!fm.fileExists(atPath: rollbackOne.path) && !fm.fileExists(atPath: rollbackTwo.path),
              "mid-batch failure left orphan audio \\(iteration)")
    try check(Data(contentsOf: manifestURL) == beforeRollback,
              "mid-batch failure published playlist or track metadata \\(iteration)")
    try check(Data(contentsOf: original) == oldBytes,
              "mid-batch rollback damaged pre-existing recording \\(iteration)")
}
try restore(rollbackArchive, failAfterCopy: false)
try check(Data(contentsOf: rollbackOne) == oldBytes && Data(contentsOf: rollbackTwo) == newBytes,
          "retry after mid-batch failure lost recording bytes")
try check((try load()).playlists.last?.trackIDs == [rollbackSecond.id, rollbackFirst.id],
          "retry after mid-batch failure changed playlist order")

// Symlink path attacks: a lexically safe .mp3 basename may resolve outside
// either the staging directory or the library. Reject before reading or
// copying, including a dangling destination link (fileExists returns false).
let outside = root.appendingPathComponent("outside-user-audio.mp3")
let outsideBytes = Data(repeating: 0xD7, count: 8192)
try outsideBytes.write(to: outside, options: .atomic)
let linkTrack = ArchiveTrack(id: "link:track/101", filename: "linked.mp3", digest: "link")
let linkArchive = ArchiveManifest(tracks: [linkTrack], playlists: [])
let linkSource = incoming.appendingPathComponent(linkTrack.filename)
let linkDestination = library.appendingPathComponent(linkTrack.filename)
let manifestBeforeLinks = try Data(contentsOf: manifestURL)
func expectLinkRejected(_ label: String) throws {
    var rejected = false
    do { try restore(linkArchive, failAfterCopy: false) }
    catch RestoreFault.malformed { rejected = true }
    try check(rejected, "symlink restore accepted: \\(label)")
    try check(Data(contentsOf: manifestURL) == manifestBeforeLinks,
              "symlink restore published metadata: \\(label)")
    try check(Data(contentsOf: outside) == outsideBytes,
              "symlink restore changed external audio: \\(label)")
    try check(Data(contentsOf: original) == oldBytes,
              "symlink restore damaged existing recording: \\(label)")
}
try fm.createSymbolicLink(at: linkSource, withDestinationURL: outside)
try expectLinkRejected("source points outside staging")
try fm.removeItem(at: linkSource)
try newBytes.write(to: linkSource)
try fm.createSymbolicLink(at: linkDestination, withDestinationURL: outside)
try expectLinkRejected("destination points outside library")
try fm.removeItem(at: linkDestination)
let missingOutside = root.appendingPathComponent("not-present.mp3")
try fm.createSymbolicLink(at: linkDestination, withDestinationURL: missingOutside)
try expectLinkRejected("dangling destination")
try fm.removeItem(at: linkDestination)
try restore(linkArchive, failAfterCopy: false)
try check(Data(contentsOf: linkDestination) == newBytes,
          "valid non-symlink retry did not restore audio")
try check(Data(contentsOf: outside) == outsideBytes,
          "valid retry mutated unrelated external audio")

// A valid filename is not sufficient: a source may be empty, a directory,
// or a hard link to user-owned audio. Reject every unsafe source before any
// destination is copied or metadata committed; permit a clean retry.
let unsafeBatchTrack = ArchiveTrack(id: "unsafe-batch", filename: "unsafe-batch.mp3", digest: "safe")
let unsafeBatch = ArchiveManifest(tracks: [unsafeBatchTrack], playlists: [])
let unsafeBatchSource = incoming.appendingPathComponent(unsafeBatchTrack.filename)
let unsafeBatchDestination = library.appendingPathComponent(unsafeBatchTrack.filename)
let protectedSource = root.appendingPathComponent("protected-source.mp3")
let protectedBytes = Data(repeating: 0xBA, count: 8192)
try protectedBytes.write(to: protectedSource)
for scenario in 0..<60 {
    if fm.fileExists(atPath: unsafeBatchSource.path) { try fm.removeItem(at: unsafeBatchSource) }
    switch scenario % 3 {
    case 0: try Data().write(to: unsafeBatchSource)
    case 1: try fm.createDirectory(at: unsafeBatchSource, withIntermediateDirectories: false)
    default: try fm.linkItem(at: protectedSource, to: unsafeBatchSource)
    }
    let before = try Data(contentsOf: manifestURL)
    var rejected = false
    do { try restore(unsafeBatch, failAfterCopy: false) }
    catch RestoreFault.malformed { rejected = true }
    try check(rejected, "unsafe staged source accepted: \\(scenario)")
    try check(Data(contentsOf: manifestURL) == before, "unsafe source published metadata")
    try check(!fm.fileExists(atPath: unsafeBatchDestination.path), "unsafe source copied")
    try check(Data(contentsOf: protectedSource) == protectedBytes, "protected source changed")
}
try fm.removeItem(at: unsafeBatchSource)
try newBytes.write(to: unsafeBatchSource)
try restore(unsafeBatch, failAfterCopy: false)
try check(Data(contentsOf: unsafeBatchDestination) == newBytes, "valid retry failed")
try check(Data(contentsOf: protectedSource) == protectedBytes, "valid retry changed protected audio")
print("PASS: 60 unsafe-source rejections and clean retry")

print("PASS: 32 interruption/retry cycles; 4 malformed archives; 9 unsafe filenames; 4 collision cases; 3 stale-file collision cases; metadata-only isolation; missing-source rejection; 3 symlink path attacks; two-track preflight/retry; byte preservation")
