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
    do {
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
        guard manifest.generation >= 0 else { throw JournalError.corruptJournal }
        var ticketIDs = Set<String>()
        var destinations = Set<String>()
        for ticket in manifest.tickets {
            guard !ticket.id.isEmpty, ticketIDs.insert(ticket.id).inserted,
                  ["queued", "completed", "failed", "cancelled"].contains(ticket.state),
                  !ticket.recording.isEmpty,
                  !ticket.recording.hasPrefix("."),
                  !ticket.recording.contains("/"),
                  !ticket.recording.contains("\\"),
                  ticket.recording != "..",
                  destinations.insert(ticket.recording).inserted
            else { throw JournalError.corruptJournal }
        }
        return manifest
    } catch { throw JournalError.corruptJournal }
}
func publish(_ value: Manifest, at url: URL, interruptBeforeRename: Bool = false) throws {
    guard let attributes = try? fm.attributesOfItem(atPath: url.path),
          attributes[.type] as? FileAttributeType == .typeRegular else { throw JournalError.unsafePath }
    // A normal immediate parent can still live below a symlinked ancestor.
    // Reject every symlink between the fixture's owned root and the journal.
    let canonicalRoot = root.standardizedFileURL.path
    let canonicalTarget = url.standardizedFileURL.path
    guard canonicalTarget.hasPrefix(canonicalRoot + "/") else { throw JournalError.unsafePath }
    var ancestor = url.deletingLastPathComponent()
    while ancestor.standardizedFileURL.path != canonicalRoot {
        guard ancestor.standardizedFileURL.path.hasPrefix(canonicalRoot + "/"),
              (try? fm.destinationOfSymbolicLink(atPath: ancestor.path)) == nil else {
            throw JournalError.unsafePath
        }
        ancestor.deleteLastPathComponent()
    }
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

// A syntactically valid but semantically unsafe checkpoint must fail closed.
// The audio file and last known-good manifest are never rewritten by rejection.
let unsafeManifests: [(String, Manifest)] = [
    ("negative generation", Manifest(generation: -1, tickets: old.tickets)),
    ("duplicate ticket", Manifest(generation: 10, tickets: [old.tickets[0], old.tickets[0]])),
    ("duplicate destination", Manifest(generation: 10, tickets: [
        Ticket(id: "one", state: "queued", recording: "same.mp3"),
        Ticket(id: "two", state: "queued", recording: "same.mp3")
    ])),
    ("empty ticket", Manifest(generation: 10, tickets: [Ticket(id: "", state: "queued", recording: "x.mp3")])),
    ("unknown state", Manifest(generation: 10, tickets: [Ticket(id: "x", state: "mystery", recording: "x.mp3")])),
    ("traversal", Manifest(generation: 10, tickets: [Ticket(id: "x", state: "queued", recording: "../audio.mp3")])),
    ("absolute path", Manifest(generation: 10, tickets: [Ticket(id: "x", state: "queued", recording: "/tmp/audio.mp3")])),
    ("windows separator", Manifest(generation: 10, tickets: [Ticket(id: "x", state: "queued", recording: "folder\\\\audio.mp3")])),
    ("hidden path", Manifest(generation: 10, tickets: [Ticket(id: "x", state: "queued", recording: ".hidden.mp3")]))
]
for (label, unsafe) in unsafeManifests {
    let badBytes = try encoder.encode(unsafe)
    try badBytes.write(to: journal, options: .atomic)
    try expectFailure(label) { _ = try readJournal(journal) }
    try checked(try Data(contentsOf: journal) == badBytes)
    try checked(try Data(contentsOf: audio) == audioBytes)
}
try encoder.encode(next).write(to: journal, options: .atomic)
try checked(try readJournal(journal) == next)
let external = root.appendingPathComponent("external.json")
try encoder.encode(old).write(to: external)
let link = root.appendingPathComponent("link.json")
try fm.createSymbolicLink(at: link, withDestinationURL: external)
try expectFailure("symlink journal") { try publish(next, at: link) }
try checked(try readJournal(external) == old)
// A hostile replacement of the journal's parent with a symlink must not
// redirect publication outside the owned staging directory. The fixture
// deliberately uses a separate directory to preserve the live journal.
let outside = fm.temporaryDirectory.appendingPathComponent("mp3-journal-outside-\(UUID().uuidString)")
try fm.createDirectory(at: outside, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: outside) }
let outsideJournal = outside.appendingPathComponent("active.json")
try encoder.encode(old).write(to: outsideJournal)
let linkedParent = root.appendingPathComponent("linked-parent")
try fm.createSymbolicLink(at: linkedParent, withDestinationURL: outside)
let redirectedJournal = linkedParent.appendingPathComponent("active.json")
// The existing publish helper only checks the immediate parent attributes;
// this adversarial case must remain a negative regression even if a future
// implementation changes its write strategy.
try expectFailure("symlink parent") { try publish(next, at: redirectedJournal) }
try checked(try readJournal(outsideJournal) == old)
try checked(try Data(contentsOf: audio) == audioBytes)
// The immediate parent is a real directory, but its grandparent is a link.
// A one-level-only check incorrectly permits this redirection.
let nested = linkedParent.appendingPathComponent("nested")
try fm.createDirectory(at: outside.appendingPathComponent("nested"), withIntermediateDirectories: true)
let nestedJournal = outside.appendingPathComponent("nested/active.json")
try encoder.encode(old).write(to: nestedJournal)
try expectFailure("symlink ancestor") {
    try publish(next, at: nested.appendingPathComponent("active.json"))
}
try checked(try readJournal(nestedJournal) == old)
try checked(try Data(contentsOf: audio) == audioBytes)
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

