import Foundation
// Standalone failure-injection model, not production importer or device proof.
// swift ios/Tests/RestoreJournalOwnershipReplayTests.swift
private struct Entry: Codable { let name: String; let bytes: Data; let owned: Bool }
private struct Journal: Codable { let entries: [Entry]; let committed: Bool }
private enum Rejection: Error { case unsafe, changed }
private let fm = FileManager.default
private let root = fm.temporaryDirectory.appendingPathComponent("restore-replay-\(UUID())")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
private let audio = root.appendingPathComponent("audio")
try fm.createDirectory(at: audio, withIntermediateDirectories: true)
private let journal = root.appendingPathComponent("journal.json")
private let manifest = root.appendingPathComponent("manifest.json")
private let old = Data("before".utf8), new = Data("after".utf8)
private let borrowed = Data(repeating: 0x55, count: 4096)
private let created = Data(repeating: 0x99, count: 8192)
private let unrelated = Data(repeating: 0xAA, count: 2048)
private func path(_ name: String) -> URL { audio.appendingPathComponent(name) }
private func assert(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw NSError(domain: "JournalQA", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
private func reset() throws {
    for name in ["borrowed.mp3", "new.mp3", "unrelated.mp3"] {
        if fm.fileExists(atPath: path(name).path) { try fm.removeItem(at: path(name)) }
    }
    try borrowed.write(to: path("borrowed.mp3"))
    try unrelated.write(to: path("unrelated.mp3"))
    try old.write(to: manifest, options: .atomic)
}
private let entries = [Entry(name: "borrowed.mp3", bytes: borrowed, owned: false),
                       Entry(name: "new.mp3", bytes: created, owned: true)]
private func replay() throws {
    let record = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: journal))
    var names = Set<String>()
    for entry in record.entries {
        guard !entry.name.isEmpty, !entry.name.hasPrefix("."),
              !entry.name.contains("/"), !entry.name.contains("\\"),
              !entry.name.contains(":"), names.insert(entry.name).inserted
        else { throw Rejection.unsafe }
        let file = path(entry.name)
        guard (try? fm.destinationOfSymbolicLink(atPath: file.path)) == nil
        else { throw Rejection.unsafe }
        var directory: ObjCBool = false
        if fm.fileExists(atPath: file.path, isDirectory: &directory) {
            guard !directory.boolValue, (try? Data(contentsOf: file)) == entry.bytes
            else { throw Rejection.changed }
        } else if !entry.owned { throw Rejection.changed }
    }
    guard (try? Data(contentsOf: manifest)) == (record.committed ? new : old)
    else { throw Rejection.changed }
    if !record.committed {
        for entry in record.entries where entry.owned {
            if fm.fileExists(atPath: path(entry.name).path) { try fm.removeItem(at: path(entry.name)) }
        }
    }
    try fm.removeItem(at: journal)
}
private func persist(_ record: Journal) throws {
    try JSONEncoder().encode(record).write(to: journal, options: .atomic)
}
for _ in 0..<24 {
    try reset()
    try created.write(to: path("new.mp3"))
    try persist(Journal(entries: entries, committed: false))
    try replay()
    try assert(!fm.fileExists(atPath: path("new.mp3").path), "uncommitted audio survived")
    try assert(Data(contentsOf: manifest) == old, "uncommitted manifest changed")
    try assert(Data(contentsOf: path("borrowed.mp3")) == borrowed, "borrowed audio removed")
    try created.write(to: path("new.mp3"))
    try new.write(to: manifest, options: .atomic)
    try persist(Journal(entries: entries, committed: true))
    try replay()
    try assert(Data(contentsOf: path("new.mp3")) == created, "committed audio removed")
    try assert(Data(contentsOf: manifest) == new, "committed manifest lost")
    try reset()
    try created.write(to: path("new.mp3"))
    for name in ["../unrelated.mp3", "/tmp/new.mp3", "dir/new.mp3", "dir\\new.mp3", ".hidden", "C:new.mp3", "borrowed.mp3"] {
        try persist(Journal(entries: entries + [Entry(name: name, bytes: created, owned: true)], committed: false))
        var rejected = false
        do { try replay() } catch Rejection.unsafe { rejected = true }
        try assert(rejected, "unsafe or duplicate journal entry accepted")
        try assert(Data(contentsOf: path("new.mp3")) == created, "unsafe journal removed audio")
        try assert(fm.fileExists(atPath: journal.path), "unsafe journal lost evidence")
    }
    try Data(repeating: 0x11, count: 7).write(to: path("new.mp3"))
    try persist(Journal(entries: entries, committed: false))
    var conflict = false
    do { try replay() } catch Rejection.changed { conflict = true }
    try assert(conflict, "foreign replacement accepted")
    try assert(Data(contentsOf: path("new.mp3")) == Data(repeating: 0x11, count: 7), "foreign bytes deleted")
    try assert(Data(contentsOf: path("borrowed.mp3")) == borrowed, "borrowed bytes changed")
    try assert(Data(contentsOf: path("unrelated.mp3")) == unrelated, "unrelated bytes changed")
}
print("PASS: 24 rollback, 24 committed replay, 168 hostile journal, 24 foreign replacement scenarios")


