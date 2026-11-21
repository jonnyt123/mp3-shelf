import Foundation

// Independent Foundation-only journal crash-boundary contract.
// Run: swift ios/Tests/JournalCrashRecoveryBoundaryTests.swift
// This models filesystem invariants, not production downloader or device evidence.
struct Ticket: Codable, Equatable {
    let id: String
    let state: String
    let recording: String
}
struct Manifest: Codable, Equatable {
    let generation: Int
    let tickets: [Ticket]
}
enum JournalError: Error { case unsafePath, corruptJournal, interrupted }
func checked(_ condition: @autoclosure () throws -> Bool) throws {
    if try !condition() { fatalError("FAIL: assertion") }
}
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("mp3-journal-crash-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let journal = root.appendingPathComponent("active.json")
let audio = root.appendingPathComponent("recording.mp3")
let audioBytes = Data([0x49,0x44,0x33,0x04,0,0,0,0,0,0,0x01,0x02])
try audioBytes.write(to: audio)
let old = Manifest(generation: 7, tickets: [Ticket(id: "ticket-A", state: "queued", recording: "recording.mp3")])
let next = Manifest(generation: 8, tickets: [
    Ticket(id: "ticket-A", state: "completed", recording: "recording.mp3"),
    Ticket(id: "ticket-B", state: "queued", recording: "other.mp3")
])
let encoder = JSONEncoder()
func readJournal(_ url: URL) throws -> Manifest {
    guard let attributes = try? fm.attributesOfItem(atPath: url.path),
          attributes[.type] as? FileAttributeType == .typeRegular else { throw JournalError.unsafePath }
    do { return try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url)) }
    catch { throw JournalError.corruptJournal }
}
func publish(_ value: Manifest, at url: URL, interruptBeforeRename: Bool = false) throws {
    guard let attributes = try? fm.attributesOfItem(atPath: url.path),
          attributes[.type] as? FileAttributeType == .typeRegular else { throw JournalError.unsafePath }
    let parent = url.deletingLastPathComponent()
    let parentAttributes = try fm.attributesOfItem(atPath: parent.path)
    guard parentAttributes[.type] as? FileAttributeType == .typeDirectory else { throw JournalError.unsafePath }
    let pending = parent.appendingPathComponent(".pending-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: pending) }
    try encoder.encode(value).write(to: pending)
    if interruptBeforeRename { throw JournalError.interrupted }
    // Foundation atomic write is tested, not a claim of production fsync durability.
    try encoder.encode(value).write(to: url, options: .atomic)
}
func expectFailure(_ label: String, _ action: () throws -> Void) throws {
    do { try action(); fatalError("FAIL: \(label) accepted") }
    catch JournalError.unsafePath, JournalError.corruptJournal, JournalError.interrupted { }
}
try encoder.encode(old).write(to: journal)
try expectFailure("interrupted publish") { try publish(next, at: journal, interruptBeforeRename: true) }
try checked(try readJournal(journal) == old)
try checked(try Data(contentsOf: audio) == audioBytes)
try publish(next, at: journal)
try checked(try readJournal(journal) == next)
try checked(try Data(contentsOf: audio) == audioBytes)
try Data("{broken".utf8).write(to: journal, options: .atomic)
try expectFailure("corrupt journal") { _ = try readJournal(journal) }
try checked(try Data(contentsOf: journal) == Data("{broken".utf8))
try encoder.encode(next).write(to: journal, options: .atomic)
let external = root.appendingPathComponent("external.json")
try encoder.encode(old).write(to: external)
let link = root.appendingPathComponent("link.json")
try fm.createSymbolicLink(at: link, withDestinationURL: external)
try expectFailure("symlink journal") { try publish(next, at: link) }
try checked(try readJournal(external) == old)
let collision = root.appendingPathComponent("collision.json")
try fm.createDirectory(at: collision, withIntermediateDirectories: true)
try expectFailure("directory journal") { try publish(next, at: collision) }
try checked(try fm.attributesOfItem(atPath: collision.path)[.type] as? FileAttributeType == .typeDirectory)
try checked(try Data(contentsOf: audio) == audioBytes)
let large = Manifest(generation: 9, tickets: (0..<20_000).map {
    Ticket(id: "ticket-\($0)", state: "queued", recording: "song-\($0).mp3")
})
try publish(large, at: journal)
let restored = try readJournal(journal)
precondition(restored == large)
precondition(restored.tickets.first?.id == "ticket-0" && restored.tickets.last?.id == "ticket-19999")
try checked(try Data(contentsOf: audio) == audioBytes)
print("PASS: interrupted update, atomic publish, corruption, symlink, directory, 20k ticket round-trip, audio preservation")
