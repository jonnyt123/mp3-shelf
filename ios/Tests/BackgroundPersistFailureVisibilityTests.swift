import Foundation

// Run from repo root: swift ios/Tests/BackgroundPersistFailureVisibilityTests.swift --fixture-only
// Without --fixture-only, also enforce the production downloader source contract.
// No URLSession, simulator, or physical-device behavior is asserted.
func require(_ ok: Bool, _ why: String) {
    guard ok else { fputs("FAIL: \(why)\n", stderr); exit(1) }
}
struct Ticket: Codable, Equatable {
    enum Status: String, Codable { case queued, imported }
    let id: UUID
    var status: Status
}
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("mp3shelf-persist-\(UUID().uuidString)")
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
let encoder = JSONEncoder()
let decoder = JSONDecoder()
try encoder.encode(initial).write(to: journal, options: .atomic)
var memory = initial
var acknowledged = false
func publish(_ proposed: [Ticket], at destination: URL) throws {
    // Exercise actual Foundation atomic publication, not a simulated error flag.
    try encoder.encode(proposed).write(to: destination, options: .atomic)
    memory = proposed
    acknowledged = true
}
var terminal = initial
terminal[0].status = .imported

// Directory collision is deterministic even when the runner has root permissions.
// Failed writes must not acknowledge completion or alter the durable queue/audio.
let blocked = root.appendingPathComponent("blocked-manifest")
try fm.createDirectory(at: blocked, withIntermediateDirectories: false)
let sentinel = blocked.appendingPathComponent("keep.txt")
try Data("sentinel".utf8).write(to: sentinel)
for attempt in 0..<32 {
    var failed = false
    do {
        try publish(terminal, at: blocked)
    } catch {
        failed = true
    }
    require(failed, "directory write barrier unexpectedly succeeded on attempt \(attempt)")
    require(!acknowledged, "failed publication acknowledged completed transfer")
    require(memory == initial, "failed publication mutated in-memory queue")
    require(try decoder.decode([Ticket].self, from: Data(contentsOf: journal)) == initial,
            "failed publication changed durable queue")
    require(try Data(contentsOf: sentinel) == Data("sentinel".utf8), "barrier directory replaced")
    require(try Data(contentsOf: audioA) == bytesA, "failed publication lost first recording")
    require(try Data(contentsOf: audioB) == bytesB, "failed publication lost unrelated recording")
}
// Retry after clearing the barrier and simulate restart from the persisted manifest.
try fm.removeItem(at: blocked)
try publish(terminal, at: journal)
require(acknowledged && memory == terminal, "successful retry not acknowledged")
require(try decoder.decode([Ticket].self, from: Data(contentsOf: journal)) == terminal,
        "successful retry not durable after restart")
require(try Data(contentsOf: audioA) == bytesA && Data(contentsOf: audioB) == bytesB,
        "retry damaged staged recordings")
print("PASS: 32 real filesystem write failures, two-track preservation, durable retry (Foundation fixture)")
if !CommandLine.arguments.contains("--fixture-only") {
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


print("PASS: production persistence source contract (static inspection only)")
}

