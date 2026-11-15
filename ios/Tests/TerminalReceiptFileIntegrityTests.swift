import Foundation

// Run: swift ios/Tests/TerminalReceiptFileIntegrityTests.swift
// Independent filesystem model, not a production URLSession integration test.
enum IntegrityFailure: Error { case absent, unsafe, changed, corrupt }
struct Receipt: Codable {
    let ticket: UUID
    let expectedSize: Int
    let expectedBytes: Data
}
func assertTrue(_ ok: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !ok() { throw NSError(domain: "ReceiptIntegrity", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("receipt-integrity-\(UUID())")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let recording = root.appendingPathComponent("recording.mp3")
let external = root.appendingPathComponent("external.mp3")
let journal = root.appendingPathComponent("receipt.json")
let bytes = Data((0..<65536).map { UInt8(($0 * 19 + 7) % 251) })
let foreign = Data((0..<65536).map { UInt8(($0 * 23 + 3) % 251) })
try foreign.write(to: external)
let receipt = Receipt(ticket: UUID(), expectedSize: bytes.count, expectedBytes: bytes)
try JSONEncoder().encode(receipt).write(to: journal, options: .atomic)

func validate() throws {
    let state: Receipt
    do { state = try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: journal)) }
    catch { throw IntegrityFailure.corrupt }
    guard state.ticket == receipt.ticket else { throw IntegrityFailure.corrupt }
    // Inspect the directory entry itself: fileExists follows symlinks and
    // considers directories to exist, neither of which proves a safe file.
    if (try? fm.destinationOfSymbolicLink(atPath: recording.path)) != nil {
        throw IntegrityFailure.unsafe
    }
    let attributes: [FileAttributeKey: Any]
    do { attributes = try fm.attributesOfItem(atPath: recording.path) }
    catch { throw IntegrityFailure.absent }
    guard attributes[.type] as? FileAttributeType == .typeRegular else {
        throw IntegrityFailure.unsafe
    }
    guard (attributes[.size] as? NSNumber)?.intValue == state.expectedSize,
          state.expectedSize > 0 else { throw IntegrityFailure.changed }
    guard try Data(contentsOf: recording) == state.expectedBytes else {
        throw IntegrityFailure.changed
    }
}
func reject(_ expected: IntegrityFailure, _ label: String) throws {
    do {
        try validate()
        try assertTrue(false, "\(label) accepted")
    } catch let actual as IntegrityFailure {
        try assertTrue(String(describing: actual) == String(describing: expected),
                       "\(label): wrong rejection \(actual)")
    }
    try assertTrue(try Data(contentsOf: external) == foreign, "external bytes changed")
    try assertTrue(try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: journal)).ticket == receipt.ticket,
                   "journal changed")
}
for round in 0..<64 {
    try bytes.write(to: recording, options: .atomic)
    try validate()
    try fm.removeItem(at: recording)
    try reject(.absent, "missing imported audio")
    try foreign.write(to: recording)
    try reject(.changed, "foreign same-size audio")
    try fm.removeItem(at: recording)
    try Data().write(to: recording)
    try reject(.changed, "empty audio")
    try fm.removeItem(at: recording)
    try fm.createDirectory(at: recording, withIntermediateDirectories: false)
    try reject(.unsafe, "directory placeholder")
    try fm.removeItem(at: recording)
    try fm.createSymbolicLink(at: recording, withDestinationURL: external)
    try reject(.unsafe, "symlink to foreign audio")
    try fm.removeItem(at: recording)
    try fm.createSymbolicLink(atPath: recording.path, withDestinationPath: root.appendingPathComponent("missing.mp3").path)
    try reject(.unsafe, "dangling symlink")
    try fm.removeItem(at: recording)
    try bytes.write(to: recording, options: .atomic)
    try validate()
    if round % 2 == 0 {
        let saved = try Data(contentsOf: journal)
        try Data("{broken".utf8).write(to: journal, options: .atomic)
        try reject(.corrupt, "corrupted journal")
        try saved.write(to: journal, options: .atomic)
    }
}
print("PASS: 64 receipt validation/recovery rounds, 384 invalid filesystem cases, 32 corrupt journals")
