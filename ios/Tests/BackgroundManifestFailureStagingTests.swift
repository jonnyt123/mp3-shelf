import Foundation

// Run from repository root:
// swift ios/Tests/BackgroundManifestFailureStagingTests.swift
// Source contract plus deterministic failed-manifest-write recovery fixture.
// Does not substitute for native URLSession or AVAudioFile integration testing.
let source = try String(contentsOfFile: "ios/MP3Shelf/Services/BackgroundAudioDownloader.swift", encoding: .utf8)
guard let failureStart = source.range(of: "private func setFailed(_ id: UUID"),
      let failureEnd = source.range(of: "private func updateProgress(", range: failureStart.upperBound..<source.endIndex),
      let importStart = source.range(of: "private func importStagedDownloadsPass() async"),
      let importEnd = source.range(of: "private struct BackgroundTaskInventory", range: importStart.upperBound..<source.endIndex) else {
    fatalError("Production recovery functions missing")
}
let failure = String(source[failureStart.lowerBound..<failureEnd.lowerBound])
let importer = String(source[importStart.lowerBound..<importEnd.lowerBound])
precondition(failure.contains("-> Bool"))
precondition(failure.contains("if try startAlternateTransfer(after: id, earliestBeginDate: earliestRecovery) { return true }"))
precondition(failure.contains("noteQueueWriteFailure(error, for: id)\n            return false"))
precondition(failure.contains("updatePending()\n        return true"))
precondition(importer.contains("guard setFailed(ticket.id, reason: \"Audio already stored or could not be imported\") else { continue }"))
precondition(importer.contains("if setFailed(ticket.id, reason: AudioDownloadDiagnostics.message(for: error),"))
precondition(importer.contains("try? fm.removeItem(at: stagedURL)"))

let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("mp3-shelf-manifest-recovery-" + UUID().uuidString)
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let staged = root.appendingPathComponent("ticket.mp3")
let manifest = root.appendingPathComponent("tickets.json")
let bytes = Data([0x49, 0x44, 0x33, 0x04, 0x00, 0x00, 0x00, 0x00])
try bytes.write(to: staged)

func finalize(manifestWriteSucceeded: Bool) throws {
    if manifestWriteSucceeded {
        try Data(#"{\"status\":\"failed\"}"#.utf8).write(to: manifest, options: .atomic)
        try fm.removeItem(at: staged)
    }
}
try finalize(manifestWriteSucceeded: false)
precondition(fm.fileExists(atPath: staged.path), "Failed queue write must preserve staged bytes")
precondition(!fm.fileExists(atPath: manifest.path))
precondition(try Data(contentsOf: staged) == bytes)
try finalize(manifestWriteSucceeded: true)
precondition(!fm.fileExists(atPath: staged.path))
precondition(fm.fileExists(atPath: manifest.path))
print("PASS: failed terminal manifest persistence retains staged audio for recovery")
