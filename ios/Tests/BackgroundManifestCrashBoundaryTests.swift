import Foundation

// Run: swift ios/Tests/BackgroundManifestCrashBoundaryTests.swift
// Filesystem-level fault injection; not an iOS URLSession integration test.
struct Entry: Codable, Equatable {
    enum State: String, Codable { case queued, imported, cancelled }
    let id: UUID
    var state: State
    let filename: String
}
struct Manifest: Codable, Equatable {
    var generation: Int
    var entries: [Entry]
}
enum Fault: Error { case interrupted, invalid, stale }
func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw NSError(domain: "ManifestCrashQA", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("manifest-crash-\(UUID())")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let manifestURL = root.appendingPathComponent("tickets.json")
let pendingURL = root.appendingPathComponent("tickets.pending")
let audioURL = root.appendingPathComponent("saved.mp3")
let audio = Data((0..<32768).map { UInt8(($0 * 17 + 9) % 251) })
try audio.write(to: audioURL, options: .atomic)
let song = UUID(), other = UUID()
func read() throws -> Manifest {
    let data = try Data(contentsOf: manifestURL)
    let value = try JSONDecoder().decode(Manifest.self, from: data)
    guard value.generation >= 0,
          Set(value.entries.map(\.id)).count == value.entries.count,
          value.entries.allSatisfy({ !$0.filename.isEmpty && !$0.filename.contains("/") && !$0.filename.contains("..") })
    else { throw Fault.invalid }
    return value
}
func publish(_ next: Manifest, interruptBeforeRename: Bool = false) throws {
    let previous = try read()
    guard next.generation == previous.generation + 1 else { throw Fault.stale }
    try JSONEncoder().encode(next).write(to: pendingURL, options: .atomic)
    if interruptBeforeRename { throw Fault.interrupted }
    // A failed write never removes the previously durable manifest.
    _ = try fm.replaceItemAt(manifestURL, withItemAt: pendingURL)
}
for round in 0..<64 {
    let baseline = Manifest(generation: round * 2, entries: [
        Entry(id: song, state: .queued, filename: "saved.mp3"),
        Entry(id: other, state: .queued, filename: "other.mp3")
    ])
    try JSONEncoder().encode(baseline).write(to: manifestURL, options: .atomic)
    let originalJournal = try Data(contentsOf: manifestURL)
    let next = Manifest(generation: baseline.generation + 1, entries: [
        Entry(id: song, state: .imported, filename: "saved.mp3"),
        baseline.entries[1]
    ])
    do { try publish(next, interruptBeforeRename: true); try check(false, "interrupted write succeeded") }
    catch Fault.interrupted {}
    try check(try Data(contentsOf: manifestURL) == originalJournal, "interruption damaged previous journal")
    try check(try read() == baseline, "relaunch observed uncommitted state")
    try check(try Data(contentsOf: audioURL) == audio, "interruption modified audio")
    do { try publish(Manifest(generation: baseline.generation + 2, entries: next.entries)); try check(false, "stale generation accepted") }
    catch Fault.stale {}
    try publish(next)
    try check(try read() == next, "committed manifest not recovered")
    try check(try Data(contentsOf: audioURL) == audio, "successful publication modified audio")
    do { try publish(next); try check(false, "duplicate publication accepted") }
    catch Fault.stale {}
    try check(try read() == next, "duplicate changed committed state")
    try check((try read()).entries[1] == baseline.entries[1], "unrelated ticket changed")
}
let valid = try read()
for invalid in [
    Manifest(generation: valid.generation, entries: valid.entries + [valid.entries[0]]),
    Manifest(generation: valid.generation, entries: [Entry(id: song, state: .imported, filename: "../escape.mp3")]),
    Manifest(generation: -1, entries: valid.entries)
] {
    try JSONEncoder().encode(invalid).write(to: manifestURL, options: .atomic)
    do { _ = try read(); try check(false, "invalid journal accepted") }
    catch Fault.invalid {}
    try check(try Data(contentsOf: audioURL) == audio, "invalid journal modified audio")
}
print("PASS: 64 interrupted/committed manifest cycles, stale/duplicate rejection, 3 invalid manifests, audio preserved")
