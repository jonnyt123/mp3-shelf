import Foundation

// Run from repository root: swift ios/Tests/ArchiveAlternateEditionTests.swift
// Checks the production edition table and the bidirectional selection gate.
let source = try String(contentsOfFile: "ios/MP3Shelf/Services/AudioSourceFinder.swift", encoding: .utf8)
guard let begin = source.range(of: "    static func recordingEditionAgrees(filename: String, requestedTitle: String) -> Bool {"),
      let end = source.range(of: "\n    // Avoid spending", range: begin.upperBound..<source.endIndex) else {
    fatalError("Archive edition matcher source boundaries changed")
}
let implementation = String(source[begin.lowerBound..<end.lowerBound])\n    .replacingOccurrences(of: "    static func recordingEditionAgrees", with: "func recordingEditionAgrees")
for category in ["reverb", "8d-audio", "lofi", "piano-version", "stripped"] {
    precondition(implementation.contains("(\\"\(category)\\""), "Missing edition category: \(category)")
}
precondition(implementation.contains("editions(fileStem) == editions(requestedTitle)"),
             "Edition comparison must be bidirectional")
precondition(implementation.contains("requestedYears == fileYears"),
             "Remaster year disagreement must prevent automatic selection")

// Compile and execute the exact production matcher, rather than maintaining
// a second test-only implementation that could drift from the app.
let temporary = FileManager.default.temporaryDirectory
    .appendingPathComponent("mp3-shelf-edition-\(UUID().uuidString).swift")
defer { try? FileManager.default.removeItem(at: temporary) }
let cases = """
import Foundation
\(implementation)
func expect(_ actual: Bool, _ expected: Bool, _ name: String) {
    precondition(actual == expected, "FAIL: " + name)
    print("PASS: " + name)
}
expect(recordingEditionAgrees(filename: "Song.mp3", requestedTitle: "Song"), true, "studio")
expect(recordingEditionAgrees(filename: "Song (Slowed + Reverb).mp3", requestedTitle: "Song"), false, "slowed reverb")
expect(recordingEditionAgrees(filename: "Song (8D Audio).mp3", requestedTitle: "Song"), false, "8D audio")
expect(recordingEditionAgrees(filename: "Song (Lo-Fi).mp3", requestedTitle: "Song"), false, "lo-fi")
expect(recordingEditionAgrees(filename: "Song (Piano Version).mp3", requestedTitle: "Song"), false, "piano")
expect(recordingEditionAgrees(filename: "Song (Stripped).mp3", requestedTitle: "Song"), false, "stripped")
expect(recordingEditionAgrees(filename: "Song.mp3", requestedTitle: "Song (8D Audio)"), false, "reverse edition")
expect(recordingEditionAgrees(filename: "Song (8D Audio).mp3", requestedTitle: "Song (8D Audio)"), true, "matching 8D")
expect(recordingEditionAgrees(filename: "Deliver.mp3", requestedTitle: "Deliver"), true, "whole word live")
"""
try cases.write(to: temporary, atomically: true, encoding: .utf8)
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
process.arguments = ["swift", temporary.path]
try process.run()
process.waitUntilExit()
precondition(process.terminationStatus == 0, "Production matcher regression failed")
