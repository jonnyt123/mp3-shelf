import Foundation
// Run: swift ios/Tests/PhysicalDeviceCallbackCorrelationStrictTests.swift
// Independent evidence-policy regression fixture; never hardware acceptance proof.
struct CallbackEvent: Codable {
    let kind: String
    let session: String
    let process: String
    let task: String?
    let time: Int
    let source: String
}
enum CallbackVerdict: Equatable { case verified, missingArm, missingWake, missingCompletion, missingStage, invalidEvidence }
func assessCallbacks(_ events: [CallbackEvent], session: String, installedCommit: String) -> CallbackVerdict {
    guard installedCommit.count == 40, installedCommit.allSatisfy({ $0.isHexDigit }),
          !session.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .invalidEvidence }
    let scoped = events.filter { $0.session == session }
    guard scoped.allSatisfy({ $0.time > 0 && !$0.process.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        $0.source == "production" &&
        ($0.task == nil || !$0.task!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }) else {
        return .invalidEvidence
    }
    let knownKinds: Set<String> = ["auditArmed", "osBackgroundWake", "urlSessionCompletion", "durableStaging"]
    guard scoped.allSatisfy({ knownKinds.contains($0.kind) &&
        (($0.kind == "auditArmed") == ($0.task == nil)) }) else { return .invalidEvidence }
    let arms = scoped.filter { $0.kind == "auditArmed" && $0.task == nil }
    guard !arms.isEmpty else { return .missingArm }
    let wakes = scoped.filter { $0.kind == "osBackgroundWake" && $0.task != nil }
    guard !wakes.isEmpty else { return .missingWake }
    let completions = scoped.filter { $0.kind == "urlSessionCompletion" && $0.task != nil }
    guard !completions.isEmpty else { return .missingCompletion }
    let stages = scoped.filter { $0.kind == "durableStaging" && $0.task != nil }
    guard !stages.isEmpty else { return .missingStage }
    for wake in wakes {
        guard arms.contains(where: { $0.process != wake.process && $0.time < wake.time }) else { continue }
        guard let task = wake.task else { continue }
        for completion in completions where completion.process == wake.process &&
            completion.task == task && completion.time > wake.time {
            if stages.contains(where: { $0.process == wake.process &&
                $0.task == task && $0.time > completion.time }) {
                return .verified
            }
        }
    }
    return .invalidEvidence
}
func event(_ kind: String, _ process: String = "p1", task: String = "t1",
           time: Int = 10, session: String = "s1", source: String = "production") -> CallbackEvent {
    CallbackEvent(kind: kind, session: session, process: process, task: task, time: time, source: source)
}
func expectCallback(_ events: [CallbackEvent], _ verdict: CallbackVerdict, _ label: String,
                    session: String = "s1", sha: String = String(repeating: "a", count: 40)) {
    let actual = assessCallbacks(events, session: session, installedCommit: sha)
    precondition(actual == verdict, "\(label): expected \(verdict), got \(actual)")
}
let arm = CallbackEvent(kind: "auditArmed", session: "s1", process: "original-process", task: nil, time: 5, source: "production")
let good = [event("osBackgroundWake"), event("urlSessionCompletion", time: 20),
            event("durableStaging", time: 30)]
