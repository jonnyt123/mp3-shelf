import Foundation

// Run: swift ios/Tests/BackgroundReceiptCrossTicketIsolationTests.swift
// Independent filesystem fault model; not a production URLSession integration test.
struct Receipt: Codable, Equatable {
    let ticket: UUID
    let generation: Int
    let audioName: String
    let byteCount: Int
}
struct Journal: Codable, Equatable {
    var receipts: [Receipt]
    var pending: [UUID: Int]
}
enum Fault: Error { case stale, duplicate, corrupt, interrupted }
private func assertQA(_ ok: @autoclosure () throws -> Bool, _ reason: String) throws {
    if try !ok() { throw NSError(domain: "CrossTicketQA", code: 1, userInfo: [NSLocalizedDescriptionKey: reason]) }
}
let fs = FileManager.default
let root = fs.temporaryDirectory.appendingPathComponent("receipt-isolation-\(UUID().uuidString)", isDirectory: true)
try fs.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fs.removeItem(at: root) }
let journalURL = root.appendingPathComponent("receipts.json")
let a = UUID(), b = UUID()
let audioA = Data((0..<65536).map { UInt8(($0 * 13 + 7) % 251) })
let audioB = Data((0..<65536).map { UInt8(($0 * 29 + 3) % 251) })
let pathA = root.appendingPathComponent("a.mp3")
let pathB = root.appendingPathComponent("b.mp3")
try audioA.write(to: pathA)
try audioB.write(to: pathB)
func readJournal() throws -> Journal {
    let value: Journal
    do { value = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: journalURL)) }
    catch { throw Fault.corrupt }
    guard Set(value.receipts.map(\.ticket)).count == value.receipts.count,
          value.receipts.allSatisfy({ $0.generation >= 0 && $0.byteCount > 0 &&
              ($0.audioName == "a.mp3" || $0.audioName == "b.mp3") &&
              value.pending[$0.ticket] == $0.generation &&
              (($0.ticket == a && $0.audioName == "a.mp3" && $0.byteCount == audioA.count) ||
               ($0.ticket == b && $0.audioName == "b.mp3" && $0.byteCount == audioB.count)) }) &&
          Set(value.receipts.map(\.audioName)).count == value.receipts.count &&
          Set(value.pending.keys).isSubset(of: Set([a, b])) else { throw Fault.corrupt }
    return value
}
func writeJournal(_ value: Journal, interrupt: Bool = false) throws {
    if interrupt { throw Fault.interrupted }
    try JSONEncoder().encode(value).write(to: journalURL, options: .atomic)
}
func complete(_ ticket: UUID, generation: Int, file: URL, interrupt: Bool = false) throws {
    var state = try readJournal()
    guard state.pending[ticket] == generation else { throw Fault.stale }
    guard !state.receipts.contains(where: { $0.ticket == ticket }) else { throw Fault.duplicate }
    let expected = ticket == a ? (pathA, audioA) : (pathB, audioB)
    guard file.standardizedFileURL == expected.0.standardizedFileURL,
          (try? Data(contentsOf: file)) == expected.1 else { throw Fault.corrupt }
    state.receipts.append(Receipt(ticket: ticket, generation: generation,
                                  audioName: file.lastPathComponent, byteCount: expected.1.count))
    try writeJournal(state, interrupt: interrupt)
}
for round in 0..<64 {
    let generation = round + 1
    let baseline = Journal(receipts: [], pending: [a: generation, b: generation])
    try writeJournal(baseline)
    let bytesBefore = try Data(contentsOf: journalURL)
    do { try complete(a, generation: generation, file: pathA, interrupt: true); try assertQA(false, "interrupted commit succeeded") }
    catch Fault.interrupted {}
    try assertQA(try Data(contentsOf: journalURL) == bytesBefore, "interruption changed journal")
    do { try complete(a, generation: generation - 1, file: pathA); try assertQA(false, "stale callback accepted") }
    catch Fault.stale {}
    do { try complete(a, generation: generation, file: pathB); try assertQA(false, "foreign audio accepted") }
    catch Fault.corrupt {}
    try complete(b, generation: generation, file: pathB)
    try complete(a, generation: generation, file: pathA)
    for ticket in [a, b] {
        do { try complete(ticket, generation: generation, file: ticket == a ? pathA : pathB); try assertQA(false, "duplicate accepted") }
        catch Fault.duplicate {}
    }
    let recovered = try readJournal()
    try assertQA(Set(recovered.receipts.map(\.ticket)) == Set([a, b]), "cross-ticket receipt lost")
    try assertQA(recovered.receipts.count == 2, "duplicate receipt persisted")
    try assertQA(try Data(contentsOf: pathA) == audioA && Data(contentsOf: pathB) == audioB, "audio bytes mutated")
    // Persisted metadata can be syntactically valid but belong to another ticket.
    // Reject a swapped receipt before treating a recovered file as imported.
    let validBytes = try Data(contentsOf: journalURL)
    let forged = [
        Journal(receipts: [Receipt(ticket: a, generation: generation, audioName: "b.mp3", byteCount: audioB.count)], pending: baseline.pending),
        Journal(receipts: [Receipt(ticket: b, generation: generation, audioName: "a.mp3", byteCount: audioA.count)], pending: baseline.pending),
        Journal(receipts: [Receipt(ticket: a, generation: generation, audioName: "a.mp3", byteCount: audioA.count),
                           Receipt(ticket: b, generation: generation, audioName: "a.mp3", byteCount: audioA.count)], pending: baseline.pending),
        Journal(receipts: recovered.receipts, pending: baseline.pending.merging([UUID(): generation]) { old, _ in old }),
        Journal(receipts: [Receipt(ticket: a, generation: generation, audioName: "a.mp3", byteCount: audioA.count - 1)], pending: baseline.pending)
    ]
    for invalid in forged {
        try JSONEncoder().encode(invalid).write(to: journalURL, options: .atomic)
        do { _ = try readJournal(); try assertQA(false, "cross-ticket or forged metadata accepted") }
        catch Fault.corrupt {}
        try assertQA(try Data(contentsOf: pathA) == audioA && Data(contentsOf: pathB) == audioB,
                     "forged receipt modified preserved audio")
    }
    try validBytes.write(to: journalURL, options: .atomic)
    try assertQA(try readJournal() == recovered, "valid journal not recoverable after forged metadata")
    // Corrupt publication cannot be interpreted as a valid completion after restart.
    try Data("{\"receipts\":[{}]}".utf8).write(to: journalURL, options: .atomic)
    do { _ = try readJournal(); try assertQA(false, "corrupt journal accepted") }
    catch Fault.corrupt {}
    try assertQA(try Data(contentsOf: pathA) == audioA && Data(contentsOf: pathB) == audioB, "corrupt journal damaged audio")
}
print("PASS: 64 two-ticket crash/replay rounds, 320 forged-metadata rejections, stale/foreign/duplicate rejection and byte preservation")
