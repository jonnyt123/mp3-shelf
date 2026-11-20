import Foundation

// Run: swift ios/Tests/BackgroundCallbackEvidenceCorrelationTests.swift
// Independent evidence model, NOT production URLSession or physical-device proof.
struct CallbackEvent: Codable {
    let session: String
    let process: String
    let task: String
    let kind: String
    let timestamp: Int
    let fileDigest: String?
}
enum EvidenceError: Error { case invalid, ambiguous, incomplete }
// A callback chain must be from one bounded foreground/background observation,
// not three independently replayed events collected days apart.
let maximumCallbackWindowSeconds = 30 * 60

func correlate(_ events: [CallbackEvent], session: String, process: String, task: String, digest: String) throws -> [CallbackEvent] {
    guard !session.isEmpty, !process.isEmpty, !task.isEmpty,
          digest.count == 64,
          digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
        throw EvidenceError.invalid
    }
    let matching = events.filter { $0.session == session && $0.process == process && $0.task == task }
    guard matching.count == 3 else { throw EvidenceError.incomplete }
    let sorted = matching.sorted { $0.timestamp < $1.timestamp }
    guard sorted.map(\.kind) == ["backgroundWake", "downloadCompleted", "recordingStaged"],
          sorted[0].timestamp >= 0,
          sorted[0].timestamp < sorted[1].timestamp,
          sorted[1].timestamp < sorted[2].timestamp,
          sorted[2].timestamp - sorted[0].timestamp <= maximumCallbackWindowSeconds,
          sorted[2].fileDigest == digest,
          sorted[0].fileDigest == nil,
          sorted[1].fileDigest == nil else { throw EvidenceError.ambiguous }
    return sorted
}
func expectRejected(_ label: String, _ events: [CallbackEvent], session: String = "S", process: String = "P", task: String = "T", digest: String = String(repeating: "a", count: 64)) throws {
    do {
        _ = try correlate(events, session: session, process: process, task: task, digest: digest)
        throw NSError(domain: "QA", code: 1, userInfo: [NSLocalizedDescriptionKey: "accepted \(label)"])
    } catch EvidenceError.invalid {} catch EvidenceError.ambiguous {} catch EvidenceError.incomplete {}
}
let digest = String(repeating: "a", count: 64)
func event(_ kind: String, _ time: Int, session: String = "S", process: String = "P", task: String = "T", hash: String? = nil) -> CallbackEvent {
    CallbackEvent(session: session, process: process, task: task, kind: kind, timestamp: time, fileDigest: hash)
}
let good = [event("backgroundWake", 100), event("downloadCompleted", 110), event("recordingStaged", 120, hash: digest)]
let extras = [event("recordingStaged", 10, process: "old", hash: digest), event("downloadCompleted", 11, task: "other"), event("backgroundWake", 12, session: "other")]
let shuffled = [good[2], extras[0], good[0], extras[2], good[1], extras[1]]
let result = try correlate(shuffled, session: "S", process: "P", task: "T", digest: digest)
precondition(result.map(\.timestamp) == [100, 110, 120])
let negative: [(String, [CallbackEvent])] = [
    ("missing wake", Array(good.dropFirst())),
    ("missing stage", Array(good.dropLast())),
    ("old process wake", [event("backgroundWake", 100, process: "old"), good[1], good[2]]),
    ("different task stage", [good[0], good[1], event("recordingStaged", 120, task: "other", hash: digest)]),
    ("different session completion", [good[0], event("downloadCompleted", 110, session: "other"), good[2]]),
    ("stage before callback", [good[0], event("recordingStaged", 105, hash: digest), good[1]]),
    ("same timestamp", [good[0], event("downloadCompleted", 100), good[2]]),
    ("negative clock", [event("backgroundWake", -1), good[1], good[2]]),
    ("stale wake", [event("backgroundWake", 100), event("downloadCompleted", 2000), event("recordingStaged", 2010, hash: digest)]),
    ("stale completion", [good[0], good[1], event("recordingStaged", 2000, hash: digest)]),
    ("window boundary exceeded", [event("backgroundWake", 1), event("downloadCompleted", 2), event("recordingStaged", 1802, hash: digest)]),
    ("duplicate completion", good + [good[1]]),
    ("duplicate stage", good + [good[2]]),
    ("foreign digest", [good[0], good[1], event("recordingStaged", 120, hash: String(repeating: "b", count: 64))]),
    ("digest on wake", [event("backgroundWake", 100, hash: digest), good[1], good[2]]),
    ("digest on completion", [good[0], event("downloadCompleted", 110, hash: digest), good[2]]),
    ("extra matching event", good + [event("progress", 115)]),
    ("replayed prior launch", good.map { event($0.kind, $0.timestamp, process: "previous", hash: $0.fileDigest) })
]
for (name, scenario) in negative { try expectRejected(name, scenario) }
try expectRejected("bad digest syntax", good, digest: String(repeating: "Z", count: 64))
try expectRejected("empty task", good, task: "")
let boundary = [event("backgroundWake", 1), event("downloadCompleted", 2), event("recordingStaged", 1801, hash: digest)]
precondition(try correlate(boundary, session: "S", process: "P", task: "T", digest: digest).count == 3)
let root = FileManager.default.temporaryDirectory.appendingPathComponent("callback-qa-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
let log = root.appendingPathComponent("events.json")
try JSONEncoder().encode(shuffled).write(to: log, options: .atomic)
let reloaded = try JSONDecoder().decode([CallbackEvent].self, from: Data(contentsOf: log))
let replayed = try correlate(reloaded, session: "S", process: "P", task: "T", digest: digest)
precondition(replayed.count == 3)
try Data("{invalid".utf8).write(to: log, options: .atomic)
do {
    _ = try JSONDecoder().decode([CallbackEvent].self, from: Data(contentsOf: log))
    fatalError("corrupt evidence accepted")
} catch is DecodingError { }
print("PASS: callback evidence correlation (1 positive, \(negative.count + 2) negative, persistence/corruption)")
