import Foundation

struct Receipt: Codable, Equatable { let ticket: String; let generation: Int; let file: String }
struct Journal: Codable, Equatable { var pending: [String: Int]; var receipts: [Receipt] }
enum RecoveryError: Error { case stale, duplicate, corrupt, injected }
// This is a Foundation-only failure model, not a production downloader test.
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("mp3shelf-receipt-recovery-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let journalURL = root.appendingPathComponent("journal.json")
let audioA = root.appendingPathComponent("a.mp3")
let audioB = root.appendingPathComponent("b.mp3")
let a = Data((0..<65536).map { UInt8($0 % 251) })
let b = Data((0..<65536).map { UInt8(($0 * 7) % 251) })
try a.write(to: audioA)
try b.write(to: audioB)
func read() throws -> Journal { try JSONDecoder().decode(Journal.self, from: Data(contentsOf: journalURL)) }
func publish(_ receipt: Receipt, fail: Bool = false) throws {
    var state = try read()
    guard state.pending[receipt.ticket] == receipt.generation else { throw RecoveryError.stale }
    guard !state.receipts.contains(where: { $0.ticket == receipt.ticket }) else { throw RecoveryError.duplicate }
    // Ticket ownership and media identity are separate invariants. A valid
    // filename belonging to another ticket must not be accepted as a receipt.
    let expected = receipt.ticket == "A" ? "a.mp3" : receipt.ticket == "B" ? "b.mp3" : nil
    guard receipt.file == expected, let expected else { throw RecoveryError.corrupt }
    let candidate = root.appendingPathComponent(expected)
    // Reject directory/symlink placeholders even if the filename is plausible.
    let attributes = try fm.attributesOfItem(atPath: candidate.path)
    guard attributes[.type] as? FileAttributeType == .typeRegular else { throw RecoveryError.corrupt }
    let payload = try Data(contentsOf: candidate)
    guard payload == (receipt.ticket == "A" ? a : b) else { throw RecoveryError.corrupt }
    state.receipts.append(receipt)
    if fail { throw RecoveryError.injected }
    try JSONEncoder().encode(state).write(to: journalURL, options: .atomic)
}
func require(_ ok: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !ok() { throw NSError(domain: "ReceiptRecovery", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
for round in 0..<64 {
    let generation = round + 1
    let baseline = Journal(pending: ["A": generation, "B": generation], receipts: [])
    try JSONEncoder().encode(baseline).write(to: journalURL, options: .atomic)
    let first = Receipt(ticket: "A", generation: generation, file: "a.mp3")
    let second = Receipt(ticket: "B", generation: generation, file: "b.mp3")
    try publish(first)
    let durable = try Data(contentsOf: journalURL)
    do { try publish(second, fail: true); throw RecoveryError.corrupt }
    catch RecoveryError.injected { }
    try require(try Data(contentsOf: journalURL) == durable, "failed publication modified journal")
    try require(try read().receipts == [first], "relaunch lost first receipt")
    try publish(second)
    try require(try read().receipts == [first, second], "replay failed")
    let completed = try Data(contentsOf: journalURL)
    do { try publish(first); throw RecoveryError.corrupt }
    catch RecoveryError.duplicate { }
    do { try publish(Receipt(ticket: "B", generation: generation - 1, file: "b.mp3")); throw RecoveryError.corrupt }
    catch RecoveryError.stale { }
    try require(try Data(contentsOf: journalURL) == completed, "rejected callback rewrote journal")
    try require(try Data(contentsOf: audioA) == a && Data(contentsOf: audioB) == b, "audio changed")
}
print("PASS: 64 crash/relaunch receipt replay rounds; two audio payloads byte-identical")

// An attacker-controlled or damaged manifest must fail closed. In particular,
// a valid-looking audio path may point at the wrong ticket, a symlink, a
// directory or bytes that no longer match the originally staged recording.
for round in 0..<64 {
    let generation = 1000 + round
    let baseline = Journal(pending: ["A": generation, "B": generation], receipts: [])
    try JSONEncoder().encode(baseline).write(to: journalURL, options: .atomic)
    let original = try Data(contentsOf: journalURL)
    let wrongOwner = Receipt(ticket: "A", generation: generation, file: "b.mp3")
    do { try publish(wrongOwner); throw RecoveryError.injected }
    catch RecoveryError.corrupt { }
    try require(try Data(contentsOf: journalURL) == original, "cross-ticket receipt changed journal")

    let placeholder = root.appendingPathComponent("a.mp3")
    let moved = root.appendingPathComponent("a-saved.mp3")
    try fm.moveItem(at: placeholder, to: moved)
    defer {
        if fm.fileExists(atPath: moved.path) {
            try? fm.removeItem(at: placeholder)
            try? fm.moveItem(at: moved, to: placeholder)
        }
    }
    try fm.createSymbolicLink(at: placeholder, withDestinationURL: moved)
    do { try publish(Receipt(ticket: "A", generation: generation, file: "a.mp3")); throw RecoveryError.injected }
    catch RecoveryError.corrupt { }
    try require(try Data(contentsOf: journalURL) == original, "symlink receipt changed journal")
    try fm.removeItem(at: placeholder)
    try fm.createDirectory(at: placeholder, withIntermediateDirectories: false)
    do { try publish(Receipt(ticket: "A", generation: generation, file: "a.mp3")); throw RecoveryError.injected }
    catch RecoveryError.corrupt { }
    try require(try Data(contentsOf: journalURL) == original, "directory receipt changed journal")
    try fm.removeItem(at: placeholder)
    try fm.moveItem(at: moved, to: placeholder)

    var damaged = a
    damaged[round % damaged.count] ^= 0xFF
    try damaged.write(to: placeholder, options: .atomic)
    do { try publish(Receipt(ticket: "A", generation: generation, file: "a.mp3")); throw RecoveryError.injected }
    catch RecoveryError.corrupt { }
    try require(try Data(contentsOf: journalURL) == original, "corrupt audio changed journal")
    try a.write(to: placeholder, options: .atomic)
    try publish(Receipt(ticket: "A", generation: generation, file: "a.mp3"))
    try publish(Receipt(ticket: "B", generation: generation, file: "b.mp3"))
    try require(try read().receipts.count == 2, "valid replay failed after corrupt placeholders")
    try require(try Data(contentsOf: audioA) == a && Data(contentsOf: audioB) == b, "audio altered")
}
print("PASS: 64 adversarial receipt-ownership, symlink, directory, corrupt-byte and replay rounds")
