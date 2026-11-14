import Foundation

// Foundation-only fault-injection test for journal publication and replay.
// This exercises real filesystem writes, not BackgroundAudioDownloader.
struct Entry: Codable, Equatable { let id: UUID; let state: String }
enum JournalFailure: Error { case corrupt, injected, duplicate }
struct DurableJournal {
    let path: URL
    func load() throws -> [Entry]? {
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let bytes = try Data(contentsOf: path)
        guard let entries = try? JSONDecoder().decode([Entry].self, from: bytes),
              Set(entries.map(\.id)).count == entries.count else { throw JournalFailure.corrupt }
        return entries
    }
    func publish(_ entries: [Entry], failAfterTemporaryWrite: Bool = false) throws {
        guard Set(entries.map(\.id)).count == entries.count else { throw JournalFailure.duplicate }
        _ = try load() // fail closed if the existing durable journal is corrupt
        let temporary = path.deletingLastPathComponent().appendingPathComponent(".journal-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try JSONEncoder().encode(entries).write(to: temporary)
        if failAfterTemporaryWrite { throw JournalFailure.injected }
        // Replace existing durable bytes only after fully encoding the new manifest.
        // On Apple platforms a production implementation must additionally ensure
        // appropriate fsync/rename durability and directory synchronization.
        try Data(contentsOf: temporary).write(to: path, options: .atomic)
    }
}
func assert(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { fatalError(message) }
}
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("mp3qa-crash-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let journal = DurableJournal(path: root.appendingPathComponent("tickets.json"))
let first = Entry(id: UUID(), state: "queued")
let second = Entry(id: UUID(), state: "queued")
let stageA = root.appendingPathComponent("a.mp3")
let stageB = root.appendingPathComponent("b.mp3")
let bytesA = Data((0..<8192).map { UInt8($0 % 251) })
let bytesB = Data((0..<8192).map { UInt8(($0 + 3) % 251) })
try bytesA.write(to: stageA)
try bytesB.write(to: stageB)
try assert(journal.load() == nil, "Missing journal confused with corrupt journal")
try journal.publish([first, second])
let initial = try Data(contentsOf: journal.path)
for _ in 0..<25 {
    do { try journal.publish([first], failAfterTemporaryWrite: true); fatalError("Failure not injected") }
    catch JournalFailure.injected {}
    try assert(Data(contentsOf: journal.path) == initial, "Partial publication replaced journal")
    try assert(journal.load() == [first, second], "Relaunch lost a queued ticket")
    try assert(Data(contentsOf: stageA) == bytesA && Data(contentsOf: stageB) == bytesB,
               "Failed write modified staged audio")
}
for bad in [Data(), Data("null".utf8), Data("[{".utf8), try JSONEncoder().encode([first, first])] {
    try bad.write(to: journal.path, options: .atomic)
    let original = try Data(contentsOf: journal.path)
    do { _ = try journal.load(); fatalError("Corrupt journal accepted") }
    catch JournalFailure.corrupt {}
    do { try journal.publish([second]); fatalError("Corrupt journal overwritten") }
    catch JournalFailure.corrupt {}
    try assert(Data(contentsOf: journal.path) == original, "Corrupt recovery evidence changed")
    try assert(Data(contentsOf: stageA) == bytesA && Data(contentsOf: stageB) == bytesB,
               "Corrupt manifest removed user audio")
}
try initial.write(to: journal.path, options: .atomic) // explicit repair
try journal.publish([first, Entry(id: second.id, state: "cancelled")])
try assert(journal.load()?.last?.state == "cancelled", "Repair and retry failed")
try assert(Data(contentsOf: stageA) == bytesA && Data(contentsOf: stageB) == bytesB,
           "Repair modified staged audio")
print("PASS: 25 interrupted publications, 4 corrupt journals, two-ticket isolation and byte-exact repair")
