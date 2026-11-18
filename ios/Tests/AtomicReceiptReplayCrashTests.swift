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
func publish() throws {
    try JSONEncoder().encode(receipt).write(to: journal, options: .atomic)
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
for round in 0..<80 {
    try? fm.removeItem(at: audio)
    try? fm.removeItem(at: journal)
    try publish()
    try check(try recover(ticket: ticket, generation: 8) == nil, "missing audio")
    try fm.removeItem(at: journal)
    try bytes.write(to: audio, options: .atomic)
    try check(try recover(ticket: ticket, generation: 8) == nil, "orphan audio")
    try publish()
    for _ in 0..<3 {
        try check(try recover(ticket: ticket, generation: 8) == bytes, "idempotent replay")
    }
    try check(try recover(ticket: ticket, generation: 7) == nil, "stale generation")
    try check(try recover(ticket: UUID(), generation: 8) == nil, "foreign ticket")
    try Data("{incomplete".utf8).write(to: journal, options: .atomic)
    try check(try recover(ticket: ticket, generation: 8) == nil, "corrupt journal")
    try publish()
    try foreign.write(to: audio, options: .atomic)
    try check(try recover(ticket: ticket, generation: 8) == nil, "same-size audio substitution")
    try fm.removeItem(at: audio)
    try fm.createSymbolicLink(at: audio, withDestinationURL: external)
    try check(try recover(ticket: ticket, generation: 8) == nil, "audio symlink")
    try fm.removeItem(at: audio)
    try bytes.write(to: audio, options: .atomic)
    if round % 2 == 0 {
        try fm.removeItem(at: journal)
        try fm.createSymbolicLink(at: journal, withDestinationURL: external)
        try check(try recover(ticket: ticket, generation: 8) == nil, "journal symlink")
    }
}
try check(try Data(contentsOf: external) == foreign, "foreign audio mutated")
print("PASS: 80 crash/replay rounds, 8 rejection/idempotency boundaries")
