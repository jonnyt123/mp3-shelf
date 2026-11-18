import Foundation

// Foundation-only filesystem fault injection, not production restore or iPhone proof.
// Run: swift ios/Tests/RestoreJournalFailureMatrixTests.swift
struct RestoreRecord: Codable {
    let id: UUID
    let relativeName: String
    let bytes: Data
}
struct RestoreIntent: Codable {
    let generation: Int
    let records: [RestoreRecord]
}
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("restore-matrix-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let live = root.appendingPathComponent("live", isDirectory: true)
let staging = root.appendingPathComponent("staging", isDirectory: true)
let journal = root.appendingPathComponent("restore-intent.json")
let outside = root.appendingPathComponent("outside.mp3")
try fm.createDirectory(at: live, withIntermediateDirectories: true)
let original = Data(repeating: 0x42, count: 8192)
let replacement = Data(repeating: 0x61, count: 16384)
let untouched = Data(repeating: 0x33, count: 2048)
try original.write(to: live.appendingPathComponent("owned.mp3"))
try untouched.write(to: live.appendingPathComponent("other.mp3"))
try untouched.write(to: outside)
let id = UUID()
let intent = RestoreIntent(generation: 17, records: [RestoreRecord(id: id, relativeName: "owned.mp3", bytes: replacement)])
func assertState(_ expected: Data, _ label: String) throws {
    let owned = try Data(contentsOf: live.appendingPathComponent("owned.mp3"))
    let other = try Data(contentsOf: live.appendingPathComponent("other.mp3"))
    let external = try Data(contentsOf: outside)
    precondition(owned == expected, "\(label): owned bytes changed")
    precondition(other == untouched, "\(label): unrelated recording changed")
    precondition(external == untouched, "\(label): external recording changed")
}
func regularUnlinked(_ url: URL) -> Bool {
    guard (try? fm.destinationOfSymbolicLink(atPath: url.path)) == nil,
          let attrs = try? fm.attributesOfItem(atPath: url.path),
          attrs[.type] as? FileAttributeType == .typeRegular,
          (attrs[.referenceCount] as? NSNumber)?.intValue == 1 else { return false }
    return true
}
func safeName(_ name: String) -> Bool {
    !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\") && !name.contains("\0")
}
// Recovery must not modify existing user audio before the complete intent validates.
func validate(_ expectedGeneration: Int) throws -> Bool {
    guard regularUnlinked(journal),
          let data = try? Data(contentsOf: journal),
          let decoded = try? JSONDecoder().decode(RestoreIntent.self, from: data),
          decoded.generation == expectedGeneration,
          !decoded.records.isEmpty else { return false }
    var seen = Set<String>()
    for record in decoded.records {
        guard safeName(record.relativeName), seen.insert(record.relativeName).inserted,
              !record.bytes.isEmpty else { return false }
        let staged = staging.appendingPathComponent(record.relativeName)
        guard regularUnlinked(staged),
              let stagedBytes = try? Data(contentsOf: staged),
              stagedBytes == record.bytes else { return false }
    }
    return true
}
func reset() throws {
    if fm.fileExists(atPath: staging.path) { try fm.removeItem(at: staging) }
    try fm.createDirectory(at: staging, withIntermediateDirectories: true)
    if fm.fileExists(atPath: journal.path) || (try? fm.destinationOfSymbolicLink(atPath: journal.path)) != nil { try fm.removeItem(at: journal) }
    try original.write(to: live.appendingPathComponent("owned.mp3"), options: .atomic)
}
for round in 0..<40 {
    try reset()
    try JSONEncoder().encode(intent).write(to: journal, options: .atomic)
    precondition(!((try? validate(17)) ?? false), "missing staged bytes accepted")
    try assertState(original, "missing stage")
    try replacement.prefix(100).write(to: staging.appendingPathComponent("owned.mp3"))
    precondition(!((try? validate(17)) ?? false), "partial staged bytes accepted")
    try assertState(original, "partial stage")
    try replacement.write(to: staging.appendingPathComponent("owned.mp3"), options: .atomic)
    precondition((try? validate(17)) == true, "valid restore stage rejected")
    precondition(!((try? validate(16)) ?? false), "stale generation accepted")
    try assertState(original, "validated but unpublished")
    try JSONEncoder().encode(RestoreIntent(generation: 17, records: [
        RestoreRecord(id: id, relativeName: "owned.mp3", bytes: replacement),
        RestoreRecord(id: UUID(), relativeName: "owned.mp3", bytes: replacement)
    ])).write(to: journal, options: .atomic)
    precondition(!((try? validate(17)) ?? false), "duplicate target accepted")
    try assertState(original, "duplicate target")
    for bad in ["../outside.mp3", "/outside.mp3", "subdir/owned.mp3", "..", "\\outside.mp3", ""] {
        try JSONEncoder().encode(RestoreIntent(generation: 17, records: [RestoreRecord(id: id, relativeName: bad, bytes: replacement)])).write(to: journal, options: .atomic)
        precondition(!((try? validate(17)) ?? false), "unsafe target accepted: \(bad)")
        try assertState(original, "unsafe target")
    }
    try JSONEncoder().encode(intent).write(to: journal, options: .atomic)
    try fm.removeItem(at: staging.appendingPathComponent("owned.mp3"))
    try fm.createSymbolicLink(at: staging.appendingPathComponent("owned.mp3"), withDestinationURL: outside)
    precondition(!((try? validate(17)) ?? false), "staging symlink accepted")
    try assertState(original, "staging symlink")
    try fm.removeItem(at: staging.appendingPathComponent("owned.mp3"))
    try fm.linkItem(at: outside, to: staging.appendingPathComponent("owned.mp3"))
    precondition(!((try? validate(17)) ?? false), "staging hardlink accepted")
    try assertState(original, "staging hardlink")
    try fm.removeItem(at: staging.appendingPathComponent("owned.mp3"))
    try replacement.write(to: staging.appendingPathComponent("owned.mp3"), options: .atomic)
    try fm.removeItem(at: journal)
    try fm.createSymbolicLink(at: journal, withDestinationURL: outside)
    precondition(!((try? validate(17)) ?? false), "journal symlink accepted")
    try assertState(original, "journal symlink")
    if round == 0 { print("Validated missing, partial, duplicate, traversal, generation, symlink and hardlink rejection") }
}
print("PASS: 40 filesystem restore fault-injection rounds; unrelated recordings preserved")
