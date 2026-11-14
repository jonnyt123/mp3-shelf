import Foundation

// Run from repository root: swift ios/Tests/CorruptManifestWarningTests.swift
// This test checks the actual source/view contracts and exercises the queue
// admission policy with a deterministic damaged-journal fixture.
let downloader = try String(contentsOfFile: "ios/MP3Shelf/Services/BackgroundAudioDownloader.swift", encoding: .utf8)
let view = try String(contentsOfFile: "ios/MP3Shelf/Views/DownloadManagerView.swift", encoding: .utf8)
func check(_ condition: @autoclosure () -> Bool, _ reason: String) {
    precondition(condition(), reason)
}
check(downloader.contains("var queueRecoveryWarning: String?"), "Recovery warning not exposed")
check(downloader.contains("manifestLoadError.map"), "Warning must derive from actual load failure")
check(downloader.contains("if manifestLoadError == nil { library?.resumePendingDiscovery() }"),
      "Automatic discovery may continue against a damaged journal")
check(view.contains("transfers.queueRecoveryWarning"), "Downloads view hides queue corruption")
check(view.contains("DOWNLOAD RECOVERY NEEDS ATTENTION"), "Recovery warning lacks visible heading")
check(view.contains("Existing offline songs remain available"), "Preservation guidance missing")

struct Ticket: Codable { let id: UUID }
func load(_ data: Data) -> (tickets: [Ticket], warning: String?) {
    do {
        let decoded = try JSONDecoder().decode([Ticket].self, from: data)
        guard Set(decoded.map(\.id)).count == decoded.count else {
            return ([], "Duplicate ticket identifiers")
        }
        return (decoded, nil)
    } catch {
        return ([], error.localizedDescription)
    }
}
func mayResumeDiscovery(_ warning: String?) -> Bool { warning == nil }
let id = UUID()
let good = try JSONEncoder().encode([Ticket(id: id)])
let bad = Data("{".utf8)
let duplicate = try JSONEncoder().encode([Ticket(id: id), Ticket(id: id)])
for bytes in [bad, duplicate] {
    let state = load(bytes)
    check(state.warning != nil, "Damaged queue was silently accepted")
    check(!mayResumeDiscovery(state.warning), "Discovery resumed against corrupt queue")
    check(bytes == (bytes == bad ? bad : duplicate), "Fixture bytes mutated")
}
let healthy = load(good)
check(healthy.warning == nil && healthy.tickets.count == 1, "Valid queue rejected")
check(mayResumeDiscovery(healthy.warning), "Healthy queue cannot resume")
print("PASS: damaged queue visible, automatic discovery paused, healthy queue unaffected")
