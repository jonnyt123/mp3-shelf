import Foundation

// Standalone fault-injection model. Run: swift ios/Tests/ManifestWriteBarrierTests.swift
// This does NOT exercise the production downloader; production must independently
// enforce the same write barrier before this can be treated as a release gate.
struct Ticket: Codable, Equatable { let id: UUID; let state: String }
enum ManifestState: Equatable { case missing, valid([Ticket]), corrupt }
enum ManifestError: Error { case corruptExistingJournal, injectedWriteFailure }

struct JournalStore {
    let url: URL
    func read() throws -> ManifestState {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        let bytes = try Data(contentsOf: url)
        guard let entries = try? JSONDecoder().decode([Ticket].self, from: bytes),
              Set(entries.map(\.id)).count == entries.count else { return .corrupt }
        return .valid(entries)
    }
    func save(_ entries: [Ticket], failBeforeCommit: Bool = false) throws {
        guard try read() != .corrupt else { throw ManifestError.corruptExistingJournal }
        guard Set(entries.map(\.id)).count == entries.count else { throw ManifestError.corruptExistingJournal }
        let bytes = try JSONEncoder().encode(entries)
        if failBeforeCommit { throw ManifestError.injectedWriteFailure }
        try bytes.write(to: url, options: .atomic)
    }
}

func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { fatalError(message) }
}
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("mp3shelf-journal-barrier-\(UUID())")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let url = root.appendingPathComponent("background-audio-tickets.json")
let audioURL = root.appendingPathComponent("staged.mp3")
let audio = Data([0x49,0x44,0x33,0x04,0x00,0x00,0x7f,0xff])
try audio.write(to: audioURL, options: .atomic)
let store = JournalStore(url: url)
let a = Ticket(id: UUID(), state: "queued")
let b = Ticket(id: UUID(), state: "queued")
try check(store.read() == .missing, "Missing journal must be distinguishable")
try store.save([a,b])
try check(store.read() == .valid([a,b]), "Initial durable queue missing")
let original = try Data(contentsOf: url)
do { try store.save([a], failBeforeCommit: true); fatalError("Injected failure unexpectedly committed") }
catch ManifestError.injectedWriteFailure { }
try check(Data(contentsOf: url) == original, "Failed save replaced durable queue")
for corrupt in [Data(), Data("null".utf8), Data("[{".utf8), try JSONEncoder().encode([a,a])] {
    try corrupt.write(to: url, options: .atomic)
    let before = try Data(contentsOf: url)
    try check(store.read() == .corrupt, "Corruption was accepted")
    do { try store.save([b]); fatalError("Corrupt manifest overwritten") }
    catch ManifestError.corruptExistingJournal { }
    try check(Data(contentsOf: url) == before, "Recovery evidence overwritten")
    try check(Data(contentsOf: audioURL) == audio, "Staged audio modified")
    try check(JournalStore(url: url).read() == .corrupt, "Relaunch lost corruption state")
}
try original.write(to: url, options: .atomic)
try store.save([a])
try check(JournalStore(url: url).read() == .valid([a]), "Repair then retry failed")
try check(Data(contentsOf: audioURL) == audio, "Retry modified staged audio")
print("PASS: manifest write barrier model — failure, corruption, duplicate IDs, relaunch, repair, audio bytes")
