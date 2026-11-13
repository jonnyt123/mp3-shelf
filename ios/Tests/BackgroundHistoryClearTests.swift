import Foundation

// Run from repository root: swift ios/Tests/BackgroundHistoryClearTests.swift
// Compile the actual history-clear method and atomic manifest writer into an
// isolated fixture. No network, simulator, or app container is required.
let source = try String(contentsOfFile: "ios/MP3Shelf/Services/BackgroundAudioDownloader.swift", encoding: .utf8)
let model = try String(contentsOfFile: "ios/MP3Shelf/Models/SourceDiscoveryJob.swift", encoding: .utf8)
func extract(_ source: String, _ start: String, _ end: String) -> String {
    guard let a = source.range(of: start),
          let b = source.range(of: end, range: a.upperBound..<source.endIndex) else {
        fatalError("Production method boundary changed; update fixture")
    }
    return String(source[a.lowerBound..<b.lowerBound])
}
let method = extract(source, "    func clearFinishedHistory() {", "    func cancelTransfer(")
let writer = extract(model, "enum BackgroundTicketManifestPolicy {", "/// Small, bounded recovery budget")
let fixture = #"""
import Foundation
struct BackgroundAudioTicket: Codable {
    enum Status: String, Codable { case queued, imported, failed, cancelled }
    let id: UUID
    var status: Status
}
final class FixtureTask {
    var cancelled = false
    func cancel() { cancelled = true }
}
final class Harness {
    static var root: URL!
    static func stagingURL(_ id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString + ".mp3")
    }
    var tickets: [UUID: BackgroundAudioTicket] = [:]
    var sourceResolutionTasks: [UUID: FixtureTask] = [:]
    var conversions: [UUID: Progress] = [:]
    var processing = Set<UUID>()
    let fm = FileManager.default
    let manifestURL: URL
    var revision = 0
    var updates = 0
    init(_ manifestURL: URL) { self.manifestURL = manifestURL }
    func updatePending() { updates += 1; revision += 1 }
__METHOD__
}
@main enum Tests {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("clear-history-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        Harness.root = root
        let queued = BackgroundAudioTicket(id: UUID(), status: .queued)
        let failed = BackgroundAudioTicket(id: UUID(), status: .failed)
        let active = BackgroundAudioTicket(id: UUID(), status: .imported)
        let h = Harness(root.appendingPathComponent("queue.json"))
        h.tickets = [queued.id: queued, failed.id: failed, active.id: active]
        h.processing.insert(active.id)
        let conversion = Progress(totalUnitCount: 10)
        h.conversions[active.id] = conversion
        let resolution = FixtureTask()
        h.sourceResolutionTasks[failed.id] = resolution
        for ticket in [queued, failed, active] {
            try Data("staged".utf8).write(to: Harness.stagingURL(ticket.id))
        }
        h.clearFinishedHistory()
        precondition(h.tickets.count == 1 && h.tickets[queued.id] != nil)
        let saved = try JSONDecoder().decode([BackgroundAudioTicket].self,
                                             from: Data(contentsOf: h.manifestURL))
        precondition(saved.count == 1 && saved[0].id == queued.id)
        precondition(resolution.cancelled && h.sourceResolutionTasks[failed.id] == nil)
        precondition(conversion.isCancelled)
        precondition(fm.fileExists(atPath: Harness.stagingURL(active.id).path))
        precondition(!fm.fileExists(atPath: Harness.stagingURL(failed.id).path))
        precondition(fm.fileExists(atPath: Harness.stagingURL(queued.id).path))
        precondition(h.updates == 1)
        print("PASS: durable clear retains queue and active conversion staging")

        let blocked = Harness(root.appendingPathComponent("missing/queue.json"))
        blocked.tickets[failed.id] = failed
        let pending = FixtureTask()
        blocked.sourceResolutionTasks[failed.id] = pending
        blocked.clearFinishedHistory()
        precondition(blocked.tickets[failed.id] != nil && !pending.cancelled)
        precondition(blocked.updates == 0)
        print("PASS: manifest failure preserves history and recovery state")

        // Conversion may own the staging file before processing is registered.
        // Clearing history must not delete the decoder's input in that window.
        let early = BackgroundAudioTicket(id: UUID(), status: .failed)
        let earlyHarness = Harness(root.appendingPathComponent("early-queue.json"))
        earlyHarness.tickets[early.id] = early
        let earlyConversion = Progress(totalUnitCount: 1)
        earlyHarness.conversions[early.id] = earlyConversion
        try Data("converting".utf8).write(to: Harness.stagingURL(early.id))
        earlyHarness.clearFinishedHistory()
        precondition(earlyConversion.isCancelled)
        precondition(fm.fileExists(atPath: Harness.stagingURL(early.id).path))
        precondition(earlyHarness.tickets.isEmpty)
        print("PASS: conversion-owned staging survives pre-processing cleanup")

        h.clearFinishedHistory()
        precondition(h.updates == 1)
        print("PASS: clearing empty history is idempotent")
    }
}
"""#
let dir = FileManager.default.temporaryDirectory.appendingPathComponent("history-fixture-\(UUID())")
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: dir) }
let file = dir.appendingPathComponent("Tests.swift")
try (writer + "\n" + fixture.replacingOccurrences(of: "__METHOD__", with: method))
    .write(to: file, atomically: true, encoding: .utf8)
let compile = Process()
compile.executableURL = URL(fileURLWithPath: "/usr/bin/env")
compile.arguments = ["swiftc", "-parse-as-library", file.path, "-o", dir.appendingPathComponent("tests").path]
try compile.run()
compile.waitUntilExit()
guard compile.terminationStatus == 0 else { fatalError("Fixture compilation failed") }
let run = Process()
run.executableURL = dir.appendingPathComponent("tests")
try run.run()
run.waitUntilExit()
guard run.terminationStatus == 0 else { fatalError("History regression failed") }
