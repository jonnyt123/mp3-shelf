import Foundation

// Run from repository root: swift ios/Tests/BackgroundDuplicateCompletionTests.swift
// Source-level regression plus deterministic local-file ownership fixture.
// This does not simulate URLSession's delegate scheduling on a real iPhone.
let source = try String(contentsOfFile: "ios/MP3Shelf/Services/BackgroundAudioDownloader.swift", encoding: .utf8)
guard let start = source.range(of: "nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,\n                                didFinishDownloadingTo location: URL)") else {
    fatalError("Download completion delegate not found")
}
let delegate = String(source[start.lowerBound...])
let end = delegate.range(of: "nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,\n                                didWriteData")
let completion = String(delegate[..<(end?.lowerBound ?? delegate.endIndex)])
guard let validStagingCheck = completion.range(of: "Self.stagedFileSurvivesMoveFailure"),
      let responseCheck = completion.range(of: "downloadTask.response"),
      let move = completion.range(of: "try FileManager.default.moveItem(at: location, to: destination)"),
      let cleanup = completion.range(of: "if !self.processing.contains(id) && self.conversions[id] == nil {"),
      let moveFailure = completion.range(of: "await self.resolveDownloadCallbackFailure", range: move.upperBound..<completion.endIndex) else {
    fatalError("Download completion must preserve staging and reconcile failed moves")
}
precondition(validStagingCheck.lowerBound < responseCheck.lowerBound,
             "a duplicate response must yield to valid staging before validation")
precondition(!completion[..<cleanup.lowerBound].contains("removeItem(at: destination)"),
             "duplicate completion must not unlink an active decoder's input")
precondition(moveFailure.lowerBound > cleanup.lowerBound,
             "a failed move must reconcile current staging before marking a failure")

let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("mp3-shelf-duplicate-" + UUID().uuidString)
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let destination = root.appendingPathComponent("staged.mp3")
let original = Data([0x49, 0x44, 0x33, 0x03, 0x00, 0x00, 0x11])
let duplicate = Data([0x49, 0x44, 0x33, 0x04, 0x00, 0x00, 0x22])
try original.write(to: destination)
let secondCallback = root.appendingPathComponent("second.tmp")
try duplicate.write(to: secondCallback)
// A competing move must leave both the incoming and already staged files intact.
do {
    try fm.moveItem(at: secondCallback, to: destination)
    fatalError("A competing move must refuse an occupied destination")
} catch {
    precondition(fm.fileExists(atPath: secondCallback.path))
}
let preserved = try Data(contentsOf: destination)
precondition(preserved == original,
             "existing conversion input must survive a duplicate completion")
precondition(fm.fileExists(atPath: secondCallback.path),
             "duplicate callback's temporary file is left for URLSession cleanup")
try fm.removeItem(at: destination)
try fm.moveItem(at: secondCallback, to: destination)
let restaged = try Data(contentsOf: destination)
precondition(restaged == duplicate,
             "a later completion may stage audio after ownership ends")
print("PASS: duplicate completion preserves staged conversion input")
