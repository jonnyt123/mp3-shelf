import Foundation

// Run from repository root: swift ios/Tests/BackgroundLateErrorTests.swift
// Source contract plus deterministic staged-file precedence fixture.
// Real URLSession delegate ordering and iPhone background execution remain unverified.
let path = "ios/MP3Shelf/Services/BackgroundAudioDownloader.swift"
let source = try String(contentsOfFile: path, encoding: .utf8)
guard let start = source.range(of: "nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,\n                                didCompleteWithError error: Error?)"),
      let finish = source.range(of: "nonisolated func urlSessionDidFinishEvents", range: start.upperBound..<source.endIndex) else {
    fatalError("Background completion callbacks missing")
}
let callback = String(source[start.lowerBound..<finish.lowerBound])
guard let queued = callback.range(of: "guard self.tickets[id]?.status == .queued else { return }"),
      let staged = callback.range(of: "if self.fm.fileExists(atPath: Self.stagingURL(id).path) {"),
      let recover = callback.range(of: "await self.recoverStagedDownloads()"),
      let retry = callback.range(of: "self.retryTemporaryTransfer(id,"),
      let fail = callback.range(of: "self.setFailed(id,") else {
    fatalError("Late-error recovery contract missing")
}
precondition(queued.lowerBound < staged.lowerBound)
precondition(staged.lowerBound < recover.lowerBound)
precondition(recover.lowerBound < retry.lowerBound)
precondition(recover.lowerBound < fail.lowerBound)

let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("mp3-shelf-late-error-" + UUID().uuidString)
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let stagedFile = root.appendingPathComponent("complete.mp3")
let completeAudio = Data([0x49, 0x44, 0x33, 0x04, 0x00, 0x00, 0x01])
try completeAudio.write(to: stagedFile)
func disposition(queued: Bool, staged: Bool) -> String {
    guard queued else { return "ignore" }
    if staged { return "recover" }
    return "retry-or-fail"
}
precondition(disposition(queued: true, staged: fm.fileExists(atPath: stagedFile.path)) == "recover")
precondition(try Data(contentsOf: stagedFile) == completeAudio)
precondition(disposition(queued: false, staged: true) == "ignore")
try fm.removeItem(at: stagedFile)
precondition(disposition(queued: true, staged: fm.fileExists(atPath: stagedFile.path)) == "retry-or-fail")
print("PASS: late URLSession error cannot override completed staging")
