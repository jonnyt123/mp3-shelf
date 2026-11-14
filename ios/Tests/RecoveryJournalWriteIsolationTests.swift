import Foundation

// Foundation-only fault injection for multi-ticket journal isolation.
// Run: swift ios/Tests/RecoveryJournalWriteIsolationTests.swift
// This tests the recovery model, NOT the production downloader.
struct Ticket: Codable, Equatable { let id: UUID; var status: String }
enum JournalError: Error { case corrupt, duplicate, interrupted }
struct Journal {
    let file: URL
    func read() throws -> [Ticket]? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let bytes = try Data(contentsOf: file)
        guard let entries = try? JSONDecoder().decode([Ticket].self, from: bytes),
              Set(entries.map(\.id)).count == entries.count else { throw JournalError.corrupt }
        return entries
    }
    func write(_ entries: [Ticket], inject: Bool = false) throws {
        guard Set(entries.map(\.id)).count == entries.count else { throw JournalError.duplicate }
        _ = try read()
        let temporary = file.deletingLastPathComponent().appendingPathComponent(".pending-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try JSONEncoder().encode(entries).write(to: temporary)
        if inject { throw JournalError.interrupted }
        try Data(contentsOf: temporary).write(to: file, options: .atomic)
    }
}
func verify(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { fatalError(message) }
}
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("mp3shelf-isolation-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let journal = Journal(file: root.appendingPathComponent("queue.json"))
let a = Ticket(id: UUID(), status: "queued")
let b = Ticket(id: UUID(), status: "queued")
let stageA = root.appendingPathComponent("a.mp3")
let stageB = root.appendingPathComponent("b.mp3")
let audioA = Data((0..<4096).map { UInt8($0 % 251) })
let audioB = Data((0..<4096).map { UInt8(($0 + 19) % 251) })
try audioA.write(to: stageA)
try audioB.write(to: stageB)
try journal.write([a,b])
let initial = try Data(contentsOf: journal.file)
for _ in 0..<32 {
    do { try journal.write([Ticket(id: a.id, status: "cancelled"), b], inject: true); fatalError("Expected interruption") }
    catch JournalError.interrupted {}
    try verify(Data(contentsOf: journal.file) == initial, "Interrupted publication changed queue")
    try verify(journal.read() == [a,b], "Interrupted publication lost a queued ticket")
    try verify(Data(contentsOf: stageA) == audioA && Data(contentsOf: stageB) == audioB, "Interrupted write changed audio")
}
for invalid in [Data(), Data("null".utf8), Data("[{".utf8), try JSONEncoder().encode([a,a])] {
    try invalid.write(to: journal.file, options: .atomic)
    let original = try Data(contentsOf: journal.file)
    do { _ = try journal.read(); fatalError("Accepted corrupt queue") }
    catch JournalError.corrupt {}
    for replacement in [[], [b], [a,b]] {
        do { try journal.write(replacement); fatalError("Overwrote corrupt recovery evidence") }
        catch JournalError.corrupt {}
        try verify(Data(contentsOf: journal.file) == original, "Replacement changed corrupt manifest")
    }
    try verify(Data(contentsOf: stageA) == audioA && Data(contentsOf: stageB) == audioB, "Corruption changed staged audio")
}
try initial.write(to: journal.file, options: .atomic)
try journal.write([Ticket(id: a.id, status: "cancelled"), b])
let restarted = try journal.read()!
try verify(restarted[0].status == "cancelled" && restarted[1] == b, "Restart lost isolated ticket state")
let duplicate = root.appendingPathComponent("late.tmp")
try audioA.write(to: duplicate)
if restarted[0].status == "queued" && !fm.fileExists(atPath: stageA.path) {
    try fm.moveItem(at: duplicate, to: stageA)
}
try verify(Data(contentsOf: stageA) == audioA && Data(contentsOf: stageB) == audioB, "Late callback modified staged media")
try verify(Data(contentsOf: duplicate) == audioA, "Late callback consumed duplicate bytes")
print("PASS: 32 interrupted writes, 4 corrupt manifests x 3 blocked replacements, isolated restart and duplicate callback")
