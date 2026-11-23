import Foundation

// Standalone Foundation fixture: swift ios/Tests/BackgroundDeviceEvidenceCorrelationTests.swift
// A reference acceptance model, NOT proof that production URLSession callbacks occurred.
struct Event: Codable, Equatable {
    enum Kind: String, Codable { case armed, osWake, callback, staged, playback, offlinePath }
    let kind: Kind
    let process: String
    let session: String
    let task: String?
    let timestamp: Int
}
struct Correlation {
    let accepted: Bool
    let reason: String
}
func correlate(_ events: [Event]) -> Correlation {
    guard let arm = events.first(where: { $0.kind == .armed && !$0.process.isEmpty && !$0.session.isEmpty }) else {
        return .init(accepted: false, reason: "missing arm")
    }
    guard let wake = events.first(where: { $0.kind == .osWake && $0.session == arm.session &&
        $0.process != arm.process && !$0.process.isEmpty && $0.timestamp > arm.timestamp }) else {
        return .init(accepted: false, reason: "missing new-process OS wake")
    }
    let callbacks = events.filter { $0.kind == .callback && $0.session == arm.session &&
        $0.process == wake.process && $0.timestamp >= wake.timestamp &&
        $0.task != nil && !$0.task!.isEmpty }
    for callback in callbacks {
        guard let staged = events.first(where: { $0.kind == .staged &&
            $0.process == callback.process && $0.session == callback.session &&
            $0.task == callback.task && $0.timestamp >= callback.timestamp }) else { continue }
        guard let offline = events.first(where: { $0.kind == .offlinePath &&
            $0.session == arm.session && $0.process != staged.process &&
            $0.process != arm.process && $0.timestamp > staged.timestamp }) else { continue }
        guard events.contains(where: { $0.kind == .playback &&
            $0.session == arm.session && $0.process == offline.process &&
            $0.timestamp > offline.timestamp }) else { continue }
        return .init(accepted: true, reason: "correlated")
    }
    return .init(accepted: false, reason: "incomplete callback/staging/offline playback chain")
}
func require(_ condition: Bool, _ message: String) {
    if !condition { fatalError("FAIL: \(message)") }
}
func e(_ kind: Event.Kind, _ process: String, _ task: String? = nil, _ time: Int, _ session: String = "s1") -> Event {
    Event(kind: kind, process: process, session: session, task: task, timestamp: time)
}
let valid = [
    e(.armed, "p1", nil, 10), e(.osWake, "p2", nil, 20),
    e(.callback, "p2", "task-A", 30), e(.staged, "p2", "task-A", 40),
    e(.offlinePath, "p3", nil, 50), e(.playback, "p3", nil, 60)
]
require(correlate(valid).accepted, "genuine ordered evidence rejected")
let mutants: [(String, [Event])] = [
    ("no arm", Array(valid.dropFirst())),
    ("same-process wake", valid.enumerated().map { $0.offset == 1 ? e(.osWake, "p1", nil, 20) : $0.element }),
    ("stale wake", valid.enumerated().map { $0.offset == 1 ? e(.osWake, "p2", nil, 9) : $0.element }),
    ("wrong task", valid.enumerated().map { $0.offset == 3 ? e(.staged, "p2", "task-B", 40) : $0.element }),
    ("wrong callback process", valid.enumerated().map { $0.offset == 2 ? e(.callback, "p1", "task-A", 30) : $0.element }),
    ("wrong staged process", valid.enumerated().map { $0.offset == 3 ? e(.staged, "p4", "task-A", 40) : $0.element }),
    ("staging before callback", valid.enumerated().map { $0.offset == 3 ? e(.staged, "p2", "task-A", 29) : $0.element }),
    ("offline before staging", valid.enumerated().map { $0.offset == 4 ? e(.offlinePath, "p3", nil, 39) : $0.element }),
    ("playback before offline", valid.enumerated().map { $0.offset == 5 ? e(.playback, "p3", nil, 49) : $0.element }),
    ("online-only playback", valid.filter { $0.kind != .offlinePath }),
    ("no callback", valid.filter { $0.kind != .callback }),
    ("no staging", valid.filter { $0.kind != .staged }),
    ("no playback", valid.filter { $0.kind != .playback }),
    ("mixed session", valid.enumerated().map { $0.offset == 3 ? e(.staged, "p2", "task-A", 40, "s2") : $0.element }),
    ("reused arm process offline", valid.enumerated().map { $0.offset == 4 ? e(.offlinePath, "p1", nil, 50) : $0.element }),
    ("reused wake process offline", valid.enumerated().map { $0.offset == 4 ? e(.offlinePath, "p2", nil, 50) : $0.element })
]
for (name, mutated) in mutants { require(!correlate(mutated).accepted, name) }
for index in 0..<100 {
    let noise = e(index.isMultiple(of: 2) ? .callback : .staged,
                  "noise-\(index)", "task-\(index)", 15 + index, "old")
    require(correlate(valid + [noise]).accepted, "noise rejected valid chain \(index)")
    require(!correlate(mutants[3].1 + [noise]).accepted, "noise repaired wrong task \(index)")
}
print("PASS: valid causal chain, \(mutants.count) negative mutations, 200 cross-session noise assertions")
