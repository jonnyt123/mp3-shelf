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
enum ReplayError: Error { case corrupt, missing, conflict, interrupted }
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
func complete(interruptTerminal: Bool = false) throws {
    var snapshot = try load()
    guard let index = snapshot.entries.firstIndex(where: { $0.id == "ticket" }) else { throw ReplayError.corrupt }
    if snapshot.entries[index].state == .imported { return }
    guard snapshot.entries[index].state == .pending || snapshot.entries[index].state == .importing else { return }
    guard fm.fileExists(atPath: stage.path) else { throw ReplayError.missing }
    guard try Data(contentsOf: stage) == original else { throw ReplayError.conflict }
    if snapshot.entries[index].state == .pending {
        snapshot.entries[index].state = .importing
        try save(snapshot)
    }
    if fm.fileExists(atPath: dest.path) {
        guard try Data(contentsOf: dest) == original else { throw ReplayError.conflict }
    } else {
        try fm.copyItem(at: stage, to: dest)
    }
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
    // Simulate process death: no retained in-memory state; reload durable journal.
    try complete()
    try fm.removeItem(at: stage)
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
print("PASS: 48 crash/replay rounds, 48 duplicate callbacks after stage cleanup, 24 corrupt-journal rejections, byte preservation")
