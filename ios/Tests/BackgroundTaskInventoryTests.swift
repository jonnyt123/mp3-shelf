import Foundation

// Run from repository root: swift ios/Tests/BackgroundTaskInventoryTests.swift
// Compiles the exact production inventory implementation with a deterministic
// mock background session; no live network, URLSession daemon or iPhone required.
let source = try String(contentsOfFile: "ios/MP3Shelf/Services/BackgroundAudioDownloader.swift", encoding: .utf8)
guard let a = source.range(of: "    private struct BackgroundTaskInventory {"),
      let b = source.range(of: "    #if DEBUG\n    func hasBackgroundTasksForProof()", range: a.upperBound..<source.endIndex) else {
    fatalError("Background inventory production boundaries changed")
}
let implementation = String(source[a.lowerBound..<b.lowerBound])
    .replacingOccurrences(of: "private struct BackgroundTaskInventory", with: "struct BackgroundTaskInventory")
    .replacingOccurrences(of: "private func backgroundTaskInventory", with: "func backgroundTaskInventory")
let fixture = #"""
import Foundation
struct FixtureTask { let taskDescription: String? }
final class FixtureSession {
    var tasks: [FixtureTask] = []
    func getAllTasks(_ callback: ([FixtureTask]) -> Void) { callback(tasks) }
}
final class Harness {
    let session = FixtureSession()
__IMPLEMENTATION__
}
@main enum InventoryRegression {
    static func main() async {
        let h = Harness()
        let first = UUID()
        let second = UUID()
        h.session.tasks = [
            FixtureTask(taskDescription: first.uuidString),
            FixtureTask(taskDescription: first.uuidString),
            FixtureTask(taskDescription: second.uuidString)
        ]
        let duplicate = await h.backgroundTaskInventory()
        precondition(duplicate.ids == Set([first, second]) && !duplicate.hasUnknownTasks,
                     "duplicate recognized tasks must not block orphan recovery")
        print("PASS: duplicate known task IDs are not unknown tasks")
        h.session.tasks.append(FixtureTask(taskDescription: "not-a-uuid"))
        let malformed = await h.backgroundTaskInventory()
        precondition(malformed.hasUnknownTasks && malformed.ids.count == 2,
                     "malformed task description must block orphan recovery")
        print("PASS: malformed task description remains unknown")
        h.session.tasks = [FixtureTask(taskDescription: nil)]
        let missing = await h.backgroundTaskInventory()
        precondition(missing.hasUnknownTasks && missing.ids.isEmpty,
                     "missing task description must block orphan recovery")
        print("PASS: missing task description remains unknown")
        h.session.tasks = []
        let empty = await h.backgroundTaskInventory()
        precondition(empty.ids.isEmpty && !empty.hasUnknownTasks,
                     "empty inventory must permit aged orphan recovery")
        print("PASS: empty inventory is known and empty")
    }
}
"""#
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("inventory-fixture-\(UUID())")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
let file = directory.appendingPathComponent("Tests.swift")
try fixture.replacingOccurrences(of: "__IMPLEMENTATION__", with: implementation)
    .write(to: file, atomically: true, encoding: .utf8)
func run(_ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw NSError(domain: "BackgroundTaskInventoryTests", code: Int(process.terminationStatus))
    }
}
try run(["swiftc", "-parse-as-library", file.path, "-o", directory.appendingPathComponent("tests").path])
try run([directory.appendingPathComponent("tests").path])
