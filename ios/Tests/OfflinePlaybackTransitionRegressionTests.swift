import Foundation
// Independent policy fixture; run: swift ios/Tests/OfflinePlaybackTransitionRegressionTests.swift
// Passing this fixture is never evidence of a physical iPhone test.
struct OfflineEvent {
    enum Kind { case exit, launch, network, clock }
    let kind: Kind
    let session: String
    let process: String
    let time: Int
    let offline: Bool?
    let recording: String?
    let position: Int?
}
enum OfflineVerdict: Equatable { case accepted, invalidIdentity, missingRelaunch, missingPath, missingAdvance }
func evaluate(_ events: [OfflineEvent], session: String, recordings: [String]) -> OfflineVerdict {
    guard !session.isEmpty, !recordings.isEmpty, Set(recordings).count == recordings.count,
          recordings.allSatisfy({ !$0.isEmpty }),
          events.allSatisfy({ $0.time > 0 && !$0.session.isEmpty && !$0.process.isEmpty }) else { return .invalidIdentity }
    let scoped = events.filter { $0.session == session }.sorted { $0.time < $1.time }
    let launches = scoped.filter { $0.kind == .launch && $0.offline == true }
    guard !launches.isEmpty else { return .missingRelaunch }
    var foundPath = false
    for launch in launches {
        guard scoped.contains(where: { $0.kind == .exit && $0.process != launch.process && $0.time < launch.time }) else { continue }
        // A process identity must identify one launch epoch. Never join clocks from a later
        // relaunch or a prior launch that reused the same process label.
        let end = scoped.filter {
            $0.process == launch.process && $0.time > launch.time &&
            ($0.kind == .exit || $0.kind == .launch)
        }.map(\.time).min() ?? Int.max
        guard !scoped.contains(where: {
            $0.kind == .launch && $0.process == launch.process && $0.time < launch.time
        }) else { continue }
        let paths = scoped.filter { $0.kind == .network && $0.process == launch.process && $0.time >= launch.time && $0.time < end }
        guard let offlinePath = paths.first(where: { $0.offline == true }) else { continue }
        foundPath = true
        // An online transition at any point after launch invalidates this offline epoch,
        // even if NWPath later becomes unsatisfied again.
        let online = paths.first(where: { $0.offline == false && $0.time >= launch.time })?.time ?? Int.max
        let clocks = scoped.filter { $0.kind == .clock && $0.process == launch.process &&
            $0.time > offlinePath.time && $0.time < min(end, online) && ($0.position ?? -1) >= 0 && $0.time < online }
        if recordings.allSatisfy({ id in
            let samples = clocks.filter { $0.recording == id }
            return samples.contains { a in samples.contains { b in b.time > a.time && b.position! > a.position! } }
        }) { return .accepted }
    }
    return foundPath ? .missingAdvance : .missingPath
}
func ev(_ kind: OfflineEvent.Kind, _ process: String, _ time: Int, offline: Bool? = nil,
        recording: String? = nil, position: Int? = nil, session: String = "run") -> OfflineEvent {
    .init(kind: kind, session: session, process: process, time: time, offline: offline, recording: recording, position: position)
}
let good = [ev(.exit, "before", 10), ev(.launch, "after", 20, offline: true),
    ev(.network, "after", 30, offline: true), ev(.clock, "after", 40, recording: "a", position: 100),
    ev(.clock, "after", 50, recording: "a", position: 1100),
    ev(.clock, "after", 60, recording: "b", position: 200),
    ev(.clock, "after", 70, recording: "b", position: 1200)]
func check(_ events: [OfflineEvent], _ verdict: OfflineVerdict, _ label: String, ids: [String] = ["a", "b"]) {
    let actual = evaluate(events, session: "run", recordings: ids)
    precondition(actual == verdict, "\(label): expected \(verdict), got \(actual)")
}
check(good, .accepted, "ordered offline relaunch")
check(Array(good.dropFirst()), .missingPath, "no prior process")
check(good.filter { $0.kind != .launch }, .missingRelaunch, "no launch")
check(good.filter { $0.kind != .network }, .missingPath, "no NWPath")
check(good.map { $0.kind == .network ? ev(.network, "after", 30, offline: false) : $0 }, .missingPath, "online path")
check(good.filter { $0.recording != "b" }, .missingAdvance, "partial catalog")
check(good.filter { $0.time != 50 }, .missingAdvance, "single clock sample")
check(good.map { $0.time == 50 ? ev(.clock, "after", 50, recording: "a", position: 100) : $0 }, .missingAdvance, "frozen clock")
check(good.map { $0.time == 50 ? ev(.clock, "other", 50, recording: "a", position: 1100) : $0 }, .missingAdvance, "cross-process clock")
check(good.map { $0.time == 50 ? ev(.clock, "after", 50, recording: "a", position: 1100, session: "old") : $0 }, .missingAdvance, "cross-session clock")
check(good + [ev(.network, "after", 45, offline: false)], .missingAdvance, "network reconnected")
check(good + [ev(.exit, "after", 45)], .missingAdvance, "clock after exit")
check(good + [ev(.launch, "after", 55, offline: true)], .missingAdvance, "second launch splits playback epoch")
check(good + [ev(.network, "after", 25, offline: false)], .missingAdvance, "online after launch before offline path")
check(good + [ev(.launch, "after", 15, offline: false)], .missingPath, "reused process label before launch")
check(good + [ev(.exit, "after", 55), ev(.launch, "after", 56, offline: true)], .missingAdvance, "relaunch cannot join earlier clock")
check(good, .invalidIdentity, "duplicate catalog", ids: ["a", "a"])
check(good, .invalidIdentity, "empty catalog", ids: [])
check(good + [ev(.clock, "", 80, recording: "a", position: 999)], .invalidIdentity, "empty process")
for i in 0..<128 {
    let noise = ev(.clock, "noise-\(i)", 80 + i, recording: "a", position: 9999, session: "old")
    check(good + [noise], .accepted, "old-session noise \(i)")
    check(good.filter { $0.time != 50 } + [noise], .missingAdvance, "old session cannot repair clock \(i)")
}
print("PASS: 19 acceptance mutations and 256 noise assertions; policy fixture only")