// Recovery stress: interrupted writes and valid atomic replacements must never
// expose a partial JSON document to a concurrent reader. This is a filesystem
// contract, not a claim about iOS process termination or fsync durability.
let readerQueue = DispatchQueue(label: "mp3-journal-reader")
let writerQueue = DispatchQueue(label: "mp3-journal-writer")
let group = DispatchGroup()
final class FailureRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var failure: String?
    func record(_ message: String) { lock.lock(); defer { lock.unlock() }; if failure == nil { failure = message } }
    var message: String? { lock.lock(); defer { lock.unlock() }; return failure }
}
let recorder = FailureRecorder()
let versions = (0..<256).map { generation in
    Manifest(generation: 100 + generation, tickets: [
        Ticket(id: "ticket-A", state: generation.isMultiple(of: 2) ? "queued" : "completed",
               recording: "recording.mp3"),
        Ticket(id: "ticket-\(generation)", state: "queued", recording: "other.mp3")
    ])
}
try publish(versions[0], at: journal)
group.enter()
readerQueue.async {
    defer { group.leave() }
    for _ in 0..<4096 {
        do {
            let value = try readJournal(journal)
            if !versions.contains(value) {
                recorder.record("reader saw unexpected complete manifest")
                break
            }
        } catch {
            recorder.record("reader saw partial or invalid journal: \(error)")
            break
        }
    }
}
group.enter()
writerQueue.async {
    defer { group.leave() }
    for (index, version) in versions.enumerated().dropFirst() {
        do {
            if index.isMultiple(of: 3) {
                try expectFailure("stress interrupted publish") {
                    try publish(version, at: journal, interruptBeforeRename: true)
                }
            } else {
                try publish(version, at: journal)
            }
        } catch {
            recorder.record("writer failed: \(error)")
            break
        }
    }
}
group.wait()
try checked(recorder.message == nil)
try checked(versions.contains(try readJournal(journal)))
try checked(try Data(contentsOf: audio) == audioBytes)
let pendingFiles = try fm.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".pending-") }
try checked(pendingFiles.isEmpty)

print("PASS: crash boundaries, nine semantic corruption cases, 20k ticket round-trip, 256-version concurrent atomic read/write, no pending files, audio preserved")
