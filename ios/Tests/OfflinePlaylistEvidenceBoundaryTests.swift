import Foundation
// Run: swift ios/Tests/OfflinePlaylistEvidenceBoundaryTests.swift
// Reference acceptance-policy fixture only. Not evidence of a real iPhone run.
struct Proof {
    struct Song: Hashable { let id: String; let artist: String; let title: String; let edition: String; let duration: Int }
    struct Match { let requested: Song; let saved: Song?; let source: String?; let decoded: Bool }
    struct Event { let kind: String; let session: String; let process: String; let task: String?; let time: Int; let offline: Bool; let recordingID: String? }
    var expectedSHA: String
    var installedSHA: String
    var catalog: [Song]
    var matches: [Match]
    var events: [Event]
}
enum Verdict: Equatable { case accepted, badSHA, badCatalog, badSource, badCallback, badOffline }
func assess(_ p: Proof) -> Verdict {
    let shaOK = { (s: String) in s.count == 40 && s.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    guard shaOK(p.expectedSHA), p.expectedSHA == p.installedSHA else { return .badSHA }
    guard !p.catalog.isEmpty, Set(p.catalog.map(\.id)).count == p.catalog.count,
          p.catalog.allSatisfy({ !$0.id.isEmpty && !$0.artist.isEmpty && !$0.title.isEmpty && $0.duration > 0 }),
          p.matches.count == p.catalog.count, Set(p.matches.map { $0.requested.id }).count == p.catalog.count else { return .badCatalog }
    for song in p.catalog {
        guard let m = p.matches.first(where: { $0.requested.id == song.id }),
              m.requested == song, m.saved == song else { return .badCatalog }
        guard m.decoded, let source = m.source, let u = URLComponents(string: source),
              u.scheme == "https", let host = u.host, u.user == nil, u.password == nil,
              host != "spotify.com", !host.hasSuffix(".spotify.com"),
              host != "spotifycdn.com", !host.hasSuffix(".spotifycdn.com") else { return .badSource }
    }
    guard p.events.allSatisfy({ !$0.session.isEmpty && !$0.process.isEmpty && $0.time > 0 &&
        ($0.task == nil || !$0.task!.isEmpty) }) else { return .badCallback }
    for wake in p.events where wake.kind == "osBackgroundWake" {
        guard let task = wake.task,
              let callback = p.events.first(where: { $0.kind == "urlSessionCompletion" &&
                $0.session == wake.session && $0.process == wake.process &&
                $0.task == task && $0.time > wake.time }),
              let staged = p.events.first(where: { $0.kind == "durableStaging" &&
                $0.session == wake.session && $0.process == wake.process &&
                $0.task == task && $0.time > callback.time }) else { continue }
        guard let restart = p.events.first(where: { $0.kind == "offlineRelaunch" &&
                $0.session == wake.session && $0.process != wake.process &&
                $0.time > staged.time && $0.offline }),
              p.catalog.allSatisfy({ song in p.events.contains(where: { $0.kind == "localPlaybackAdvanced" &&
                $0.session == wake.session && $0.process == restart.process &&
                $0.time > restart.time && $0.offline && $0.recordingID == song.id }) }) else { return .badOffline }
        return .accepted
    }
    return .badCallback
}
func check(_ proof: Proof, _ verdict: Verdict, _ name: String) {
    precondition(assess(proof) == verdict, "\(name): expected \(verdict), got \(assess(proof))")
}
let song = Proof.Song(id: "track-1", artist: "Artist", title: "Track", edition: "Album", duration: 203)
let match = Proof.Match(requested: song, saved: song, source: "https://files.example.org/audio.mp3", decoded: true)
let events = [
    Proof.Event(kind: "osBackgroundWake", session: "s", process: "download", task: "t", time: 10, offline: false, recordingID: nil),
    Proof.Event(kind: "urlSessionCompletion", session: "s", process: "download", task: "t", time: 20, offline: false, recordingID: nil),
    Proof.Event(kind: "durableStaging", session: "s", process: "download", task: "t", time: 30, offline: false, recordingID: nil),
    Proof.Event(kind: "offlineRelaunch", session: "s", process: "restart", task: nil, time: 40, offline: true, recordingID: nil),
    Proof.Event(kind: "localPlaybackAdvanced", session: "s", process: "restart", task: nil, time: 50, offline: true, recordingID: "track-1")
]
let good = Proof(expectedSHA: String(repeating: "a", count: 40), installedSHA: String(repeating: "a", count: 40),
                 catalog: [song], matches: [match], events: events)
func mutant(_ edit: (inout Proof) -> Void) -> Proof { var copy = good; edit(&copy); return copy }
check(good, .accepted, "valid chain")
check(mutant { $0.installedSHA = String(repeating: "b", count: 40) }, .badSHA, "wrong binary")
check(mutant { $0.catalog.append(song) }, .badCatalog, "duplicate catalog")
check(mutant { $0.catalog.append(.init(id: "2", artist: "A", title: "B", edition: "C", duration: 120)) }, .badCatalog, "missing recording")
check(mutant { $0.matches[0] = .init(requested: song, saved: .init(id: song.id, artist: "Artist", title: "Wrong", edition: "Album", duration: 203), source: match.source, decoded: true) }, .badCatalog, "wrong edition")
check(mutant { $0.matches[0] = .init(requested: song, saved: song, source: "https://open.spotify.com/track/1", decoded: true) }, .badSource, "Spotify stream")
check(mutant { $0.matches[0] = .init(requested: song, saved: song, source: match.source, decoded: false) }, .badSource, "undecoded bytes")
check(mutant { $0.events[1] = .init(kind: "urlSessionCompletion", session: "s", process: "other", task: "t", time: 20, offline: false, recordingID: nil) }, .badCallback, "cross-process callback")
check(mutant { $0.events[2] = .init(kind: "durableStaging", session: "s", process: "download", task: "other", time: 30, offline: false) }, .badCallback, "cross-task stage")
check(mutant { $0.events[3] = .init(kind: "offlineRelaunch", session: "s", process: "restart", task: nil, time: 40, offline: false, recordingID: nil) }, .badOffline, "online restart")
check(mutant { $0.events[4] = .init(kind: "localPlaybackAdvanced", session: "s", process: "restart", task: nil, time: 50, offline: false) }, .badOffline, "online playback")
check(mutant { $0.events[4] = .init(kind: "localPlaybackAdvanced", session: "s", process: "download", task: nil, time: 50, offline: true, recordingID: "track-1") }, .badOffline, "wrong playback process")
check(mutant { $0.events[4] = .init(kind: "localPlaybackAdvanced", session: "s", process: "restart", task: nil, time: 35, offline: true) }, .badOffline, "playback before restart")
// Offline playback evidence must identify every imported recording, not merely any audio clock.
check(mutant { $0.events[4] = .init(kind: "localPlaybackAdvanced", session: "s", process: "restart", task: nil, time: 50, offline: true, recordingID: "unrelated") }, .badOffline, "unrelated audio cannot prove imported track")
check(mutant { $0.events[4] = .init(kind: "localPlaybackAdvanced", session: "s", process: "restart", task: nil, time: 50, offline: true, recordingID: nil) }, .badOffline, "missing recording identity")
let second = Proof.Song(id: "track-2", artist: "Second", title: "Other", edition: "Album", duration: 180)
let secondMatch = Proof.Match(requested: second, saved: second, source: "https://files.example.org/other.mp3", decoded: true)
check(mutant { $0.catalog.append(second); $0.matches.append(secondMatch) }, .badOffline, "one offline clock cannot prove two tracks")
check(mutant { $0.catalog.append(second); $0.matches.append(secondMatch); $0.events.append(.init(kind: "localPlaybackAdvanced", session: "s", process: "restart", task: nil, time: 60, offline: true, recordingID: second.id)) }, .accepted, "every imported recording independently played offline")
for i in 0..<200 {
    let noise = Proof.Event(kind: "durableStaging", session: "old", process: "p\(i)", task: "t\(i)", time: 60 + i, offline: false, recordingID: nil)
    check(mutant { $0.events.append(noise) }, .accepted, "unrelated session noise \(i)")
}
print("PASS: 17 deterministic acceptance cases and 200 noise cases; fixture only")
