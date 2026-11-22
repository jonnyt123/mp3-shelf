import Foundation

// Foundation-only crash/restart fixture for portable restore transaction
// invariants. This models the contract; it does not invoke production restore.
// Run: swift ios/Tests/PortableRestoreCrashMatrixTests.swift
enum RestoreFailure: Error { case injected, invalidJournal }
struct Snapshot: Codable, Equatable {
    var tracks: [String: String]
    var playlists: [String: [String]]
}
struct Journal: Codable {
    var before: Snapshot
    var proposed: Snapshot
    var phase: String
}
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("mp3-restore-matrix-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let library = root.appendingPathComponent("library.json")
let journalURL = root.appendingPathComponent("restore.json")
let audio = root.appendingPathComponent("original.mp3")
let originalAudio = Data([0x49, 0x44, 0x33, 0x04, 0, 0xff, 0x10])
let before = Snapshot(tracks: ["old": "original.mp3"], playlists: ["favorites": ["old"]])
let proposed = Snapshot(tracks: ["new": "new.mp3"], playlists: ["imported": ["new"]])
func save<T: Encodable>(_ value: T, at url: URL) throws {
    try JSONEncoder().encode(value).write(to: url, options: .atomic)
}
func load<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
    try JSONDecoder().decode(type, from: Data(contentsOf: url))
}
func recover() throws {
    guard fm.fileExists(atPath: journalURL.path) else { return }
    let record: Journal
    do { record = try load(Journal.self, from: journalURL) }
    catch { throw RestoreFailure.invalidJournal }
    guard ["prepared", "writing", "committed"].contains(record.phase) else {
        throw RestoreFailure.invalidJournal
    }
    try save(record.phase == "committed" ? record.proposed : record.before, at: library)
    try fm.removeItem(at: journalURL)
}
for failurePoint in 0...4 {
    try save(before, at: library)
    try originalAudio.write(to: audio, options: .atomic)
    if fm.fileExists(atPath: journalURL.path) { try fm.removeItem(at: journalURL) }
    do {
        if failurePoint == 0 { throw RestoreFailure.injected }
        try save(Journal(before: before, proposed: proposed, phase: "prepared"), at: journalURL)
        if failurePoint == 1 { throw RestoreFailure.injected }
        try save(Journal(before: before, proposed: proposed, phase: "writing"), at: journalURL)
        if failurePoint == 2 { throw RestoreFailure.injected }
        try save(proposed, at: library)
        if failurePoint == 3 { throw RestoreFailure.injected }
        try save(Journal(before: before, proposed: proposed, phase: "committed"), at: journalURL)
        if failurePoint == 4 { throw RestoreFailure.injected }
    } catch RestoreFailure.injected { }
    try recover()
    let actual = try load(Snapshot.self, from: library)
    precondition(actual == (failurePoint == 4 ? proposed : before), "bad restart at phase \(failurePoint)")
    let observedAudio = try Data(contentsOf: audio)
    precondition(observedAudio == originalAudio, "original audio changed")
    precondition(!fm.fileExists(atPath: journalURL.path), "journal not cleared")
}
for bytes in [Data(), Data("{".utf8), Data("null".utf8), Data("[]".utf8), Data(#"{"phase":"committed"}"#.utf8)] {
    try save(before, at: library)
    try bytes.write(to: journalURL, options: .atomic)
    do { try recover(); fatalError("accepted corrupt restore journal") }
    catch RestoreFailure.invalidJournal { }
    let restored = try load(Snapshot.self, from: library)
    precondition(restored == before)
    let preservedAudio = try Data(contentsOf: audio)
    precondition(preservedAudio == originalAudio)
    let preservedJournal = try Data(contentsOf: journalURL)
    precondition(preservedJournal == bytes)
}
print("PASS: five restart boundaries and five malformed journals preserve original audio")
print("LIMITATION: Foundation transaction model; production restore, Xcode and iPhone UNVERIFIED")
