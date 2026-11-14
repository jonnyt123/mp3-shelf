import Foundation

// Run from a checkout containing the native downloader:
// swift ios/Tests/BackgroundRetryPublicationOrderTests.swift
// Standalone filesystem fault injection (no production claims):
// swift ios/Tests/BackgroundRetryPublicationOrderTests.swift --fixture-only
//
// A replacement transfer must be committed with its predecessor's retirement
// before the replacement URLSession task starts. Failed commits must leave
// the old transfer and staged recordings recoverable.
struct RetryTicket: Codable, Equatable {
    let id: UUID
    var status: String
}
enum RetryFailure: Error { case injected, corrupt }
func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
}
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("mp3-retry-order-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let journal = root.appendingPathComponent("tickets.json")
let stage = root.appendingPathComponent("old.mp3")
let unrelated = root.appendingPathComponent("other.mp3")
let audio = Data((0..<32768).map { UInt8($0 % 251) })
let otherAudio = Data((0..<32768).map { UInt8(($0 + 17) % 251) })
try audio.write(to: stage)
try otherAudio.write(to: unrelated)
let old = RetryTicket(id: UUID(), status: "queued")
let other = RetryTicket(id: UUID(), status: "queued")
let replacement = RetryTicket(id: UUID(), status: "queued")
try JSONEncoder().encode([old, other]).write(to: journal, options: .atomic)
var live = [old, other]
var scheduled = [UUID]()
func commitAndSchedule(_ proposed: [RetryTicket], fail: Bool) throws {
    // Do not trust a corrupt journal as an empty queue.
    let durable = try JSONDecoder().decode([RetryTicket].self, from: Data(contentsOf: journal))
    guard Set(durable.map(\.id)).count == durable.count else { throw RetryFailure.corrupt }
    if fail { throw RetryFailure.injected }
    try JSONEncoder().encode(proposed).write(to: journal, options: .atomic)
    live = proposed
    scheduled.append(replacement.id)
}
let next = [RetryTicket(id: old.id, status: "cancelled"), other, replacement]
for _ in 0..<32 {
    do {
        try commitAndSchedule(next, fail: true)
        try check(false, "injected journal failure was acknowledged")
    } catch RetryFailure.injected {}
    try check(scheduled.isEmpty, "replacement task started before durable commit")
    try check(live == [old, other], "failed commit mutated in-memory tickets")
    try check(JSONDecoder().decode([RetryTicket].self, from: Data(contentsOf: journal)) == [old, other],
              "failed commit retired original durable ticket")
    try check(Data(contentsOf: stage) == audio && Data(contentsOf: unrelated) == otherAudio,
              "failed retry destroyed staged or unrelated audio")
}
try commitAndSchedule(next, fail: false)
try check(scheduled == [replacement.id], "successful retry scheduled more than one replacement")
try check(JSONDecoder().decode([RetryTicket].self, from: Data(contentsOf: journal)) == next,
          "relaunch cannot recover old retirement and replacement atomically")
try check(Data(contentsOf: stage) == audio && Data(contentsOf: unrelated) == otherAudio,
          "successful retry prematurely removed audio")
print("PASS: 32 failed retry publications, atomic retirement/replacement, staged audio isolation")
// A corrupted durable queue must never be treated as an empty queue during a retry.
// Preserve the exact corrupt bytes for diagnosis and allow a later valid recovery.
let validJournal = try Data(contentsOf: journal)
let corruptCases: [Data] = [
    Data("{".utf8),
    Data("null".utf8),
    Data("[{\"id\":\"not-a-uuid\",\"status\":\"queued\"}]".utf8),
    try JSONEncoder().encode([old, old])
]
for (index, corrupt) in corruptCases.enumerated() {
    try corrupt.write(to: journal, options: .atomic)
    let scheduledBefore = scheduled
    let liveBefore = live
    do {
        try commitAndSchedule(next, fail: false)
        try check(false, "corrupt journal accepted on case \\(index)")
    } catch RetryFailure.corrupt {
        // Duplicate identifiers are structurally valid JSON but unsafe for recovery.
    } catch is DecodingError {
        // Malformed JSON and invalid ticket identifiers must fail closed.
    }
    try check(Data(contentsOf: journal) == corrupt, "corrupt evidence overwritten on case \\(index)")
    try check(scheduled == scheduledBefore, "corrupt journal scheduled a transfer on case \\(index)")
    try check(live == liveBefore, "corrupt journal changed live tickets on case \\(index)")
    try check(Data(contentsOf: stage) == audio && Data(contentsOf: unrelated) == otherAudio,
              "corrupt journal destroyed audio on case \\(index)")
}
// Simulate a second process publishing a newer queue snapshot while the retry
// is preparing its replacement. A stale writer must not erase that snapshot.
let concurrent = RetryTicket(id: UUID(), status: "queued")
let concurrentJournal = try JSONEncoder().encode([old, other, concurrent])
try concurrentJournal.write(to: journal, options: .atomic)
let scheduledAtConflict = scheduled
let liveAtConflict = live
func commitIfUnchanged(_ proposed: [RetryTicket], expected: Data) throws {
    let observed = try Data(contentsOf: journal)
    guard observed == expected else { throw RetryFailure.corrupt }
    try commitAndSchedule(proposed, fail: false)
}
do {
    try commitIfUnchanged(next, expected: validJournal)
    try check(false, "stale retry overwrote concurrent durable queue")
} catch RetryFailure.corrupt {}
try check(Data(contentsOf: journal) == concurrentJournal,
          "stale retry destroyed a newer durable queue snapshot")
try check(scheduled == scheduledAtConflict && live == liveAtConflict,
          "stale retry changed live queue or started another transfer")
try check(Data(contentsOf: stage) == audio && Data(contentsOf: unrelated) == otherAudio,
          "stale retry destroyed staged audio")
print("PASS: stale retry rejected without erasing concurrent journal or audio")

try validJournal.write(to: journal, options: .atomic)
try check(JSONDecoder().decode([RetryTicket].self, from: Data(contentsOf: journal)) == next,
          "valid recovery journal not restorable after corruption")
try check(scheduled == [replacement.id], "restored journal caused duplicate transfer scheduling")
print("PASS: four corrupt journal cases blocked, exact evidence and audio preserved, valid recovery restored")


if !CommandLine.arguments.contains("--fixture-only") {
    let sourcePath = "ios/MP3Shelf/Services/BackgroundAudioDownloader.swift"
    guard fm.fileExists(atPath: sourcePath) else {
        fputs("UNVERIFIED: native downloader source missing\n", stderr)
        exit(2)
    }
    let source = try String(contentsOfFile: sourcePath, encoding: .utf8)
    guard let start = source.range(of: "private func startTransfer("),
          let end = source.range(of: "private func noteQueueWriteFailure(", range: start.upperBound..<source.endIndex) else {
        fputs("FAIL: cannot locate downloader replacement implementation\n", stderr)
        exit(1)
    }
    let body = String(source[start.lowerBound..<end.lowerBound])
    guard let write = body.range(of: "try BackgroundTicketManifestPolicy.write("),
          let assign = body.range(of: "tickets = updated", range: write.upperBound..<body.endIndex),
          let schedule = body.range(of: "task.resume()", range: assign.upperBound..<body.endIndex),
          body.contains("updated[retired.id] = retired"),
          body.contains("updated[ticket.id] = ticket"),
          write.lowerBound < assign.lowerBound && assign.lowerBound < schedule.lowerBound else {
        fputs("FAIL: retry must durably retire predecessor and publish replacement before task.resume()\n", stderr)
        exit(1)
    }
    print("PASS: native startTransfer source publication-order contract (source inspection only)")
}