// Recovery must fail closed on torn journals, missing owned media and filesystem
// substitutions. Rejected replay leaves the journal available for investigation.
for _ in 0..<16 {
    try reset()
    try created.write(to: path("new.mp3"))
    for damaged in [Data(), Data("{".utf8), Data("null".utf8),
                    Data(#"{"entries":[]}"#.utf8)] {
        try damaged.write(to: journal, options: .atomic)
        var rejected = false
        do { try replay() } catch { rejected = true }
        try assert(rejected, "corrupt journal was accepted")
        try assert(Data(contentsOf: path("new.mp3")) == created, "corrupt journal deleted audio")
        try assert(Data(contentsOf: manifest) == old, "corrupt journal changed manifest")
        try assert(fm.fileExists(atPath: journal.path), "corrupt journal was discarded")
    }
    try persist(Journal(entries: entries, committed: false))
    try fm.removeItem(at: path("new.mp3"))
    var missingRejected = false
    do { try replay() } catch Rejection.changed { missingRejected = true }
    // Missing owned audio is safe to roll back, while missing borrowed media is not.
    try assert(!missingRejected, "missing owned media prevented safe rollback")
    try assert(!fm.fileExists(atPath: journal.path), "rollback left stale journal")

    try reset()
    try created.write(to: path("new.mp3"))
    try persist(Journal(entries: entries, committed: false))
    try fm.removeItem(at: path("new.mp3"))
    try fm.createSymbolicLink(at: path("new.mp3"), withDestinationURL: path("unrelated.mp3"))
    var linkRejected = false
    do { try replay() } catch Rejection.unsafe { linkRejected = true }
    try assert(linkRejected, "symlink substitution accepted")
    try assert(Data(contentsOf: path("unrelated.mp3")) == unrelated, "symlink target changed")
    try assert(fm.fileExists(atPath: journal.path), "symlink rejection discarded journal")
    try fm.removeItem(at: path("new.mp3"))

    try fm.createDirectory(at: path("new.mp3"), withIntermediateDirectories: false)
    var dirRejected = false
    do { try replay() } catch Rejection.changed { dirRejected = true }
    try assert(dirRejected, "directory substitution accepted")
    try assert(Data(contentsOf: path("unrelated.mp3")) == unrelated, "directory replay changed unrelated audio")
    try assert(fm.fileExists(atPath: journal.path), "directory rejection discarded journal")
    try fm.removeItem(at: path("new.mp3"))
}
print("PASS: 64 torn journal, 16 missing owned media, 16 symlink and 16 directory substitution scenarios")
