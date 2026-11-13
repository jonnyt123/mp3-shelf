import Foundation

// Run from repo root: swift ios/Tests/BackgroundCancellationOwnershipTests.swift
// Source contract plus deterministic Foundation file fixture, not real URLSession/iPhone QA.
let source = try String(contentsOfFile: "ios/MP3Shelf/Services/BackgroundAudioDownloader.swift", encoding: .utf8)
func slice(_ start: String, _ end: String) -> String {
    guard let a = source.range(of: start),
          let b = source.range(of: end, range: a.upperBound..<source.endIndex) else {
        fatalError("Missing native callback contract: \(start)")
    }
    return String(source[a.lowerBound..<b.lowerBound])
}
func check(_ ok: Bool, _ why: String) {
    guard ok else { fatalError(why) }
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

