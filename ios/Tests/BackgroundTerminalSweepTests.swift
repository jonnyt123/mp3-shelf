import Foundation

// Run from repository root: swift ios/Tests/BackgroundTerminalSweepTests.swift
// Compile the exact terminal-file sweep from the production recovery pass.
// This reproduces the race where a ticket is marked terminal while its
// cancelled AVFoundation conversion is still reading the staged input.
let source = try String(contentsOfFile: "ios/MP3Shelf/Services/BackgroundAudioDownloader.swift", encoding: .utf8)
let start = "        for ticket in tickets.values where ticket.status != .queued {"
let end = "        guard let library else { return }"
guard let a = source.range(of: start),
      let b = source.range(of: end, range: a.upperBound..<source.endIndex) else {
    fatalError("Production recovery sweep boundaries changed")
}
let sweep = String(source[a.lowerBound..<b.lowerBound])
let fixture = #"""
import Foundation
struct Ticket {
    enum Status { case queued, imported, failed, cancelled }
    let id: UUID
    let status: Status
}
final class Harness {
    static var root: URL!
    static func stagingURL(_ id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString + ".mp3")
    }
    let fm = FileManager.default
    var tickets: [UUID: Ticket] = [:]
    var processing: Set<UUID> = []
    var conversions: [UUID: Progress] = [:]
    func sweep() {
__SWEEP__
    }
}
@main enum Regression {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("terminal-sweep-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        Harness.root = root
        let h = Harness()
        let converting = Ticket(id: UUID(), status: .cancelled)
        let processing = Ticket(id: UUID(), status: .imported)
        let idle = Ticket(id: UUID(), status: .failed)
        let queued = Ticket(id: UUID(), status: .queued)
        for ticket in [converting, processing, idle, queued] {
            h.tickets[ticket.id] = ticket
            try Data("staged audio".utf8).write(to: Harness.stagingURL(ticket.id))
        }
        h.conversions[converting.id] = Progress(totalUnitCount: 10)
        h.processing.insert(processing.id)
        h.sweep()
        precondition(fm.fileExists(atPath: Harness.stagingURL(converting.id).path),
                     "conversion-owned input must survive terminal sweep")
        precondition(fm.fileExists(atPath: Harness.stagingURL(processing.id).path),
                     "processing-owned input must survive terminal sweep")
        precondition(!fm.fileExists(atPath: Harness.stagingURL(idle.id).path),
                     "unowned terminal staging must be reclaimed")
        precondition(fm.fileExists(atPath: Harness.stagingURL(queued.id).path),
                     "queued audio must remain recoverable")
        print("PASS: terminal sweep retains live conversion and queued staging")
        h.conversions.removeValue(forKey: converting.id)
        h.processing.remove(processing.id)
        h.sweep()
        precondition(!fm.fileExists(atPath: Harness.stagingURL(converting.id).path))
        precondition(!fm.fileExists(atPath: Harness.stagingURL(processing.id).path))
        print("PASS: terminal staging is reclaimed after ownership ends")
        h.sweep()
        print("PASS: repeated terminal sweep is idempotent")
    }
}
"""#
let dir = FileManager.default.temporaryDirectory.appendingPathComponent("terminal-sweep-tests-\(UUID())")
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: dir) }
let file = dir.appendingPathComponent("Tests.swift")
try fixture.replacingOccurrences(of: "__SWEEP__", with: sweep)
    .write(to: file, atomically: true, encoding: .utf8)
let compiler = Process()
compiler.executableURL = URL(fileURLWithPath: "/usr/bin/env")
compiler.arguments = ["swiftc", "-parse-as-library", file.path, "-o", dir.appendingPathComponent("tests").path]
try compiler.run()
compiler.waitUntilExit()
guard compiler.terminationStatus == 0 else { fatalError("Fixture compilation failed") }
let executable = Process()
executable.executableURL = dir.appendingPathComponent("tests")
try executable.run()
executable.waitUntilExit()
guard executable.terminationStatus == 0 else { fatalError("Terminal sweep regression failed") }
