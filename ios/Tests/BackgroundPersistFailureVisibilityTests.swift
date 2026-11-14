import Foundation

// Run from integrated candidate: swift ios/Tests/BackgroundPersistFailureVisibilityTests.swift
// Source-bound regression plus deterministic journal-write fault injection.
// This does not simulate URLSession or prove iPhone behavior.
func require(_ ok: Bool, _ why: String) {
    guard ok else { fputs("FAIL: \(why)\n", stderr); exit(1) }
}
let sourcePath = "ios/MP3Shelf/Services/BackgroundAudioDownloader.swift"
guard FileManager.default.fileExists(atPath: sourcePath) else {
    fputs("UNVERIFIED: native downloader source missing\n", stderr)
    exit(2)
}
let source = try String(contentsOfFile: sourcePath, encoding: .utf8)
guard let begin = source.range(of: "private func persist()"),
      let end = source.range(of: "private func updatePending()", range: begin.upperBound..<source.endIndex) else {
    fputs("FAIL: cannot locate native persistence helper\n", stderr)
    exit(1)
}
let helper = String(source[begin.lowerBound..<end.lowerBound])
require(!helper.contains("try? BackgroundTicketManifestPolicy.write"),
        "P0: persist() silently swallows a failed queue manifest write")

struct Ticket: Codable, Equatable {
    enum Status: String, Codable { case queued, imported }
    let id: UUID
    var status: Status
}
enum DiskFault: Error { case injected }
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("mp3shelf-persist-\(UUID())")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let journal = root.appendingPathComponent("tickets.json")
let audioA = root.appendingPathComponent("a.mp3")
let audioB = root.appendingPathComponent("b.mp3")
let bytesA = Data(repeating: 0x41, count: 8192)
let bytesB = Data(repeating: 0x42, count: 8192)
try bytesA.write(to: audioA)
try bytesB.write(to: audioB)
let initial = [Ticket(id: UUID(), status: .queued), Ticket(id: UUID(), status: .queued)]
try JSONEncoder().encode(initial).write(to: journal, options: .atomic)
var memory = initial
var acknowledged = false
func publish(_ proposed: [Ticket], fail: Bool) throws {
    if fail { throw DiskFault.injected }
    try JSONEncoder().encode(proposed).write(to: journal, options: .atomic)
    memory = proposed
    acknowledged = true
}
var terminal = initial
terminal[0].status = .imported
for _ in 0..<24 {
    do {
        try publish(terminal, fail: true)
        require(false, "Injected persistence failure was swallowed")
    } catch DiskFault.injected {}
    require(!acknowledged, "Failed write acknowledged completed transfer")
    require(memory == initial, "Failed write mutated in-memory queue")
    let recovered = try JSONDecoder().decode([Ticket].self, from: Data(contentsOf: journal))
    require(recovered == initial, "Failed write mutated durable queue")
    require(try Data(contentsOf: audioA) == bytesA, "Failed write removed first recording")
    require(try Data(contentsOf: audioB) == bytesB, "Failed write removed unrelated recording")
}
try publish(terminal, fail: false)
require(acknowledged, "Successful write not acknowledged")
let recovered = try JSONDecoder().decode([Ticket].self, from: Data(contentsOf: journal))
require(recovered == terminal, "Successful retry not durable after restart")
require(try Data(contentsOf: audioB) == bytesB, "Retry damaged unrelated audio")
print("PASS: production persistence source contract and 24 injected journal failures")
