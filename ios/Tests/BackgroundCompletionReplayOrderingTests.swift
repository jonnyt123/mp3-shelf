import Foundation

// Run: swift ios/Tests/BackgroundCompletionReplayOrderingTests.swift
// Independent filesystem model: not a production URLSession integration test.
struct Entry: Codable, Equatable {
    enum State: String, Codable { case pending, importing, imported, cancelled }
    var id: String
    var state: State
    var filename: String
}
struct Snapshot: Codable {
    var entries: [Entry]
    var receipts: [String]
}
enum ReplayError: Error { case corrupt, missing, conflict, unsafe, interrupted }
func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw NSError(domain: "ReplayQA", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("mp3-replay-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let journal = root.appendingPathComponent("journal.json")
let stage = root.appendingPathComponent("stage.mp3")
let dest = root.appendingPathComponent("song.mp3")
let other = root.appendingPathComponent("other.mp3")
let original = Data((0..<32768).map { UInt8(($0 * 17 + 9) % 251) })
let unrelated = Data((0..<32768).map { UInt8(($0 * 11 + 3) % 251) })
try unrelated.write(to: other)
func load() throws -> Snapshot {
    guard let value = try? JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: journal)) else { throw ReplayError.corrupt }
    let ids = value.entries.map(\.id)
    guard Set(ids).count == ids.count, Set(value.receipts).count == value.receipts.count,
          value.receipts.allSatisfy({ id in value.entries.contains { $0.id == id && $0.state == .imported } }),
          value.entries.allSatisfy({ $0.state != .imported || value.receipts.contains($0.id) }) else { throw ReplayError.corrupt }
    return value
}
func save(_ value: Snapshot, interrupted: Bool = false) throws {
    if interrupted { throw ReplayError.interrupted }
    try JSONEncoder().encode(value).write(to: journal, options: .atomic)
}
// Validate the directory entry before reading: a terminal receipt must never
// authorize a missing, foreign or symlink-substituted recording after restart.
func verifiedRecording(_ url: URL) throws -> Bool {
    if (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil {
        throw ReplayError.unsafe
    }
    let attributes: [FileAttributeKey: Any]
    do { attributes = try fm.attributesOfItem(atPath: url.path) }
    catch { return false }
    guard attributes[.type] as? FileAttributeType == .typeRegular else {
        throw ReplayError.unsafe
    }
    guard (attributes[.size] as? NSNumber)?.intValue == original.count,
          try Data(contentsOf: url) == original else { throw ReplayError.conflict }
    return true
}
func complete(interruptTerminal: Bool = false) throws {
    var snapshot = try load()
    guard let index = snapshot.entries.firstIndex(where: { $0.id == "ticket" }) else { throw ReplayError.corrupt }
    if snapshot.entries[index].state == .imported {
        guard try verifiedRecording(dest) else { throw ReplayError.missing }
        return
    }
    guard snapshot.entries[index].state == .pending || snapshot.entries[index].state == .importing else { return }
    let stagedExists = try verifiedRecording(stage)
    let destinationExists = try verifiedRecording(dest)
    guard stagedExists || (snapshot.entries[index].state == .importing && destinationExists) else { throw ReplayError.missing }
    if snapshot.entries[index].state == .pending {
        snapshot.entries[index].state = .importing
        try save(snapshot)
    }
    if !destinationExists { try fm.copyItem(at: stage, to: dest) }
    snapshot.entries[index].state = .imported
    snapshot.receipts.append("ticket")
    try save(snapshot, interrupted: interruptTerminal)
}
for round in 0..<48 {
    if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
    try original.write(to: stage, options: .atomic)
    try save(Snapshot(entries: [
        Entry(id: "ticket", state: .pending, filename: "song.mp3"),
        Entry(id: "cancelled", state: .cancelled, filename: "cancelled.mp3")
    ], receipts: []))
    do { try complete(interruptTerminal: true); try check(false, "interrupted commit succeeded") }
    catch ReplayError.interrupted {}
    try check(try load().entries[0].state == .importing, "pending state lost")
    try check(try Data(contentsOf: dest) == original, "copied recording lost")
    // Simulate process death, including lost temporary URLSession staging.
    if round % 3 == 0 { try fm.removeItem(at: stage) }
    try complete()
    if fm.fileExists(atPath: stage.path) { try fm.removeItem(at: stage) }
    try complete() // late duplicate after stage cleanup must be idempotent
    let result = try load()
    try check(result.receipts == ["ticket"], "duplicate receipt")
    try check(result.entries[1].state == .cancelled, "cancelled ticket changed")
    try check(try Data(contentsOf: dest) == original, "recording mutated")
    try check(try Data(contentsOf: other) == unrelated, "unrelated audio mutated")
    if round % 2 == 0 {
        let valid = try Data(contentsOf: journal)
        try Data("{bad".utf8).write(to: journal, options: .atomic)
        do { try complete(); try check(false, "corrupt journal accepted") }
        catch ReplayError.corrupt {}
        try valid.write(to: journal, options: .atomic)
    }
}
// A persisted terminal receipt must not mask deletion, substitution, or a
// symlink introduced between launches. Invalid files must remain untouched.
try save(Snapshot(entries: [Entry(id: "ticket", state: .imported, filename: "song.mp3")],
                  receipts: ["ticket"]))
try original.write(to: dest, options: .atomic)
try complete()
try fm.removeItem(at: dest)
do { try complete(); try check(false, "terminal receipt accepted missing audio") }
catch ReplayError.missing {}
try unrelated.write(to: dest, options: .atomic)
do { try complete(); try check(false, "terminal receipt accepted foreign audio") }
catch ReplayError.conflict {}
try fm.removeItem(at: dest)
try fm.createSymbolicLink(at: dest, withDestinationURL: other)
do { try complete(); try check(false, "terminal receipt accepted symlink") }
catch ReplayError.unsafe {}
try fm.removeItem(at: dest)
try fm.createDirectory(at: dest, withIntermediateDirectories: false)
do { try complete(); try check(false, "terminal receipt accepted directory") }
catch ReplayError.unsafe {}
try fm.removeItem(at: dest)
try check(try load().receipts == ["ticket"], "invalid terminal check rewrote receipt")
try check(try Data(contentsOf: other) == unrelated, "foreign target modified")
try original.write(to: dest, options: .atomic)
try complete()
try check(try load().receipts == ["ticket"], "recovery duplicated receipt")
try fm.removeItem(at: dest)
// Neither absent nor foreign destination bytes can authorize a receipt.
try save(Snapshot(entries: [Entry(id: "ticket", state: .importing, filename: "song.mp3")], receipts: []))
if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
do { try complete(); try check(false, "missing destination accepted") }
catch ReplayError.missing {}
try check(try load().receipts.isEmpty, "missing audio published receipt")
try Data("foreign recording".utf8).write(to: dest, options: .atomic)
do { try complete(); try check(false, "foreign destination accepted") }
catch ReplayError.conflict {}
try check(try load().receipts.isEmpty, "foreign audio published receipt")
try check(try Data(contentsOf: dest) == Data("foreign recording".utf8), "foreign audio modified")
print("PASS: 48 crash/replay rounds (16 without staging), 48 duplicates, 24 corrupt journals, terminal receipt integrity and unsafe path rejection")
