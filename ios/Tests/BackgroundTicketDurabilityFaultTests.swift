import Foundation

// Standalone deterministic filesystem model, NOT production URLSession integration.
// Run: swift -swift-version 6 ios/Tests/BackgroundTicketDurabilityFaultTests.swift
enum Fault: Error { case injected, invalid, conflict }
struct TicketRecord: Codable, Equatable {
    let ticket: String
    let generation: Int
    let audioName: String
    let expectedBytes: Int
}
final class DurableTicketStore {
    private let root: URL
    private let fm = FileManager.default
    init(_ root: URL) { self.root = root }
    private func path(_ name: String) -> URL { root.appendingPathComponent(name) }
    func read(_ ticket: String) throws -> TicketRecord? {
        guard ticket.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { throw Fault.invalid }
        let file = path("\(ticket).json")
        guard fm.fileExists(atPath: file.path) else { return nil }
        return try JSONDecoder().decode(TicketRecord.self, from: Data(contentsOf: file))
    }
    func arm(_ record: TicketRecord, failBeforePublish: Bool = false) throws {
        guard record.ticket.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil,
              record.audioName.range(of: "^[A-Za-z0-9_-]+\\.mp3$", options: .regularExpression) != nil,
              record.expectedBytes > 0, record.generation > 0 else { throw Fault.invalid }
        if let old = try read(record.ticket), old.generation >= record.generation { throw Fault.conflict }
        let temp = path("\(record.ticket).new")
        try JSONEncoder().encode(record).write(to: temp, options: .atomic)
        if failBeforePublish { throw Fault.injected }
        // Model only: removing an existing journal before moving the replacement
        // is NOT crash-atomic. Production must use an atomic replace or versioned journal.
        let journal = path("\(record.ticket).json")
        if fm.fileExists(atPath: journal.path) { try fm.removeItem(at: journal) }
        try fm.moveItem(at: temp, to: journal)
    }
    func complete(_ record: TicketRecord, bytes: Data, failBeforeCommit: Bool = false) throws -> Bool {
        guard let active = try read(record.ticket), active == record else { return false }
        guard bytes.count == record.expectedBytes else { throw Fault.invalid }
        let destination = path(record.audioName)
        guard !fm.fileExists(atPath: destination.path) else { return false }
        let stage = path("\(record.ticket).part")
        try bytes.write(to: stage, options: .atomic)
        if failBeforeCommit { throw Fault.injected }
        try fm.moveItem(at: stage, to: destination)
        return true
    }
}
func verify(_ condition: @autoclosure () throws -> Bool, _ message: String) {
    guard (try? condition()) == true else { fatalError(message) }
}
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("mp3-ticket-durability-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let store = DurableTicketStore(root)
for i in 0..<128 {
    let id = "ticket_\(i)"
    let record = TicketRecord(ticket: id, generation: 1, audioName: "song_\(i).mp3", expectedBytes: 4096 + i)
    let bytes = Data(repeating: UInt8(i % 251), count: record.expectedBytes)
    do { try store.arm(record, failBeforePublish: true); fatalError("journal fault ignored") }
    catch Fault.injected { }
    verify(try store.read(id) == nil, "partial journal became active")
    try store.arm(record)
    verify(try store.read(id) == record, "journal not persisted")
    let reopened = DurableTicketStore(root)
    do { _ = try reopened.complete(record, bytes: bytes, failBeforeCommit: true); fatalError("stage fault ignored") }
    catch Fault.injected { }
    verify(!fm.fileExists(atPath: root.appendingPathComponent(record.audioName).path), "incomplete audio published")
    verify(try reopened.complete(record, bytes: bytes), "valid completion rejected")
    verify(try !reopened.complete(record, bytes: Data(repeating: 0xFF, count: bytes.count)), "duplicate overwrote audio")
    verify(try Data(contentsOf: root.appendingPathComponent(record.audioName)) == bytes, "audio bytes changed")
    let stale = TicketRecord(ticket: id, generation: 0, audioName: record.audioName, expectedBytes: record.expectedBytes)
    verify(try !reopened.complete(stale, bytes: bytes), "stale generation accepted")
    do { try reopened.arm(record); fatalError("same generation overwrote journal") }
    catch Fault.conflict { }
}
for name in ["../outside.mp3", "nested/song.mp3", "song.m4a", "", "bad\n.mp3"] {
    do { try store.arm(TicketRecord(ticket: "unsafe", generation: 1, audioName: name, expectedBytes: 100)); fatalError("unsafe filename accepted") }
    catch Fault.invalid { }
}
for ticket in ["../escape", "nested/ticket", "", "a b"] {
    do { _ = try store.read(ticket); fatalError("unsafe ticket accepted") }
    catch Fault.invalid { }
}
print("PASS: 128 persisted ticket replay/fault/duplicate scenarios and 9 path rejection cases (model only)")
