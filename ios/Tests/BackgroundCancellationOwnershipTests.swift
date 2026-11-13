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
