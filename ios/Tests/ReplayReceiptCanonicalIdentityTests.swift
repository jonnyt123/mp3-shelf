import Foundation

// Run: swift ios/Tests/ReplayReceiptCanonicalIdentityTests.swift
// Standalone journal identity model; does not exercise production URLSession.
struct Ticket: Codable {
    let id: String
    let destination: String
    let imported: Bool
}
struct Journal: Codable {
    let tickets: [Ticket]
    let receipts: [String]
}
enum JournalError: Error { case corrupt }
func canonical(_ value: String) -> String {
    value.precomposedStringWithCanonicalMapping
        .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
}
func validate(_ data: Data) throws -> Journal {
    // Reject oversized journals before decoding attacker-controlled arrays.
    guard data.count <= 128 * 1024,
          let journal = try? JSONDecoder().decode(Journal.self, from: data),
          journal.tickets.count <= 256,
          journal.receipts.count <= 256 else { throw JournalError.corrupt }
    let ids = journal.tickets.map { canonical($0.id) }
    let destinations = journal.tickets.map { canonical($0.destination) }
    let receipts = journal.receipts.map(canonical)
    guard Set(ids).count == ids.count,
          Set(destinations).count == destinations.count,
          Set(receipts).count == receipts.count,
          journal.tickets.allSatisfy({
              !$0.id.isEmpty && !$0.destination.isEmpty &&
              $0.id.utf8.count <= 128 && $0.destination.utf8.count <= 255 &&
              !$0.destination.hasPrefix(".") &&
              !$0.destination.contains("/") && !$0.destination.contains("\\") &&
              !$0.destination.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
          }),
          journal.receipts.allSatisfy({ receipt in
              journal.tickets.contains { canonical($0.id) == canonical(receipt) && $0.imported }
          }),
          journal.tickets.allSatisfy({ !$0.imported || receipts.contains(canonical($0.id)) })
    else { throw JournalError.corrupt }
    return journal
}
func encode(_ value: Journal) throws -> Data { try JSONEncoder().encode(value) }
func expectCorrupt(_ journal: Journal) throws {
    do { _ = try validate(encode(journal)); fatalError("corrupt journal accepted") }
    catch JournalError.corrupt {}
}
let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
let audio = root.appendingPathComponent("owned.mp3")
let bytes = Data((0..<65536).map { UInt8(($0 * 13 + 7) % 251) })
try bytes.write(to: audio)
let valid = Journal(tickets: [Ticket(id: "one", destination: "owned.mp3", imported: true)],
                    receipts: ["one"])
let snapshot = try encode(valid)
_ = try validate(snapshot)
let collisions: [Journal] = [
    Journal(tickets: [
        Ticket(id: "ABC", destination: "one.mp3", imported: true),
        Ticket(id: "abc", destination: "two.mp3", imported: true)
    ], receipts: ["ABC", "abc"]),
    Journal(tickets: [
        Ticket(id: "café", destination: "one.mp3", imported: false),
        Ticket(id: "cafe\u{301}", destination: "two.mp3", imported: false)
    ], receipts: []),
    Journal(tickets: [
        Ticket(id: "a", destination: "SONG.mp3", imported: false),
        Ticket(id: "b", destination: "song.mp3", imported: false)
    ], receipts: []),
    Journal(tickets: [Ticket(id: "one", destination: "owned.mp3", imported: true)],
            receipts: ["one", "ONE"]),
    Journal(tickets: [Ticket(id: "one", destination: "../owned.mp3", imported: false)], receipts: []),
    Journal(tickets: [Ticket(id: "one", destination: "owned.mp3", imported: false)], receipts: ["one"]),
    Journal(tickets: [Ticket(id: "one", destination: "owned.mp3", imported: true)], receipts: []),
    Journal(tickets: [Ticket(id: String(repeating: "x", count: 129),
                             destination: "owned.mp3", imported: false)], receipts: [])
]
for invalid in collisions {
    try expectCorrupt(invalid)
    guard try Data(contentsOf: audio) == bytes else { fatalError("audio mutated by rejection") }
}
let oversized = Data(repeating: 32, count: 128 * 1024 + 1)
do { _ = try validate(oversized); fatalError("oversized journal accepted") }
catch JournalError.corrupt {}
guard try encode(valid) == snapshot,
      try Data(contentsOf: audio) == bytes else { fatalError("valid state mutated") }
print("PASS: canonical IDs, receipt uniqueness, bounded journal, owned audio preserved")
