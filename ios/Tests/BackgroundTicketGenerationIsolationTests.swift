import Foundation

// Run: swift ios/Tests/BackgroundTicketGenerationIsolationTests.swift
// Standalone deterministic model; not a production URLSession integration test.
struct Ticket: Codable, Equatable {
    enum State: String, Codable { case queued, downloading, cancelled, imported }
    var id: String
    var generation: Int
    var state: State
    var filename: String
}
struct Ledger: Codable { var tickets: [Ticket]; var receipts: [String] }
enum Failure: Error { case stale, cancelled, duplicate, interrupted, invalid }
func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw NSError(domain: "TicketGenerationQA", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("ticket-generation-\(UUID())")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let journal = root.appendingPathComponent("queue.json")
let stage = root.appendingPathComponent("staging.mp3")
let destination = root.appendingPathComponent("recording.mp3")
let unrelated = root.appendingPathComponent("unrelated.mp3")
let original = Data((0..<65536).map { UInt8(($0 * 13 + 5) % 251) })
let foreign = Data((0..<65536).map { UInt8(($0 * 29 + 11) % 251) })
try foreign.write(to: unrelated)
func persist(_ ledger: Ledger, fail: Bool = false) throws {
    if fail { throw Failure.interrupted }
    try JSONEncoder().encode(ledger).write(to: journal, options: .atomic)
}
func restore() throws -> Ledger {
    let value = try JSONDecoder().decode(Ledger.self, from: Data(contentsOf: journal))
    guard Set(value.tickets.map(\.id)).count == value.tickets.count,
          Set(value.receipts).count == value.receipts.count,
          value.receipts.allSatisfy({ id in value.tickets.contains { $0.id == id && $0.state == .imported } })
    else { throw Failure.invalid }
    return value
}
func callback(ticketID: String, generation: Int, payload: URL, interrupt: Bool = false) throws {
    var ledger = try restore()
    guard let index = ledger.tickets.firstIndex(where: { $0.id == ticketID }) else { throw Failure.stale }
    let ticket = ledger.tickets[index]
    guard ticket.generation == generation else { throw Failure.stale }
    guard ticket.state != .cancelled else { throw Failure.cancelled }
    if ticket.state == .imported { throw Failure.duplicate }
    guard ticket.state == .downloading else { throw Failure.stale }
    guard payload.standardizedFileURL == stage.standardizedFileURL,
          let attributes = try? fm.attributesOfItem(atPath: payload.path),
          attributes[.type] as? FileAttributeType == .typeRegular,
          (attributes[.size] as? NSNumber)?.intValue == original.count,
          try Data(contentsOf: payload) == original else { throw Failure.invalid }
    // Terminal receipt must be durable before moving/removing staged bytes.
    ledger.tickets[index].state = .imported
    ledger.receipts.append(ticketID)
    try persist(ledger, fail: interrupt)
    if !fm.fileExists(atPath: destination.path) { try fm.copyItem(at: payload, to: destination) }
}
for round in 0..<64 {
    if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
    try original.write(to: stage, options: .atomic)
    try persist(Ledger(tickets: [Ticket(id: "song", generation: round * 2 + 2, state: .downloading, filename: "recording.mp3"), Ticket(id: "other", generation: 1, state: .queued, filename: "unrelated.mp3")], receipts: []))
    let before = try Data(contentsOf: journal)
    do { try callback(ticketID: "song", generation: round * 2 + 1, payload: stage); try require(false, "old generation accepted") }
    catch Failure.stale {}
    do { try callback(ticketID: "song", generation: round * 2 + 2, payload: unrelated); try require(false, "foreign payload accepted") }
    catch Failure.invalid {}
    do { try callback(ticketID: "song", generation: round * 2 + 2, payload: stage, interrupt: true); try require(false, "interrupted receipt accepted") }
    catch Failure.interrupted {}
    try require(try Data(contentsOf: journal) == before, "failed callback changed durable journal")
    try require(!fm.fileExists(atPath: destination.path), "audio moved before receipt commit")
    try callback(ticketID: "song", generation: round * 2 + 2, payload: stage)
    do { try callback(ticketID: "song", generation: round * 2 + 2, payload: stage); try require(false, "duplicate accepted") }
    catch Failure.duplicate {}
    let saved = try restore()
    try require(saved.receipts == ["song"], "duplicate or missing receipt")
    try require(saved.tickets[1].state == .queued, "unrelated ticket mutated")
    try require(try Data(contentsOf: destination) == original, "recording bytes changed")
    try require(try Data(contentsOf: unrelated) == foreign, "unrelated audio changed")
    // A cancellation and requeue increments the generation, invalidating callbacks
    // from the former task even when its ticket ID is reused.
    try persist(Ledger(tickets: [Ticket(id: "song", generation: round * 2 + 3, state: .cancelled, filename: "recording.mp3")], receipts: []))
    do { try callback(ticketID: "song", generation: round * 2 + 2, payload: stage); try require(false, "cancelled old generation accepted") }
    catch Failure.stale {}
    do { try callback(ticketID: "song", generation: round * 2 + 3, payload: stage); try require(false, "cancelled current generation accepted") }
    catch Failure.cancelled {}
    try require((try restore()).receipts.isEmpty, "cancelled ticket published receipt")
}
print("PASS: 64 generation-isolation rounds, 64 interrupted receipts, 64 duplicates, 128 cancelled/stale callbacks")