expectCallback([arm] + good, .verified, "ordered cross-process arm/wake/completion/stage")
expectCallback(good, .missingArm, "unarmed callbacks cannot prove restart")
expectCallback([CallbackEvent(kind: "auditArmed", session: "s1", process: "p1", task: nil, time: 5, source: "production")] + good, .invalidEvidence, "valid same-process arm cannot prove restart")
expectCallback([CallbackEvent(kind: "auditArmed", session: "s1", process: "original-process", task: nil, time: 10, source: "production")] + good, .invalidEvidence, "valid arm at wake timestamp cannot prove restart")
// Exercise structurally valid audit arms: malformed task-bearing arms are tested separately.
// A valid arm in the callback process, or one recorded after the wake, must never
// be accepted as evidence of a cross-process offline relaunch.
let sameProcessArm = CallbackEvent(kind: "auditArmed", session: "s1", process: "p1", task: nil, time: 5, source: "production")
let lateArm = CallbackEvent(kind: "auditArmed", session: "s1", process: "previous", task: nil, time: 11, source: "production")
expectCallback([sameProcessArm] + good, .invalidEvidence, "same-process valid arm is not a restart")
expectCallback([lateArm] + good, .invalidEvidence, "late valid arm is not a restart")
expectCallback([arm, sameProcessArm] + good, .verified, "valid independent arm remains sufficient despite same-process arm")
expectCallback([arm, lateArm] + good, .verified, "later unrelated arm does not invalidate earlier correlated arm")
expectCallback([arm] + [event("osBackgroundWake", "p2", task: "t2"), good[1], good[2]], .invalidEvidence, "different-process wake cannot borrow callback chain")
expectCallback([arm] + [event("osBackgroundWake", task: "t2"), good[1], good[2]], .invalidEvidence, "different-task wake cannot borrow callback chain")
expectCallback([arm] + Array(good.dropFirst()), .missingWake, "missing OS wake")
expectCallback([arm] + [good[0], good[2]], .missingCompletion, "missing completion")
expectCallback([arm] + Array(good.prefix(2)), .missingStage, "missing durable stage")
expectCallback([arm] + [good[0], event("urlSessionCompletion", "p2", time: 20), good[2]], .invalidEvidence, "cross-process completion")
expectCallback([arm] + [good[0], event("urlSessionCompletion", task: "t2", time: 20), good[2]], .invalidEvidence, "cross-task completion")
expectCallback([arm] + [good[0], good[1], event("durableStaging", "p2", time: 30)], .invalidEvidence, "cross-process stage")
expectCallback([arm] + [good[0], good[1], event("durableStaging", task: "t2", time: 30)], .invalidEvidence, "cross-task stage")
expectCallback([arm] + [good[0], event("urlSessionCompletion", time: 9), good[2]], .invalidEvidence, "old completion")
expectCallback([arm] + [good[0], good[1], event("durableStaging", time: 19)], .invalidEvidence, "old stage")
expectCallback([arm] + [good[0], event("urlSessionCompletion", time: 20, session: "old"), good[2]], .missingCompletion, "old session")
expectCallback([arm] + [good[0], event("urlSessionCompletion", time: 20, source: "mock"), good[2]], .invalidEvidence, "mock callback")
expectCallback([arm] + good, .invalidEvidence, "unverified SHA", sha: "stale")
expectCallback([arm] + good + [event("unexpectedCallback", time: 40)], .invalidEvidence, "unknown event kind")
expectCallback([arm] + good + [CallbackEvent(kind: "durableStaging", session: "s1", process: "p1", task: nil, time: 40, source: "production")], .invalidEvidence, "staging missing task")
expectCallback([arm] + good + [CallbackEvent(kind: "auditArmed", session: "s1", process: "p2", task: "t2", time: 6, source: "production")], .invalidEvidence, "malformed arm")
expectCallback([arm] + good, .missingArm, "wrong session", session: "s2")
// Equal timestamps cannot establish event order; blank identities cannot correlate.
expectCallback([arm] + [good[0], event("urlSessionCompletion", time: 10), good[2]], .invalidEvidence, "simultaneous wake/callback")
expectCallback([arm] + [good[0], good[1], event("durableStaging", time: 20)], .invalidEvidence, "simultaneous callback/stage")
expectCallback([arm] + [event("osBackgroundWake", task: ""), event("urlSessionCompletion", task: "", time: 20), event("durableStaging", task: "", time: 30)], .invalidEvidence, "empty task")
expectCallback([arm] + [event("osBackgroundWake", task: "  "), event("urlSessionCompletion", task: "  ", time: 20), event("durableStaging", task: "  ", time: 30)], .invalidEvidence, "whitespace task")
expectCallback([arm] + [event("osBackgroundWake", " "), event("urlSessionCompletion", " ", time: 20), event("durableStaging", " ", time: 30)], .invalidEvidence, "whitespace process")
expectCallback([arm] + good, .invalidEvidence, "whitespace session", session: " ")
let wrongTask = [good[0], event("urlSessionCompletion", task: "t2", time: 20), good[2]]
for index in 0..<128 {
    let noise = event(index.isMultiple(of: 2) ? "urlSessionCompletion" : "durableStaging",
                      "noise-\(index)", task: "noise-\(index)", time: 40 + index, session: "old")
    expectCallback([arm] + good + [noise], .verified, "unrelated session noise \(index)")
    expectCallback([arm] + wrongTask + [noise], .invalidEvidence, "noise cannot repair task mismatch \(index)")
}
// Audit evidence is transported as JSON. Verify that the policy evaluates decoded
// records, rejects malformed payloads, and never joins independent process/task
// streams even when their timestamps and event kinds are identical.
let encoder = JSONEncoder()
let decoder = JSONDecoder()
let encodedEvidence = try encoder.encode([arm] + good)
let decodedEvidence = try decoder.decode([CallbackEvent].self, from: encodedEvidence)
expectCallback(decodedEvidence, .verified, "serialized production evidence round-trip")
for malformed in [
    Data("{}".utf8),
    Data("[{\\"kind\\":\\"auditArmed\\"}]".utf8),
    Data("[null]".utf8),
    Data("[{\\"kind\\":1}]".utf8)
] {
    do {
        _ = try decoder.decode([CallbackEvent].self, from: malformed)
        preconditionFailure("malformed audit JSON was decoded as valid evidence")
    } catch is DecodingError {
        // Expected: incomplete or incorrectly typed evidence is not admissible.
    }
}
for index in 0..<128 {
    let task = "foreign-task-\\(index)"
    let process = "foreign-process-\\(index)"
    let foreign = [
        event("osBackgroundWake", process, task: task, time: 11),
        event("urlSessionCompletion", process, task: task, time: 21),
        event("durableStaging", process, task: task, time: 31)
    ]
    expectCallback([arm] + good + foreign, .verified,
                   "unrelated complete callback chain cannot break valid evidence \\(index)")
    let incomplete = [good[0], event("urlSessionCompletion", task: task, time: 20), good[2]]
    expectCallback([arm] + incomplete + foreign, .invalidEvidence,
                   "foreign complete chain cannot repair missing matching callback \\(index)")
}
print("PASS: strict callback correlation, JSON transport, malformed payload and 512 noise assertions; fixture only")
