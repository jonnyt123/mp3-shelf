import Foundation

// swift ios/Tests/BackgroundCompletionJournalAtomicityTests.swift
// Filesystem fault-injection reference model; does not invoke production URLSession.
private enum Fault: Error { case journalWrite, corruptJournal, missingStage, mismatchedStage }
private struct Ticket: Codable, Equatable {
    enum Status: String, Codable { case queued, importing, imported, cancelled }
    var id: UUID
    var status: Status
    var recording: String
}
private struct Journal: Codable, Equatable {
    var tickets: [Ticket]
    var receipts: Set<UUID>
}
private func require(_ ok: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !ok() { throw NSError(domain: "CompletionJournalQA", code: 1,
                               userInfo: [NSLocalizedDescriptionKey: message]) }
}
private let fm = FileManager.default
private let root = fm.temporaryDirectory.appendingPathComponent("mp3-completion-atomicity-\(UUID())")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
private let journalURL = root.appendingPathComponent("tickets.json")
private let stageURL = root.appendingPathComponent("stage.mp3")
private let libraryURL = root.appendingPathComponent("library.mp3")
private let unrelatedURL = root.appendingPathComponent("unrelated.mp3")
private let audio = Data((0..<65536).map { UInt8(($0 * 13 + 17) % 251) })
private let unrelated = Data((0..<65536).map { UInt8(($0 * 7 + 31) % 251) })
private let ticketID = UUID()
private let cancelledID = UUID()
private let unrelatedID = UUID()
private let original = Journal(tickets: [
    Ticket(id: ticketID, status: .queued, recording: "library.mp3"),
    Ticket(id: cancelledID, status: .cancelled, recording: "cancelled.mp3"),
    Ticket(id: unrelatedID, status: .queued, recording: "unrelated.mp3")
], receipts: [])
try audio.write(to: stageURL)
try unrelated.write(to: unrelatedURL)

private func readJournal() throws -> Journal {
    let bytes = try Data(contentsOf: journalURL)
    let value: Journal
    do { value = try JSONDecoder().decode(Journal.self, from: bytes) }
    catch { throw Fault.corruptJournal }
    let ids = value.tickets.map(\.id)
    guard Set(ids).count == ids.count,
          value.receipts.allSatisfy({ id in
              value.tickets.contains(where: { $0.id == id && $0.status == .imported })
          }),
          value.tickets.allSatisfy({ $0.status != .imported || value.receipts.contains($0.id) })
    else { throw Fault.corruptJournal }
    return value
}
private func publish(_ value: Journal, fail: Bool = false) throws {
    if fail { throw Fault.journalWrite }
    try JSONEncoder().encode(value).write(to: journalURL, options: .atomic)
}
private func complete(failReceipt: Bool = false) throws {
    var state = try readJournal()
    guard let index = state.tickets.firstIndex(where: { $0.id == ticketID }) else {
        throw Fault.corruptJournal
    }
    if state.tickets[index].status == .imported { return }
    guard state.tickets[index].status == .queued || state.tickets[index].status == .importing
    else { return }
    guard fm.fileExists(atPath: stageURL.path) else { throw Fault.missingStage }
    guard try Data(contentsOf: stageURL) == audio else { throw Fault.mismatchedStage }
    if state.tickets[index].status == .queued {
        state.tickets[index].status = .importing
        try publish(state)
    }
    // A staged recording remains authoritative until both the library bytes
    // and the durable terminal receipt are confirmed. Duplicate callbacks
    // must not remove the staging input during this crash window.
    if fm.fileExists(atPath: libraryURL.path) {
        guard try Data(contentsOf: libraryURL) == audio else { throw Fault.mismatchedStage }
    } else {
        try fm.copyItem(at: stageURL, to: libraryURL)
    }
    state.tickets[index].status = .imported
    state.receipts.insert(ticketID)
    try publish(state, fail: failReceipt)
}
private func reset() throws {
    try publish(original)
    if fm.fileExists(atPath: libraryURL.path) { try fm.removeItem(at: libraryURL) }
    try audio.write(to: stageURL, options: .atomic)
}
for round in 0..<64 {
    try reset()
    do {
        try complete(failReceipt: true)
        try require(false, "journal failure unexpectedly acknowledged")
    } catch Fault.journalWrite {}
    try require(try readJournal().tickets[0].status == .importing,
                "failed terminal publication changed durable state")
    try require(try readJournal().receipts.isEmpty, "failed publication left receipt")
    try require(try Data(contentsOf: libraryURL) == audio, "copy lost after failed receipt")
    try require(try Data(contentsOf: stageURL) == audio, "staging lost after failed receipt")
    try require(try Data(contentsOf: unrelatedURL) == unrelated, "other audio changed")
    try complete()
    try complete() // Duplicate URLSession completion after successful recovery.
    let recovered = try readJournal()
    try require(recovered.tickets[0].status == .imported && recovered.receipts == [ticketID],
                "replay did not commit exactly one terminal receipt")
    try require(try Data(contentsOf: libraryURL) == audio, "replay changed imported bytes")
    try require(try Data(contentsOf: unrelatedURL) == unrelated, "replay changed unrelated audio")
    if round % 2 == 0 {
        // Corruption must fail closed without deleting the imported recording.
        let valid = try Data(contentsOf: journalURL)
        try Data("{broken".utf8).write(to: journalURL, options: .atomic)
        do {
            try complete()
            try require(false, "corrupt journal treated as empty queue")
        } catch Fault.corruptJournal {}
        try require(try Data(contentsOf: libraryURL) == audio, "corruption deleted audio")
        try valid.write(to: journalURL, options: .atomic)
    }
}
try reset()
try fm.removeItem(at: stageURL)
do {
    try complete()
    try require(false, "missing staging was accepted")
} catch Fault.missingStage {}
try require(!fm.fileExists(atPath: libraryURL.path), "missing stage produced recording")
try require(try readJournal().receipts.isEmpty, "missing stage produced receipt")
try require(try Data(contentsOf: unrelatedURL) == unrelated, "missing stage damaged other audio")
print("PASS: 64 terminal-journal failures, 64 idempotent duplicate callbacks, 32 corrupt-journal rejections, missing-stage fail-closed, 64-KiB byte preservation")
