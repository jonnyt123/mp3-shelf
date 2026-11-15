import Foundation

struct Receipt: Codable, Equatable { let ticket: String; let generation: Int; let file: String }
struct Journal: Codable, Equatable { var pending: [String: Int]; var receipts: [Receipt] }
enum RecoveryError: Error { case stale, duplicate, corrupt, injected }
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
    guard ["a.mp3", "b.mp3"].contains(receipt.file) else { throw RecoveryError.corrupt }
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
