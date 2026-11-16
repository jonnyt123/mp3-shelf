import Foundation
// Run: swift ios/Tests/PhysicalDeviceCallbackCorrelationStrictTests.swift
// Standalone Foundation evidence model; never physical-device acceptance proof.
struct CallbackEvent: Codable {
    let kind: String
    let session: String
    let process: String
    let task: String?
    let time: Int
    let source: String
}
enum CallbackVerdict: Equatable { case verified, missingWake, missingCompletion, missingStage, invalidEvidence }
func assessCallbacks(_ events: [CallbackEvent], session: String, installedCommit: String) -> CallbackVerdict {
    guard installedCommit.count == 40, installedCommit.allSatisfy({ $0.isHexDigit }),
          !session.isEmpty else { return .invalidEvidence }
    let scoped = events.filter { $0.session == session }
    guard scoped.allSatisfy({ $0.time > 0 && !$0.process.isEmpty && $0.source == "production" }) else {
        return .invalidEvidence
    }
    let wakes = scoped.filter { $0.kind == "osBackgroundWake" && $0.task != nil }
    guard !wakes.isEmpty else { return .missingWake }
    let completions = scoped.filter { $0.kind == "urlSessionCompletion" && $0.task != nil }
    guard !completions.isEmpty else { return .missingCompletion }
    let stages = scoped.filter { $0.kind == "durableStaging" && $0.task != nil }
    guard !stages.isEmpty else { return .missingStage }
    for wake in wakes {
        guard let task = wake.task else { continue }
        for completion in completions where completion.process == wake.process &&
            completion.task == task && completion.time >= wake.time {
            if stages.contains(where: { $0.process == wake.process &&
                $0.task == task && $0.time >= completion.time }) {
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
let good = [event("osBackgroundWake"), event("urlSessionCompletion", time: 20),
            event("durableStaging", time: 30)]
expectCallback(good, .verified, "ordered same-process task")
expectCallback(Array(good.dropFirst()), .missingWake, "missing OS wake")
expectCallback([good[0], good[2]], .missingCompletion, "missing completion")
expectCallback(Array(good.prefix(2)), .missingStage, "missing durable stage")
expectCallback([good[0], event("urlSessionCompletion", "p2", time: 20), good[2]], .invalidEvidence, "cross-process completion")
expectCallback([good[0], event("urlSessionCompletion", task: "t2", time: 20), good[2]], .invalidEvidence, "cross-task completion")
expectCallback([good[0], good[1], event("durableStaging", "p2", time: 30)], .invalidEvidence, "cross-process stage")
expectCallback([good[0], good[1], event("durableStaging", task: "t2", time: 30)], .invalidEvidence, "cross-task stage")
expectCallback([good[0], event("urlSessionCompletion", time: 9), good[2]], .invalidEvidence, "old completion")
expectCallback([good[0], good[1], event("durableStaging", time: 19)], .invalidEvidence, "old stage")
expectCallback([good[0], event("urlSessionCompletion", time: 20, session: "old"), good[2]], .missingCompletion, "old session")
expectCallback([good[0], event("urlSessionCompletion", time: 20, source: "mock"), good[2]], .invalidEvidence, "mock callback")
expectCallback(good, .invalidEvidence, "unverified SHA", sha: "stale")
expectCallback(good, .missingWake, "wrong session", session: "s2")
print("PASS: 14 strict telemetry correlation fixtures; no device proof inferred")
