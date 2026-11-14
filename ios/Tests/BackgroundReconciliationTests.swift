import Foundation

// Run from repository root: swift ios/Tests/BackgroundReconciliationTests.swift
// Compile the production reconciliation method and atomic manifest writer with
// a controlled library/task inventory and real temporary staged files.
let downloader = try String(contentsOfFile: "ios/MP3Shelf/Services/BackgroundAudioDownloader.swift", encoding: .utf8)
let model = try String(contentsOfFile: "ios/MP3Shelf/Models/SourceDiscoveryJob.swift", encoding: .utf8)
func section(_ text: String, _ start: String, _ end: String) -> String {
    guard let a = text.range(of: start),
          let b = text.range(of: end, range: a.upperBound..<text.endIndex) else {
        fatalError("Production reconciliation boundary changed; update fixture explicitly")
    }
    return String(text[a.lowerBound..<b.lowerBound])
}
let method = section(downloader, "    private func reconcileAlreadyStoredDownloads(", "    /// Recover *only* temporary")
    .replacingOccurrences(of: "private func reconcileAlreadyStoredDownloads", with: "func reconcileAlreadyStoredDownloads")
let writer = section(model, "enum BackgroundTicketManifestPolicy {", "/// Small, bounded recovery budget")
let fixture = #"""
import Foundation
struct BackgroundAudioTicket: Codable {
    enum Status: String, Codable { case queued, imported, failed, cancelled }
    var id = UUID()
    var playlistID = UUID()
    var requested = "exact-recording"
    var status: Status = .queued
    var failureReason: String?
    var alternativeSources: [String]? = ["fallback"]
    var nextRetryAt: Date? = .distantFuture
}
final class FixtureLibrary {
    var finished = 0
    func hasOfflineRecording(matching value: String) -> Bool { value == "exact-recording" }
    func finishedBackgroundDownload(for id: UUID, succeeded: Bool) {
        precondition(succeeded)
        finished += 1
    }
}
final class FixtureTask {
    var taskDescription: String?
    var cancelled = false
    init(_ id: UUID) { taskDescription = id.uuidString }
    func cancel() { cancelled = true }
}
final class FixtureSession {
    var tasks: [FixtureTask] = []
    func getAllTasks(_ callback: ([FixtureTask]) -> Void) { callback(tasks) }
}
final class ReconciliationHarness {
    static var root: URL!
    static func stagingURL(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString + ".mp3") }
    var library: FixtureLibrary? = FixtureLibrary()
    var tickets: [UUID: BackgroundAudioTicket] = [:]
    var processing: Set<UUID> = []
    var conversions: [UUID: Progress] = [:]
    let fm = FileManager.default
    var manifestURL: URL
    let session = FixtureSession()
    var updates = 0
    init(_ url: URL) { manifestURL = url }
    func updatePending() { updates += 1 }
__METHOD__
}
@main enum ReconciliationTests {
    static func main() throws {
        func check(_ value: Bool, _ label: String) {
            precondition(value, "FAIL: " + label)
            print("PASS: " + label)
        }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("background-reconcile-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        ReconciliationHarness.root = root
        let h = ReconciliationHarness(root.appendingPathComponent("queue.json"))
        let active = BackgroundAudioTicket()
        let idle = BackgroundAudioTicket()
        var unrelated = BackgroundAudioTicket()
        unrelated.requested = "different-recording"
        let excluded = BackgroundAudioTicket()
        h.tickets = [active.id: active, idle.id: idle, unrelated.id: unrelated, excluded.id: excluded]
        h.processing.insert(active.id)
        let conversion = Progress(totalUnitCount: 100)
        h.conversions[active.id] = conversion
        for ticket in [active, idle, unrelated, excluded] {
            try Data("recoverable media".utf8).write(to: ReconciliationHarness.stagingURL(ticket.id))
            h.session.tasks.append(FixtureTask(ticket.id))
        }
        h.reconcileAlreadyStoredDownloads(excluding: excluded.id)
        check(h.tickets[active.id]?.status == .imported && h.tickets[idle.id]?.status == .imported,
              "one offline recording durably fulfills duplicate queued tickets")
        check(fm.fileExists(atPath: ReconciliationHarness.stagingURL(active.id).path) && conversion.isCancelled,
              "active conversion retains its staged file until cancellation completes")
        check(!fm.fileExists(atPath: ReconciliationHarness.stagingURL(idle.id).path),
              "idle duplicate staging is cleaned after durable completion")
        check(h.tickets[unrelated.id]?.status == .queued && h.tickets[excluded.id]?.status == .queued &&
              h.session.tasks.filter(\.cancelled).count == 2 && h.library?.finished == 2,
              "only fulfilled tickets are acknowledged and their daemon tasks cancelled")
        let saved = try JSONDecoder().decode([BackgroundAudioTicket].self, from: Data(contentsOf: h.manifestURL))
        check(saved.filter { $0.status == .imported }.count == 2 &&
              saved.filter { $0.status == .imported }.allSatisfy { $0.nextRetryAt == nil && $0.alternativeSources == nil },
              "completion survives manifest reload without stale retry state")
        h.reconcileAlreadyStoredDownloads(excluding: excluded.id)
        check(h.library?.finished == 2, "repeated reconciliation does not acknowledge imports twice")

        // Conversion ownership can begin before insertion into processing.
        // Reconciliation must not unlink a decoder's input in this window.
        let early = BackgroundAudioTicket()
        let earlyConversion = Progress(totalUnitCount: 100)
        h.tickets[early.id] = early
        h.conversions[early.id] = earlyConversion
        try Data("conversion input".utf8).write(to: ReconciliationHarness.stagingURL(early.id))
        h.session.tasks.append(FixtureTask(early.id))
        h.reconcileAlreadyStoredDownloads()
        check(h.tickets[early.id]?.status == .imported && earlyConversion.isCancelled &&
              fm.fileExists(atPath: ReconciliationHarness.stagingURL(early.id).path),
              "conversion-owned staging survives reconciliation before processing registration")

        let failed = ReconciliationHarness(root.appendingPathComponent("missing-parent/queue.json"))
        failed.tickets[active.id] = active
        let task = FixtureTask(active.id)
        failed.session.tasks = [task]
        let retained = Progress(totalUnitCount: 1)
        failed.conversions[active.id] = retained
        failed.reconcileAlreadyStoredDownloads()
        check(failed.tickets[active.id]?.status == .queued && !task.cancelled && !retained.isCancelled &&
              failed.library?.finished == 0 && fm.fileExists(atPath: ReconciliationHarness.stagingURL(active.id).path),
              "failed manifest write preserves queued work, conversion and staged audio")
    }
}
"""#
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("background-tests-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
let file = directory.appendingPathComponent("Tests.swift")
try (writer + "\n" + fixture.replacingOccurrences(of: "__METHOD__", with: method))
    .write(to: file, atomically: true, encoding: .utf8)
func run(_ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw NSError(domain: "BackgroundReconciliationTests", code: Int(process.terminationStatus))
    }
}
try run(["swiftc", "-parse-as-library", file.path, "-o", directory.appendingPathComponent("tests").path])
try run([directory.appendingPathComponent("tests").path])
