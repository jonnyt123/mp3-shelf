import Foundation
// Run: swift ios/Tests/OfflineEvidenceReplayIsolationTests.swift
// Synthetic policy model, not a production URLSession or physical iPhone test.
struct Event: Codable {
    let kind: String
    let run: String
    let process: String
    let task: String?
    let recording: String?
    let sequence: Int
    let offline: Bool
}
struct Evidence: Codable {
    let sourceSHA: String
    let selectedRun: String
    let installedSHA: String
    let catalog: [String]
    let events: [Event]
}
enum Verdict: Equatable { case accepted, invalidIdentity, missingTransfer, missingRestart, missingPlayback }
func assess(_ p: Evidence) -> Verdict {
    let hex = { (s: String) in s.count == 40 && s.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    guard hex(p.sourceSHA), p.installedSHA == p.sourceSHA, !p.selectedRun.isEmpty, !p.catalog.isEmpty,
          Set(p.catalog).count == p.catalog.count,
          p.catalog.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
          p.events.allSatisfy({ $0.sequence > 0 && !$0.run.isEmpty && !$0.process.isEmpty &&
              ($0.task == nil || !$0.task!.isEmpty) }) else { return .invalidIdentity }
    // Only the explicitly selected run may satisfy acceptance. Historical
    // receipts may coexist but cannot fill gaps in a newer run.
    let events = p.events.filter { $0.run == p.selectedRun }
    for wake in events where wake.kind == "osBackgroundWake" {
        guard let task = wake.task else { continue }
        for completion in events where completion.kind == "urlSessionCompletion" &&
            completion.process == wake.process && completion.task == task && completion.sequence > wake.sequence {
            for stage in events where stage.kind == "durableStaging" &&
                stage.process == wake.process && stage.task == task && stage.sequence > completion.sequence {
                for restart in events where restart.kind == "offlineRelaunch" &&
                    restart.process != wake.process && restart.sequence > stage.sequence && restart.offline {
                    let played = Set(events.filter { $0.kind == "localPlaybackAdvanced" &&
                        $0.process == restart.process && $0.sequence > restart.sequence && $0.offline }
                        .compactMap(\.recording))
                    if Set(p.catalog).isSubset(of: played) { return .accepted }
                }
            }
        }
    }
    let transfer = events.contains { $0.kind == "osBackgroundWake" } &&
        events.contains { $0.kind == "urlSessionCompletion" } &&
        events.contains { $0.kind == "durableStaging" }
    if !transfer { return .missingTransfer }
    if !events.contains(where: { $0.kind == "offlineRelaunch" && $0.offline }) { return .missingRestart }
    return .missingPlayback
}
let sha = String(repeating: "a", count: 40)
func event(_ kind: String, _ n: Int, run: String = "current", process: String = "downloader",
           task: String? = "task", recording: String? = nil, offline: Bool = false) -> Event {
    Event(kind: kind, run: run, process: process, task: task, recording: recording, sequence: n, offline: offline)
}
let chain = [event("osBackgroundWake", 10), event("urlSessionCompletion", 20),
             event("durableStaging", 30), event("offlineRelaunch", 40, process: "reopened", task: nil, offline: true),
             event("localPlaybackAdvanced", 50, process: "reopened", task: nil, recording: "song-a", offline: true),
             event("localPlaybackAdvanced", 60, process: "reopened", task: nil, recording: "song-b", offline: true)]
let baseline = Evidence(sourceSHA: sha, selectedRun: "current", installedSHA: sha, catalog: ["song-a", "song-b"], events: chain)
func check(_ value: Evidence, _ expected: Verdict, _ label: String) {
    precondition(assess(value) == expected, "\(label): \(assess(value)) != \(expected)")
}
func changed(_ mutate: (inout Evidence) -> Void) -> Evidence {
    var copy = baseline
    mutate(&copy)
    return copy
}
check(baseline, .accepted, "complete same-run chain")
check(changed { $0 = Evidence(sourceSHA: sha, selectedRun: "current", installedSHA: String(repeating: "b", count: 40), catalog: $0.catalog, events: $0.events) }, .invalidIdentity, "wrong installed binary")
check(changed { $0 = Evidence(sourceSHA: sha, selectedRun: "current", installedSHA: sha, catalog: ["song-a", "song-a"], events: $0.events) }, .invalidIdentity, "duplicate catalog")
check(changed { $0 = Evidence(sourceSHA: sha, selectedRun: "current", installedSHA: sha, catalog: $0.catalog, events: Array($0.events.dropFirst())) }, .missingTransfer, "missing OS wake")
check(changed { $0 = Evidence(sourceSHA: sha, selectedRun: "current", installedSHA: sha, catalog: $0.catalog, events: $0.events.filter { $0.kind != "offlineRelaunch" }) }, .missingRestart, "no offline restart")
check(changed { $0 = Evidence(sourceSHA: sha, selectedRun: "current", installedSHA: sha, catalog: $0.catalog, events: $0.events.filter { $0.recording != "song-b" }) }, .missingPlayback, "partial playlist")
for index in 0..<128 {
    let historical = chain.map { Event(kind: $0.kind, run: "old-\(index)", process: $0.process,
                                      task: $0.task, recording: $0.recording, sequence: $0.sequence, offline: $0.offline) }
    check(changed { $0 = Evidence(sourceSHA: sha, selectedRun: "current", installedSHA: sha, catalog: $0.catalog,
                                  events: Array($0.events.dropFirst()) + historical) }, .missingTransfer,
          "historic wake cannot repair current chain \(index)")
    check(changed { $0 = Evidence(sourceSHA: sha, selectedRun: "current", installedSHA: sha, catalog: $0.catalog,
                                  events: $0.events.filter { $0.recording != "song-b" } + historical.filter { $0.recording == "song-b" }) }, .missingPlayback,
          "historic playback cannot repair current playlist \(index)")
}
let root = FileManager.default.temporaryDirectory.appendingPathComponent("offline-evidence-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
let receipt = root.appendingPathComponent("evidence.json")
try JSONEncoder().encode(baseline).write(to: receipt, options: .atomic)
check(try JSONDecoder().decode(Evidence.self, from: Data(contentsOf: receipt)), .accepted, "receipt round trip")
try Data("{\"events\":[".utf8).write(to: receipt, options: .atomic)
precondition((try? JSONDecoder().decode(Evidence.self, from: Data(contentsOf: receipt))) == nil,
             "truncated receipt unexpectedly decoded")
print("PASS: 6 baseline/mutation cases, 256 historic-event isolation cases, durable receipt round-trip and truncation rejection; synthetic only")
