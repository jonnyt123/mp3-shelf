import Foundation

// Run: swift ios/Tests/ReceiptPublicationCrashMatrixTests.swift
// Independent Foundation crash model; not a production URLSession or iPhone test.
enum Fault: Error { case injected, invalid }
struct Ticket: Codable, Equatable {
    enum Phase: String, Codable { case queued, copying, imported, cancelled }
    var id: String
    var phase: Phase
    var file: String
}
struct Ledger: Codable, Equatable {
    var tickets: [Ticket]
    var receipts: [String]
}
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("receipt-crash-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let journal = root.appendingPathComponent("journal.json")
let source = root.appendingPathComponent("download.tmp")
let destination = root.appendingPathComponent("recording.mp3")
let other = root.appendingPathComponent("unrelated.mp3")
let bytes = Data((0..<65536).map { UInt8(($0 * 31 + 7) % 251) })
let otherBytes = Data((0..<65536).map { UInt8(($0 * 13 + 19) % 251) })
try otherBytes.write(to: other)

func require(_ ok: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !ok { throw NSError(domain: "ReceiptCrashQA", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
func isSafeRegular(_ url: URL) -> Bool {
    guard (try? fm.destinationOfSymbolicLink(atPath: url.path)) == nil,
          let attrs = try? fm.attributesOfItem(atPath: url.path),
          attrs[.type] as? FileAttributeType == .typeRegular,
          (attrs[.referenceCount] as? NSNumber)?.intValue == 1 else { return false }
    return true
}
func read() throws -> Ledger {
    guard isSafeRegular(journal),
          let ledger = try? JSONDecoder().decode(Ledger.self, from: Data(contentsOf: journal)),
          ledger.tickets.count == 2,
          Set(ledger.tickets.map(\.id)).count == 2,
          ledger.tickets[0].id == "a", ledger.tickets[0].file == "recording.mp3",
          ledger.tickets[1] == Ticket(id: "b", phase: .queued, file: "unrelated.mp3"),
          ledger.receipts.allSatisfy({ $0 == "a" }),
          ledger.receipts.count <= 1,
          (ledger.tickets[0].phase == .imported) == (ledger.receipts == ["a"]) else {
        throw Fault.invalid
    }
    return ledger
}
func publish(_ ledger: Ledger, fail: Bool = false) throws {
    if fail { throw Fault.injected }
    guard !fm.fileExists(atPath: journal.path) || isSafeRegular(journal) else { throw Fault.invalid }
    try JSONEncoder().encode(ledger).write(to: journal, options: .atomic)
}
func replay(failAt step: Int = -1) throws {
    var ledger = try read()
    if ledger.tickets[0].phase == .imported {
        guard isSafeRegular(destination), try Data(contentsOf: destination) == bytes else { throw Fault.invalid }
        return
    }
    guard ledger.tickets[0].phase == .queued || ledger.tickets[0].phase == .copying else { throw Fault.invalid }
    if ledger.tickets[0].phase == .queued {
        ledger.tickets[0].phase = .copying
        try publish(ledger, fail: step == 0)
    }
    let alreadyCopied = isSafeRegular(destination) && (try Data(contentsOf: destination) == bytes)
    if !alreadyCopied {
        guard !fm.fileExists(atPath: destination.path), isSafeRegular(source),
              try Data(contentsOf: source) == bytes else { throw Fault.invalid }
        if step == 1 { throw Fault.injected }
        try fm.copyItem(at: source, to: destination)
    }
    if step == 2 { throw Fault.injected }
    ledger.tickets[0].phase = .imported
    ledger.receipts = ["a"]
    try publish(ledger, fail: step == 3)
}
for failure in 0...3 {
    for round in 0..<24 {
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try bytes.write(to: source, options: .atomic)
        try publish(Ledger(tickets: [
            Ticket(id: "a", phase: .queued, file: "recording.mp3"),
            Ticket(id: "b", phase: .queued, file: "unrelated.mp3")
        ], receipts: []))
        do { try replay(failAt: failure); try require(false, "injected failure did not stop replay") }
        catch Fault.injected {}
        if round % 2 == 0 && fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: source) // process death loses staging after copy
        }
        try replay()
        try replay() // duplicate callback after receipt publication
        let ledger = try read()
        try require(ledger.receipts == ["a"] && ledger.tickets[0].phase == .imported,
                    "missing or duplicated terminal receipt")
        try require(ledger.tickets[1].phase == .queued, "unrelated ticket changed")
        try require(try Data(contentsOf: destination) == bytes, "recording corrupted")
        try require(try Data(contentsOf: other) == otherBytes, "unrelated audio changed")
    }
}
try require(try read().receipts == ["a"], "final checkpoint invalid")
print("PASS: 96 injected crash/retry cases, duplicate receipts, byte-exact isolation")
