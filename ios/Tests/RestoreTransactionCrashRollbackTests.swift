import Foundation

// Standalone crash-window filesystem model; not production restore integration.
// swift ios/Tests/RestoreTransactionCrashRollbackTests.swift
struct Recovery: Codable {
    let transaction: UUID
    let staged: String
    let destination: String
    let expectedBytes: Int
}
enum RestoreFault: Error { case invalid, conflict }
func require(_ ok: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !ok() { throw NSError(domain: "RestoreTransactionQA", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("restore-crash-\(UUID())")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let destination = root.appendingPathComponent("library.mp3")
let staged = root.appendingPathComponent("incoming.part")
let journal = root.appendingPathComponent("restore.json")
let original = Data((0..<32768).map { UInt8(($0 * 11) % 251) })
let replacement = Data((0..<65536).map { UInt8(($0 * 19 + 3) % 251) })
let outside = root.appendingPathComponent("outside.mp3")
try original.write(to: outside)
func isRegularFile(_ url: URL) -> Bool {
    guard let attrs = try? fm.attributesOfItem(atPath: url.path),
          let kind = attrs[.type] as? FileAttributeType else { return false }
    return kind == .typeRegular
}
func recover(_ record: Recovery) throws {
    guard record.staged == staged.lastPathComponent,
          record.destination == destination.lastPathComponent,
          record.expectedBytes == replacement.count,
          isRegularFile(journal), isRegularFile(staged),
          (try Data(contentsOf: staged)) == replacement else { throw RestoreFault.invalid }
    // Existing user-owned files must not be overwritten by replay.
    guard !fm.fileExists(atPath: destination.path) else { throw RestoreFault.conflict }
    try fm.moveItem(at: staged, to: destination)
    try fm.removeItem(at: journal)
}
for _ in 0..<64 {
    for crashPoint in 0..<4 {
        for url in [destination, staged, journal] { try? fm.removeItem(at: url) }
        let record = Recovery(transaction: UUID(), staged: staged.lastPathComponent,
                              destination: destination.lastPathComponent, expectedBytes: replacement.count)
        // Stage, journal, then publish: crash at each boundary.
        if crashPoint >= 1 { try replacement.write(to: staged, options: .atomic) }
        if crashPoint >= 2 { try JSONEncoder().encode(record).write(to: journal, options: .atomic) }
        if crashPoint == 3 { try recover(record) }
        if crashPoint == 2 {
            try recover(record)
            try require((try Data(contentsOf: destination)) == replacement, "valid replay lost audio")
            try require(!fm.fileExists(atPath: journal.path), "committed journal remains")
        } else if crashPoint < 2 {
            try require(!fm.fileExists(atPath: destination.path), "uncommitted audio became visible")
        } else {
            try require((try Data(contentsOf: destination)) == replacement, "committed bytes changed")
        }
        try require((try Data(contentsOf: outside)) == original, "unrelated audio changed")
    }
    // A destination created during suspension belongs to another operation.
    for url in [destination, staged, journal] { try? fm.removeItem(at: url) }
    let record = Recovery(transaction: UUID(), staged: staged.lastPathComponent,
                          destination: destination.lastPathComponent, expectedBytes: replacement.count)
    try replacement.write(to: staged)
    try JSONEncoder().encode(record).write(to: journal)
    try original.write(to: destination)
    do { try recover(record); try require(false, "existing destination overwritten") }
    catch RestoreFault.conflict {}
    try require((try Data(contentsOf: destination)) == original, "existing user audio mutated")
    try require((try Data(contentsOf: staged)) == replacement, "recoverable staged audio lost")
    // Corrupt or symlinked staging must never be published.
    try fm.removeItem(at: destination)
    try Data(repeating: 0, count: replacement.count).write(to: staged)
    do { try recover(record); try require(false, "corrupt staging accepted") }
    catch RestoreFault.invalid {}
    try fm.removeItem(at: staged)
    try fm.createSymbolicLink(at: staged, withDestinationURL: outside)
    do { try recover(record); try require(false, "symlink staging accepted") }
    catch RestoreFault.invalid {}
    try require((try Data(contentsOf: outside)) == original, "symlink target damaged")
    try require(!fm.fileExists(atPath: destination.path), "invalid stage published")
}
print("PASS: 256 crash boundaries, 64 destination conflicts, 128 corrupt/symlink stage rejections; unrelated audio preserved")
print("LIMITATION: standalone Foundation model; production restore, Xcode, simulator and physical iPhone UNVERIFIED")
