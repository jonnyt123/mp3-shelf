import Foundation

// Run from repo root against integrated candidate #29:
//   swift ios/Tests/BackgroundCancellationOwnershipTests.swift
// Run the deterministic Foundation-only fixture on this web/QA branch:
//   swift ios/Tests/BackgroundCancellationOwnershipTests.swift --fixture-only
// --fixture-only does NOT verify production source contracts or URLSession behavior.
let fixtureOnly = CommandLine.arguments.dropFirst().contains("--fixture-only")
let productionPath = "ios/MP3Shelf/Services/BackgroundAudioDownloader.swift"
func check(_ ok: Bool, _ why: String) {
    guard ok else { fatalError(why) }
}
if !fixtureOnly {
    guard FileManager.default.fileExists(atPath: productionPath) else {
        fatalError("Native downloader source absent. Run on integrated candidate #29, or pass --fixture-only for Foundation-only QA.")
    }
    let source = try String(contentsOfFile: productionPath, encoding: .utf8)
    func slice(_ start: String, _ end: String) -> String {
        guard let a = source.range(of: start),
              let b = source.range(of: end, range: a.upperBound..<source.endIndex) else {
            fatalError("Missing native callback contract: \(start)")
        }
        return String(source[a.lowerBound..<b.lowerBound])
    }
    let cancel = slice("func cancelTransfer(_ id: UUID", "func pendingCount(")
    let finish = slice("didFinishDownloadingTo location: URL)", "didWriteData bytesWritten:")
    let error = slice("didCompleteWithError error: Error?)", "urlSessionDidFinishEvents(")
    let a = cancel.range(of: "try BackgroundTicketManifestPolicy.write(")
    let b = cancel.range(of: "tickets = updated")
    let c = cancel.range(of: "conversions[id]?.cancel()")
    let d = cancel.range(of: "session.getAllTasks")
    check(a != nil && b != nil && c != nil && d != nil, "Cancellation steps missing")
    check(a!.lowerBound < b!.lowerBound && b!.lowerBound < c!.lowerBound &&
          c!.lowerBound < d!.lowerBound, "Cancellation precedes durable terminal state")
    check(cancel.contains("if !processing.contains(id) && conversions[id] == nil"),
          "Cancellation must preserve decoder-owned stage")
    check(finish.contains("if !FileManager.default.fileExists(atPath: destination.path)"),
          "Duplicate completion must not overwrite staged bytes")
    check(finish.contains("guard self.tickets[id]?.status == .queued else"),
          "Late completion must reject cancelled ticket")
    check(finish.contains("if !self.processing.contains(id) && self.conversions[id] == nil"),
          "Late completion must preserve decoder-owned stage")
    check(error.contains("guard self.tickets[id]?.status == .queued else { return }"),
          "Late URLSession errors must not revive cancelled tickets")
    
    
} else {
    print("UNVERIFIED: production downloader source contract skipped (--fixture-only)")
}

