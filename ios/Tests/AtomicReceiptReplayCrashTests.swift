import Foundation

// Foundation-only crash/replay fixture. Not a production URLSession or device test.
// Run: swift ios/Tests/AtomicReceiptReplayCrashTests.swift
struct CrashReceipt: Codable {
    let ticket: UUID
    let generation: Int
    let filename: String
    let expected: Data
}
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("crash-replay-\(UUID())")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let audio = root.appendingPathComponent("audio.mp3")
let journal = root.appendingPathComponent("receipt.json")
let external = root.appendingPathComponent("external.mp3")
let bytes = Data((0..<8192).map { UInt8($0 % 251) })
let foreign = Data(repeating: 99, count: 8192)
try foreign.write(to: external)
let ticket = UUID()
let receipt = CrashReceipt(ticket: ticket, generation: 8, filename: "audio.mp3", expected: bytes)
func publish(_ state: CrashReceipt = receipt) throws {
    try JSONEncoder().encode(state).write(to: journal, options: .atomic)
}
func recover(ticket: UUID, generation: Int) throws -> Data? {
    guard (try? fm.destinationOfSymbolicLink(atPath: journal.path)) == nil,
          let ja = try? fm.attributesOfItem(atPath: journal.path),
          ja[.type] as? FileAttributeType == .typeRegular,
          (ja[.referenceCount] as? NSNumber)?.intValue == 1,
          let state = try? JSONDecoder().decode(CrashReceipt.self, from: Data(contentsOf: journal)),
          state.ticket == ticket, state.generation == generation,
          state.filename == "audio.mp3", !state.expected.isEmpty,
          (try? fm.destinationOfSymbolicLink(atPath: audio.path)) == nil,
          let aa = try? fm.attributesOfItem(atPath: audio.path),
          aa[.type] as? FileAttributeType == .typeRegular,
          (aa[.referenceCount] as? NSNumber)?.intValue == 1,
          (aa[.size] as? NSNumber)?.intValue == state.expected.count else { return nil }
    let actual = try Data(contentsOf: audio)
    return actual == state.expected ? actual : nil
}
func check(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
    let ok = try condition()
    precondition(ok, label)
}
func reset() throws {
    for url in [audio, journal] where fm.fileExists(atPath: url.path) || (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil {
        try fm.removeItem(at: url)
    }
}
for _ in 0..<80 {
    try reset()
    try publish()
    try check(try recover(ticket: ticket, generation: 8) == nil, "missing audio")
    try fm.removeItem(at: journal)
    try bytes.write(to: audio, options: .atomic)
    try check(try recover(ticket: ticket, generation: 8) == nil, "orphan audio")
    try publish()
    for _ in 0..<3 { try check(try recover(ticket: ticket, generation: 8) == bytes, "idempotent replay") }
    try check(try recover(ticket: ticket, generation: 7) == nil, "stale generation")
    try check(try recover(ticket: UUID(), generation: 8) == nil, "foreign ticket")
    try Data("{incomplete".utf8).write(to: journal, options: .atomic)
    try check(try recover(ticket: ticket, generation: 8) == nil, "corrupt journal")
    try publish(CrashReceipt(ticket: ticket, generation: 8, filename: "../external.mp3", expected: bytes))
    try check(try recover(ticket: ticket, generation: 8) == nil, "traversal filename")
    try publish(CrashReceipt(ticket: ticket, generation: 8, filename: "audio.mp3", expected: Data()))
    try check(try recover(ticket: ticket, generation: 8) == nil, "empty receipt")
    try publish()
    try Data().write(to: audio, options: .atomic)
    try check(try recover(ticket: ticket, generation: 8) == nil, "zero-byte audio")
    try Data(bytes.dropLast()).write(to: audio, options: .atomic)
    try check(try recover(ticket: ticket, generation: 8) == nil, "truncated audio")
    try foreign.write(to: audio, options: .atomic)
    try check(try recover(ticket: ticket, generation: 8) == nil, "same-size audio substitution")
    try fm.removeItem(at: audio)
    try fm.createSymbolicLink(at: audio, withDestinationURL: external)
    try check(try recover(ticket: ticket, generation: 8) == nil, "audio symlink")
    try fm.removeItem(at: audio)
    try fm.linkItem(at: external, to: audio)
    try check(try recover(ticket: ticket, generation: 8) == nil, "audio hardlink")
    try fm.removeItem(at: audio)
    try fm.createDirectory(at: audio, withIntermediateDirectories: false)
    try check(try recover(ticket: ticket, generation: 8) == nil, "audio directory")
    try fm.removeItem(at: audio)
    try bytes.write(to: audio, options: .atomic)
    try fm.removeItem(at: journal)
    try fm.linkItem(at: external, to: journal)
    try check(try recover(ticket: ticket, generation: 8) == nil, "journal hardlink")
    try fm.removeItem(at: journal)
    try fm.createDirectory(at: journal, withIntermediateDirectories: false)
    try check(try recover(ticket: ticket, generation: 8) == nil, "journal directory")
    try fm.removeItem(at: journal)
    try fm.createSymbolicLink(at: journal, withDestinationURL: external)
    try check(try recover(ticket: ticket, generation: 8) == nil, "journal symlink")
    try check(try Data(contentsOf: external) == foreign, "external file modified")
    // A partially written unpublished receipt cannot replace committed state.
    try reset()
    try bytes.write(to: audio, options: .atomic)
    try publish()
    let pending = root.appendingPathComponent("receipt-pending-\(UUID()).json")
    let encoded = try JSONEncoder().encode(receipt)
    try Data(encoded.prefix(encoded.count / 2)).write(to: pending)
    try check(try recover(ticket: ticket, generation: 8) == bytes, "unpublished partial receipt altered committed recovery")
    try check(try Data(contentsOf: journal) == encoded, "committed journal modified")
    try fm.removeItem(at: pending)
    try publish(CrashReceipt(ticket: ticket, generation: 9, filename: "audio.mp3", expected: bytes))
    try check(try recover(ticket: ticket, generation: 8) == nil, "stale generation after replacement")
    try check(try recover(ticket: ticket, generation: 9) == bytes, "new generation not recoverable")
    try check(try Data(contentsOf: audio) == bytes, "audio changed on generation transition")

    // A staged replacement is not visible until publication; malformed replacements
    // fail closed and never mutate the independently owned recording bytes.
    let staged = root.appendingPathComponent("receipt-next-\(UUID()).json")
    let next = CrashReceipt(ticket: ticket, generation: 10, filename: "audio.mp3", expected: bytes)
    let nextData = try JSONEncoder().encode(next)
    try Data(nextData.prefix(nextData.count / 3)).write(to: staged, options: .atomic)
    try check(try recover(ticket: ticket, generation: 9) == bytes, "partial staged generation displaced committed receipt")
    try check(try recover(ticket: ticket, generation: 10) == nil, "unpublished generation became visible")
    try nextData.write(to: staged, options: .atomic)
    try check(try recover(ticket: ticket, generation: 9) == bytes, "complete staged generation displaced committed receipt")
    try fm.removeItem(at: journal)
    try fm.moveItem(at: staged, to: journal)
    try check(try recover(ticket: ticket, generation: 9) == nil, "old generation survived committed handoff")
    try check(try recover(ticket: ticket, generation: 10) == bytes, "committed handoff lost recording")

    // A receipt whose bytes are correct but whose identity is substituted must
    // never be treated as an authorized completion.
    try publish(CrashReceipt(ticket: UUID(), generation: 10, filename: "audio.mp3", expected: bytes))
    try check(try recover(ticket: ticket, generation: 10) == nil, "foreign receipt accepted")
    try publish(CrashReceipt(ticket: ticket, generation: 10, filename: "audio.mp3", expected: foreign))
    try check(try recover(ticket: ticket, generation: 10) == nil, "substituted audio digest accepted")
    try check(try Data(contentsOf: audio) == bytes, "failed receipt replay changed owned audio")
    try check(try Data(contentsOf: external) == foreign, "failed replay changed unrelated audio")


}
print("PASS: 80 crash/replay rounds; interrupted/staged publication, generation handoff, identity and audio isolation")
