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


// A crash can occur during recovery itself. Replaying the same journal must
// converge to the same catalog without changing pre-existing audio bytes.
for phase in ["prepared", "writing", "committed"] {
    for recoveryAttempt in 0..<3 {
        try save(before, at: library)
        try originalAudio.write(to: audio, options: .atomic)
        if fm.fileExists(atPath: journalURL.path) { try fm.removeItem(at: journalURL) }
        let record = Journal(before: before, proposed: proposed, phase: phase)
        try save(record, at: journalURL)
        // Emulate a partially installed candidate before restart.
        try save(proposed, at: library)
        // Emulate a crash after the recovery catalog write but before the
        // journal unlink. The next restart must be safe to repeat.
        if recoveryAttempt > 0 {
            try save(phase == "committed" ? proposed : before, at: library)
        }
        try recover()
        let expected = phase == "committed" ? proposed : before
        let observed = try load(Snapshot.self, from: library)
        precondition(observed == expected,
                     "recovery replay mismatch: \(phase) attempt \(recoveryAttempt)")
        let observedAudio = try Data(contentsOf: audio)
    precondition(observedAudio == originalAudio,
                     "recovery replay changed original audio")
        try recover() // No journal: restart must be a no-op.
        let observedAfterSecondRecovery = try load(Snapshot.self, from: library)
        precondition(observedAfterSecondRecovery == expected,
                     "second recovery changed catalog")
        precondition(!fm.fileExists(atPath: journalURL.path))
    }
}

// Invalid phase values must never overwrite a partially installed library.
// Keep the journal for diagnosis/retry rather than silently discarding it.
for phase in ["", "PREPARED", "committing", "../committed", "rolledBack"] {
    try save(proposed, at: library)
    let record = Journal(before: before, proposed: proposed, phase: phase)
    try save(record, at: journalURL)
    let journalBytes = try Data(contentsOf: journalURL)
    do { try recover(); fatalError("accepted invalid phase \(phase)") }
    catch RestoreFailure.invalidJournal { }
    let observed = try load(Snapshot.self, from: library)
    precondition(observed == proposed,
                 "invalid journal mutated catalog")
    let preservedJournal = try Data(contentsOf: journalURL)
    precondition(preservedJournal == journalBytes,
                 "invalid journal was lost")
    let observedAudio = try Data(contentsOf: audio)
        precondition(observedAudio == originalAudio,
                 "invalid journal mutated existing audio")
}
print("PASS: recovery replay/idempotence and invalid-phase preservation model")

// A recovery journal is itself user data until reconciliation succeeds.
// Simulate a failed catalog write by replacing its path with a directory:
// recovery must retain the durable journal, then succeed after repair.
for phase in ["prepared", "writing", "committed"] {
    try save(Journal(before: before, proposed: proposed, phase: phase), at: journalURL)
    let journalBytes = try Data(contentsOf: journalURL)
    if fm.fileExists(atPath: library.path) { try fm.removeItem(at: library) }
    try fm.createDirectory(at: library, withIntermediateDirectories: false)
    do {
        try recover()
        fatalError("recovery unexpectedly succeeded with directory catalog")
    } catch RestoreFailure.invalidJournal {
        fatalError("valid journal misclassified as corrupt")
    } catch {
        // Expected filesystem write failure. The journal must remain intact.
    }
    let journalAfterFailure = try Data(contentsOf: journalURL)
    let audioAfterFailure = try Data(contentsOf: audio)
    precondition(journalAfterFailure == journalBytes,
                 "failed recovery discarded journal")
    precondition(audioAfterFailure == originalAudio,
                 "failed recovery changed user audio")
    try fm.removeItem(at: library)
    try save(before, at: library)
    try recover()
    let recoveredCatalog = try load(Snapshot.self, from: library)
    precondition(recoveredCatalog == (phase == "committed" ? proposed : before),
                 "recovery retry did not converge")
    precondition(!fm.fileExists(atPath: journalURL.path),
                 "successful retry retained stale journal")
}
print("PASS: failed catalog-write recovery preserves journal for retry")
