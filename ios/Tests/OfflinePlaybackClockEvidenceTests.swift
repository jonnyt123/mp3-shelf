import Foundation

// Standalone acceptance-policy fixture, not evidence from a physical iPhone.
// Run: swift ios/Tests/OfflinePlaybackClockEvidenceTests.swift
struct Sample {
    let process: String
    let session: String
    let timestamp: Int
    let positionMs: Int?
    let networkSatisfied: Bool?
}
func provesOfflinePlayback(_ samples: [Sample], restartProcess: String, session: String, offlineAt: Int) -> Bool {
    guard !restartProcess.isEmpty, !session.isEmpty else { return false }
    let valid = samples.filter {
        $0.process == restartProcess && $0.session == session &&
        $0.timestamp > offlineAt && $0.networkSatisfied == false &&
        ($0.positionMs ?? -1) >= 0
    }.sorted { $0.timestamp < $1.timestamp }
    // A playing flag or decoded file is insufficient: require clock advancement
    // after relaunch, in one session/process, while NWPath is unsatisfied.
    for first in valid.indices {
        for second in valid.indices where second > first {
            if valid[second].timestamp > valid[first].timestamp &&
                valid[second].positionMs! > valid[first].positionMs! { return true }
        }
    }
    return false
}
func sample(_ t: Int, _ pos: Int?, _ offline: Bool? = false,
            _ process: String = "relaunch", _ session: String = "audit") -> Sample {
    Sample(process: process, session: session, timestamp: t,
           positionMs: pos, networkSatisfied: offline)
}
func check(_ condition: Bool, _ label: String) {
    precondition(condition, "FAIL: \(label)")
}
let good = [sample(110, 1000), sample(120, 1700)]
check(provesOfflinePlayback(good, restartProcess: "relaunch", session: "audit", offlineAt: 100), "advancing offline clock")
let invalid: [(String, [Sample])] = [
    ("single sample", [good[0]]),
    ("stalled clock", [sample(110, 1000), sample(120, 1000)]),
    ("reversed clock", [sample(110, 1700), sample(120, 1000)]),
    ("unknown network", [sample(110, 1000, nil), sample(120, 1700, nil)]),
    ("online samples", [sample(110, 1000, true), sample(120, 1700, true)]),
    ("before offline", [sample(90, 1000), sample(95, 1700)]),
    ("different process", [sample(110, 1000, false, "prior"), sample(120, 1700, false, "prior")]),
    ("different session", [sample(110, 1000, false, "relaunch", "old"), sample(120, 1700, false, "relaunch", "old")]),
    ("mixed process", [sample(110, 1000), sample(120, 1700, false, "prior")]),
    ("mixed session", [sample(110, 1000), sample(120, 1700, false, "relaunch", "old")]),
    ("missing clock", [sample(110, nil), sample(120, nil)]),
    ("negative clock", [sample(110, -1), sample(120, 1700)]),
    ("same timestamp", [sample(110, 1000), sample(110, 1700)])
]
for (label, values) in invalid {
    check(!provesOfflinePlayback(values, restartProcess: "relaunch", session: "audit", offlineAt: 100), label)
}
for i in 0..<1000 {
    let noise = sample(110 + i, 999999, false, "other", "old")
    check(provesOfflinePlayback(good + [noise], restartProcess: "relaunch", session: "audit", offlineAt: 100), "noise preserved valid \(i)")
    check(!provesOfflinePlayback(invalid[8].1 + [noise], restartProcess: "relaunch", session: "audit", offlineAt: 100), "noise repaired mixed process \(i)")
}
print("PASS: offline playback clock proof, \(invalid.count) negative scenarios, 2000 noise assertions")
