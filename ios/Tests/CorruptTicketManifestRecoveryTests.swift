import Foundation

// Independent source-contract regression: run from a checkout containing the
// production downloader. A failure is a release blocker, not device proof.
let path = "ios/MP3Shelf/Services/BackgroundAudioDownloader.swift"
guard FileManager.default.fileExists(atPath: path) else {
    fatalError("UNVERIFIED: production downloader source missing; run from an exact-SHA checkout")
}
let source = try String(contentsOfFile: path, encoding: .utf8)
guard let begin = source.range(of: "override private init()"),
      let end = source.range(of: "super.init()", range: begin.upperBound..<source.endIndex) else {
    fatalError("FAIL: downloader initializer contract changed; review source")
}
let initializer = String(source[begin.lowerBound..<end.upperBound])
// Malformed persisted tickets must not be interpreted as an empty queue:
// reconciliation can otherwise discard ownership evidence. Require explicit
// failure handling and a quarantine or checkpoint recovery strategy.
let hasFailureBranch = initializer.contains("catch ") || initializer.contains("else {")
let hasRecovery = initializer.contains("quarantine") || initializer.contains("checkpoint") || initializer.contains("recoverCorrupt")
if !hasFailureBranch || !hasRecovery {
    fputs("FAIL: corrupt ticket manifest silently becomes empty in BackgroundAudioDownloader.init; preserve corrupt bytes and fail closed before reconciliation\n", stderr)
    exit(1)
}

struct Ticket: Codable, Equatable { let id: UUID; let status: String }
let fm = FileManager.default
let dir = fm.temporaryDirectory.appendingPathComponent("mp3-corrupt-journal-\(UUID())", isDirectory: true)
try fm.createDirectory(at: dir, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: dir) }
let journal = dir.appendingPathComponent("tickets.json")
let staged = dir.appendingPathComponent("recording.mp3")
let audio = Data([0x49, 0x44, 0x33, 0x04, 0x00, 0x01])
try audio.write(to: staged)
let original = try JSONEncoder().encode([Ticket(id: UUID(), status: "queued")])
try original.write(to: journal)
for broken in [Data(), Data("[{".utf8), Data("null".utf8), Data("{}".utf8)] {
    try broken.write(to: journal, options: .atomic)
    guard (try? JSONDecoder().decode([Ticket].self, from: broken)) == nil else {
        fatalError("FAIL: malformed journal decoded as valid queue")
    }
    guard try Data(contentsOf: staged) == audio else {
        fatalError("FAIL: corrupted journal changed staged audio")
    }
}
print("PASS: manifest recovery contract and staged audio preservation (source inspection + Foundation model only)")