let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("mp3-shelf-ownership-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let stage = root.appendingPathComponent("stage.mp3")
let first = Data([0x49, 0x44, 0x33, 0x04, 0x11, 0x22])
let second = Data([0x49, 0x44, 0x33, 0x04, 0x33, 0x44])
try first.write(to: stage)
func cleanup(processing: Bool, converting: Bool) throws {
    if !processing && !converting { try fm.removeItem(at: stage) }
}
try cleanup(processing: false, converting: true)
check(try Data(contentsOf: stage) == first, "Cancelled decoder lost staged bytes")
let duplicate = root.appendingPathComponent("duplicate.tmp")
try second.write(to: duplicate)
if !fm.fileExists(atPath: stage.path) { try fm.moveItem(at: duplicate, to: stage) }
check(try Data(contentsOf: stage) == first, "Duplicate callback replaced staged bytes")
try cleanup(processing: true, converting: false)
check(try Data(contentsOf: stage) == first, "Processing ownership ignored")
try cleanup(processing: false, converting: false)
check(!fm.fileExists(atPath: stage.path), "Unowned cancelled stage leaked")
check(try Data(contentsOf: duplicate) == second, "Duplicate temporary bytes altered")
print("PASS: cancellation ordering and staged-file ownership")

// Crash/relaunch model: a failed terminal-manifest write must leave the queued
// ticket and staged media intact. A successful retry must publish terminal
// state before cancellation/late delegate callbacks may clean up the stage.
// The model deliberately injects the persistence failure; the source contract
// above checks the corresponding production ordering.
enum FixtureStatus: String, Codable { case queued, cancelled }
struct FixtureTicket: Codable, Equatable {
    var status: FixtureStatus
    var reason: String?
}
enum FixtureWriteFailure: Error { case injected }
let manifest = root.appendingPathComponent("tickets.json")
let retainedStage = root.appendingPathComponent("retained-stage.mp3")
try first.write(to: retainedStage)
var inMemory = FixtureTicket(status: .queued, reason: nil)
try JSONEncoder().encode(inMemory).write(to: manifest, options: .atomic)

func cancelWithInjectedWriteFailure(_ fail: Bool) throws {
    guard inMemory.status == .queued else { return }
    let proposed = FixtureTicket(status: .cancelled, reason: "Cancelled")
    if fail { throw FixtureWriteFailure.injected }
    try JSONEncoder().encode(proposed).write(to: manifest, options: .atomic)
    inMemory = proposed
    if fm.fileExists(atPath: retainedStage.path) {
        try fm.removeItem(at: retainedStage)
    }
}
do {
    try cancelWithInjectedWriteFailure(true)
    fatalError("Injected manifest write failure unexpectedly succeeded")
} catch FixtureWriteFailure.injected {}
check(inMemory.status == .queued, "Failed manifest write published cancellation in memory")
check(try JSONDecoder().decode(FixtureTicket.self, from: Data(contentsOf: manifest)).status == .queued,
      "Failed manifest write changed durable ticket")
check(try Data(contentsOf: retainedStage) == first,
      "Failed manifest write deleted recoverable media")

// A process restart sees the same queued ticket and audio, so the transfer
// remains eligible for recovery instead of becoming an unrecoverable phantom.
inMemory = try JSONDecoder().decode(FixtureTicket.self, from: Data(contentsOf: manifest))
check(inMemory.status == .queued, "Restart lost recoverable queue state")
try cancelWithInjectedWriteFailure(false)
check(inMemory.status == .cancelled, "Successful cancellation was not published")
check(try JSONDecoder().decode(FixtureTicket.self, from: Data(contentsOf: manifest)).status == .cancelled,
      "Successful cancellation was not durable")
check(!fm.fileExists(atPath: retainedStage.path), "Terminal unowned stage was not removed")

// A late duplicate completion must not resurrect a cancelled ticket. Model
// the delegate's queued-state gate, including a fresh temporary URLSession file.
let lateLocation = root.appendingPathComponent("late-download.tmp")
try second.write(to: lateLocation)
if inMemory.status == .queued && !fm.fileExists(atPath: retainedStage.path) {
    try fm.moveItem(at: lateLocation, to: retainedStage)
}
check(!fm.fileExists(atPath: retainedStage.path), "Late completion resurrected cancelled audio")
check(try Data(contentsOf: lateLocation) == second,
      "Rejected late completion modified the temporary payload")
check(inMemory.status == .cancelled, "Late callback changed terminal ticket")
print("PASS: failed manifest write survives relaunch; durable cancellation rejects late completion")



// Multi-ticket recovery isolation: cancellation of one transfer must never
// erase a second queued ticket or its independently owned staging bytes.
// Persist the complete manifest on each transition, then simulate a restart
// by discarding the in-memory map and decoding the on-disk journal.
struct JournalEntry: Codable, Equatable {
    let id: UUID
    var status: FixtureStatus
}
let cancelledID = UUID()
let survivingID = UUID()
let journal = root.appendingPathComponent("multi-ticket-journal.json")
let cancelledStage = root.appendingPathComponent(cancelledID.uuidString + ".mp3")
let survivingStage = root.appendingPathComponent(survivingID.uuidString + ".mp3")
try first.write(to: cancelledStage)
try second.write(to: survivingStage)
var journalEntries = [
    JournalEntry(id: cancelledID, status: .queued),
    JournalEntry(id: survivingID, status: .queued)
]
func persistJournal(_ entries: [JournalEntry], fail: Bool = false) throws {
    if fail { throw FixtureWriteFailure.injected }
    try JSONEncoder().encode(entries).write(to: journal, options: .atomic)
}
func reloadJournal() throws -> [JournalEntry] {
    try JSONDecoder().decode([JournalEntry].self, from: Data(contentsOf: journal))
}
try persistJournal(journalEntries)
var proposedEntries = journalEntries
proposedEntries[0].status = .cancelled
do {
    try persistJournal(proposedEntries, fail: true)
    fatalError("Multi-ticket manifest failure was not injected")
} catch FixtureWriteFailure.injected {}
check(try reloadJournal() == journalEntries, "Failed write corrupted a different queued ticket")
check(try Data(contentsOf: cancelledStage) == first, "Failed write lost cancelled ticket media")
check(try Data(contentsOf: survivingStage) == second, "Failed write lost unrelated queued media")

// A retry commits the full journal first, then releases only the terminal
// ticket's unowned stage. The unrelated ticket must remain resumable.
try persistJournal(proposedEntries)
journalEntries = try reloadJournal()
check(journalEntries[0].status == .cancelled, "Terminal state missing after restart")
check(journalEntries[1].status == .queued, "Unrelated queued ticket was cancelled")
try fm.removeItem(at: cancelledStage)
check(!fm.fileExists(atPath: cancelledStage.path), "Cancelled stage survived terminal cleanup")
check(try Data(contentsOf: survivingStage) == second, "Cancellation removed another ticket's stage")

// Late duplicate callbacks may target the cancelled ID while the other
// transfer remains queued. A rejected callback must not mutate the journal,
// overwrite the surviving stage or consume its bytes.
let lateCancelled = root.appendingPathComponent("late-cancelled.tmp")
try first.write(to: lateCancelled)
let beforeLateCallback = try Data(contentsOf: journal)
let cancelledIsQueued = journalEntries.first { $0.id == cancelledID }?.status == .queued
if cancelledIsQueued && !fm.fileExists(atPath: cancelledStage.path) {
    try fm.moveItem(at: lateCancelled, to: cancelledStage)
}
check(!fm.fileExists(atPath: cancelledStage.path), "Late callback restored cancelled transfer")
check(try Data(contentsOf: survivingStage) == second, "Late callback modified another transfer")
check(try Data(contentsOf: journal) == beforeLateCallback, "Late callback changed durable queue")

// The remaining queued transfer can still complete normally. A duplicate
// completion for the same ID must not replace its already staged bytes.
let duplicateSurvivor = root.appendingPathComponent("duplicate-survivor.tmp")
try first.write(to: duplicateSurvivor)
if !fm.fileExists(atPath: survivingStage.path) {
    try fm.moveItem(at: duplicateSurvivor, to: survivingStage)
}
check(try Data(contentsOf: survivingStage) == second, "Duplicate overwrote queued stage")
check(try Data(contentsOf: duplicateSurvivor) == first, "Duplicate source was unexpectedly moved")
print("PASS: two-ticket journal isolation, failed persistence, restart and duplicate completion")
