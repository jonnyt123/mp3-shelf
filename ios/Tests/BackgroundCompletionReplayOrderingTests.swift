import Foundation

// Run: swift ios/Tests/BackgroundCompletionReplayOrderingTests.swift
// Independent filesystem model: not a production URLSession integration test.
struct Entry: Codable, Equatable {
    enum State: String, Codable { case pending, importing, imported, cancelled }
    var id: String
    var state: State
    var filename: String
}
struct Snapshot: Codable {
    var entries: [Entry]
    var receipts: [String]
}
enum ReplayError: Error { case corrupt, missing, conflict, unsafe, interrupted }
func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw NSError(domain: "ReplayQA", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("mp3-replay-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let journal = root.appendingPathComponent("journal.json")
let stage = root.appendingPathComponent("stage.mp3")
let dest = root.appendingPathComponent("song.mp3")
let other = root.appendingPathComponent("other.mp3")
let original = Data((0..<32768).map { UInt8(($0 * 17 + 9) % 251) })
let unrelated = Data((0..<32768).map { UInt8(($0 * 11 + 3) % 251) })
try unrelated.write(to: other)
func safeJournal() -> Bool {
    guard (try? fm.destinationOfSymbolicLink(atPath: journal.path)) == nil,
          let attributes = try? fm.attributesOfItem(atPath: journal.path),
          attributes[.type] as? FileAttributeType == .typeRegular,
          (attributes[.referenceCount] as? NSNumber)?.intValue == 1 else { return false }
    return true
}
func load() throws -> Snapshot {
    guard safeJournal() else { throw ReplayError.corrupt }
    // A hostile or damaged manifest must not allocate unbounded memory on relaunch.
    let attributes = try fm.attributesOfItem(atPath: journal.path)
    guard let bytes = (attributes[.size] as? NSNumber)?.int64Value,
          bytes > 0 && bytes <= 1_048_576 else { throw ReplayError.corrupt }
    guard let value = try? JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: journal)) else { throw ReplayError.corrupt }
    guard value.entries.count <= 256, value.receipts.count <= 256 else { throw ReplayError.corrupt }
    let ids = value.entries.map(\.id)
    // Reject ambiguous or escaping destinations before any replay operation.
    // A corrupt journal must not turn an unrelated file into a ticket's audio.
    let names = value.entries.map(\.filename)
    let canonicalNames = names.map {
        $0.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    // Portable destinations can alias across Unicode normalization and case folding.
    guard Set(ids).count == ids.count, Set(names).count == names.count,
          Set(canonicalNames).count == canonicalNames.count,
          value.entries.allSatisfy({ entry in
              !entry.id.isEmpty && !entry.filename.isEmpty &&
              entry.filename != "." && entry.filename != ".." &&
              !entry.filename.contains("/") && !entry.filename.contains("\\") &&
              !entry.filename.contains("\0") &&
              !entry.filename.hasPrefix(".") &&
              !entry.filename.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) &&
              !entry.filename.hasSuffix(" ") && !entry.filename.hasSuffix(".") &&
              !["CON", "PRN", "AUX", "NUL", "COM1", "LPT1"].contains(entry.filename.split(separator: ".").first.map(String.init)?.uppercased() ?? "")
          }),
          Set(value.receipts).count == value.receipts.count,
          value.receipts.allSatisfy({ id in value.entries.contains { $0.id == id && $0.state == .imported } }),
          value.entries.allSatisfy({ $0.state != .imported || value.receipts.contains($0.id) }) else { throw ReplayError.corrupt }
    return value
}
func save(_ value: Snapshot, interrupted: Bool = false) throws {
    if interrupted { throw ReplayError.interrupted }
    guard (try? fm.destinationOfSymbolicLink(atPath: journal.path)) == nil,
          (safeJournal() || !fm.fileExists(atPath: journal.path)) else { throw ReplayError.unsafe }
    try JSONEncoder().encode(value).write(to: journal, options: .atomic)
}
// Validate the directory entry before reading: a terminal receipt must never
// authorize a missing, foreign or symlink-substituted recording after restart.
func verifiedRecording(_ url: URL) throws -> Bool {
    if (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil {
        throw ReplayError.unsafe
    }
    let attributes: [FileAttributeKey: Any]
    do { attributes = try fm.attributesOfItem(atPath: url.path) }
    catch { return false }
    guard attributes[.type] as? FileAttributeType == .typeRegular,
          (attributes[.referenceCount] as? NSNumber)?.intValue == 1 else {
        throw ReplayError.unsafe
    }
    guard (attributes[.size] as? NSNumber)?.intValue == original.count,
          try Data(contentsOf: url) == original else { throw ReplayError.conflict }
    return true
}
func complete(interruptTerminal: Bool = false) throws {
    var snapshot = try load()
    guard let index = snapshot.entries.firstIndex(where: { $0.id == "ticket" }) else { throw ReplayError.corrupt }
    if snapshot.entries[index].state == .imported {
        guard snapshot.entries[index].filename == dest.lastPathComponent else { throw ReplayError.conflict }
        guard try verifiedRecording(dest) else { throw ReplayError.missing }
        return
    }
    guard snapshot.entries[index].state == .pending || snapshot.entries[index].state == .importing else { return }
    // The replay destination must come from the validated durable ticket, not a
    // caller-supplied path that could disagree with the journal after restart.
    guard snapshot.entries[index].filename == dest.lastPathComponent else { throw ReplayError.conflict }
    let stagedExists = try verifiedRecording(stage)
    let destinationExists = try verifiedRecording(dest)
    guard stagedExists || (snapshot.entries[index].state == .importing && destinationExists) else { throw ReplayError.missing }
    if snapshot.entries[index].state == .pending {
        snapshot.entries[index].state = .importing
        try save(snapshot)
    }
    if !destinationExists { try fm.copyItem(at: stage, to: dest) }
    snapshot.entries[index].state = .imported
    snapshot.receipts.append("ticket")
    try save(snapshot, interrupted: interruptTerminal)
}
for round in 0..<48 {
    if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
    try original.write(to: stage, options: .atomic)
    try save(Snapshot(entries: [
        Entry(id: "ticket", state: .pending, filename: "song.mp3"),
        Entry(id: "cancelled", state: .cancelled, filename: "cancelled.mp3")
    ], receipts: []))
    do { try complete(interruptTerminal: true); try check(false, "interrupted commit succeeded") }
    catch ReplayError.interrupted {}
    try check(try load().entries[0].state == .importing, "pending state lost")
    try check(try Data(contentsOf: dest) == original, "copied recording lost")
    // Simulate process death, including lost temporary URLSession staging.
    if round % 3 == 0 { try fm.removeItem(at: stage) }
    try complete()
    if fm.fileExists(atPath: stage.path) { try fm.removeItem(at: stage) }
    try complete() // late duplicate after stage cleanup must be idempotent
    let result = try load()
    try check(result.receipts == ["ticket"], "duplicate receipt")
    try check(result.entries[1].state == .cancelled, "cancelled ticket changed")
    try check(try Data(contentsOf: dest) == original, "recording mutated")
    try check(try Data(contentsOf: other) == unrelated, "unrelated audio mutated")
    if round % 2 == 0 {
        let valid = try Data(contentsOf: journal)
        try Data("{bad".utf8).write(to: journal, options: .atomic)
        do { try complete(); try check(false, "corrupt journal accepted") }
        catch ReplayError.corrupt {}
        try valid.write(to: journal, options: .atomic)
    }
}
// Corrupt replay metadata must not redirect a ticket to another recording,
// collapse two tickets onto one destination, or escape the audio directory.
// Each rejected journal is restored without modifying any existing media.
let invalidSnapshots: [Snapshot] = [
    Snapshot(entries: [Entry(id: "ticket", state: .pending, filename: "../other.mp3")], receipts: []),
    Snapshot(entries: [Entry(id: "ticket", state: .pending, filename: "/tmp/other.mp3")], receipts: []),
    Snapshot(entries: [Entry(id: "ticket", state: .pending, filename: "..\\other.mp3")], receipts: []),
    Snapshot(entries: [Entry(id: "ticket", state: .pending, filename: ".hidden.mp3")], receipts: []),
    Snapshot(entries: [Entry(id: "ticket", state: .pending, filename: "song.mp3"),
                       Entry(id: "second", state: .pending, filename: "song.mp3")], receipts: []),
    Snapshot(entries: [Entry(id: "ticket", state: .pending, filename: "song.mp3"),
                       Entry(id: "ticket", state: .pending, filename: "second.mp3")], receipts: []),
    Snapshot(entries: [Entry(id: "ticket", state: .pending, filename: "Song.mp3"),
                       Entry(id: "second", state: .pending, filename: "song.mp3")], receipts: []),
    Snapshot(entries: [Entry(id: "ticket", state: .pending, filename: "café.mp3"),
                       Entry(id: "second", state: .pending, filename: "cafe\u{301}.mp3")], receipts: []),
    Snapshot(entries: [Entry(id: "ticket", state: .pending, filename: "MUSIC.mp3"),
                       Entry(id: "second", state: .pending, filename: "music.mp3")], receipts: []),
    Snapshot(entries: [Entry(id: "", state: .pending, filename: "song.mp3")], receipts: []),
    Snapshot(entries: [Entry(id: "ticket", state: .pending, filename: "other.mp3")], receipts: []),
    Snapshot(entries: [Entry(id: "ticket", state: .pending, filename: "song.mp3\\n")], receipts: []),
    Snapshot(entries: [Entry(id: "ticket", state: .pending, filename: "song.mp3 ")], receipts: []),
    Snapshot(entries: [Entry(id: "ticket", state: .pending, filename: "CON.mp3")], receipts: [])
]
let validBeforeCorruption = try Data(contentsOf: journal)
let audioBeforeCorruption = try Data(contentsOf: other)
for invalid in invalidSnapshots {
    try JSONEncoder().encode(invalid).write(to: journal, options: .atomic)
    do { try complete(); try check(false, "unsafe replay metadata accepted") }
    catch ReplayError.corrupt {}
    catch ReplayError.conflict {}
    try check(try Data(contentsOf: other) == audioBeforeCorruption,
              "unsafe journal modified unrelated audio")
    try validBeforeCorruption.write(to: journal, options: .atomic)
}
try check(try Data(contentsOf: journal) == validBeforeCorruption,
          "valid replay checkpoint not restored")

// A corrupt or adversarially large checkpoint must fail before replay or
// terminal-state publication, without touching any audio or replacing the
// previous valid checkpoint. These cases are deliberately much larger than
// the ordinary two-ticket fixture and exercise bounded parsing.
let sizeCheckpoint = try Data(contentsOf: journal)
let sizeAudioCheckpoint = try Data(contentsOf: other)
let oversizedPayload = Data(repeating: 0x20, count: 1_048_577)
try oversizedPayload.write(to: journal, options: .atomic)
do { try complete(); try check(false, "oversized manifest accepted") }
catch ReplayError.corrupt {}
try check(try Data(contentsOf: other) == sizeAudioCheckpoint, "oversized manifest touched audio")
let excessiveEntries = Snapshot(entries: (0..<257).map { Entry(id: "ticket-\($0)", state: .pending, filename: "file-\($0).mp3") }, receipts: [])
try JSONEncoder().encode(excessiveEntries).write(to: journal, options: .atomic)
do { try complete(); try check(false, "excessive ticket count accepted") }
catch ReplayError.corrupt {}
try check(try Data(contentsOf: other) == sizeAudioCheckpoint, "excessive tickets touched audio")
try sizeCheckpoint.write(to: journal, options: .atomic)
try complete()
try check(try Data(contentsOf: journal) == sizeCheckpoint, "size rejection lost valid checkpoint")

// Boundary and hostile-structure checks: a bounded journal may contain a
// legitimate maximum-sized queue, but must not permit an oversized receipt
// array, zero-length input, or malformed/truncated JSON to publish a ticket.
let boundaryEntries = (0..<256).map {
    Entry(id: "boundary-\($0)", state: .pending, filename: "boundary-\($0).mp3")
}
let boundaryReceipts: [String] = []
try save(Snapshot(entries: boundaryEntries, receipts: boundaryReceipts))
try check(try load().entries.count == 256, "maximum valid queue rejected")
let boundaryJournal = try Data(contentsOf: journal)
let boundaryAudio = try Data(contentsOf: other)
func expectCorruptJournal(_ bytes: Data, _ reason: String) throws {
    try bytes.write(to: journal, options: .atomic)
    do { _ = try load(); try check(false, reason) }
    catch ReplayError.corrupt {}
    try check(try Data(contentsOf: other) == boundaryAudio, "invalid journal changed unrelated audio")
    try check(try Data(contentsOf: dest) == original, "invalid journal changed saved recording")
    try boundaryJournal.write(to: journal, options: .atomic)
    try check(try load().entries.count == 256, "invalid journal damaged recoverable queue")
}
try expectCorruptJournal(Data(), "empty journal accepted")
try expectCorruptJournal(Data("{".utf8), "truncated journal accepted")
try expectCorruptJournal(Data(repeating: 0x20, count: 1_048_576), "maximum-size malformed journal accepted")
let excessiveReceipts = Snapshot(entries: boundaryEntries, receipts: (0..<257).map { "boundary-\($0)" })
try expectCorruptJournal(try JSONEncoder().encode(excessiveReceipts), "excessive receipts accepted")
let duplicateReceipts = Snapshot(entries: [Entry(id: "ticket", state: .imported, filename: "song.mp3")], receipts: ["ticket", "ticket"])
try expectCorruptJournal(try JSONEncoder().encode(duplicateReceipts), "duplicate receipts accepted")
let orphanReceipts = Snapshot(entries: boundaryEntries, receipts: ["missing-ticket"])
try expectCorruptJournal(try JSONEncoder().encode(orphanReceipts), "orphan receipt accepted")
try sizeCheckpoint.write(to: journal, options: .atomic)
try complete()
try check(try Data(contentsOf: journal) == sizeCheckpoint, "boundary test changed prior durable checkpoint")

// A persisted terminal receipt must not mask deletion, substitution, or a
// symlink introduced between launches. Invalid files must remain untouched.
try save(Snapshot(entries: [Entry(id: "ticket", state: .imported, filename: "song.mp3")],
                  receipts: ["ticket"]))
try original.write(to: dest, options: .atomic)
try complete()
try fm.removeItem(at: dest)
do { try complete(); try check(false, "terminal receipt accepted missing audio") }
catch ReplayError.missing {}
try unrelated.write(to: dest, options: .atomic)
do { try complete(); try check(false, "terminal receipt accepted foreign audio") }
catch ReplayError.conflict {}
try fm.removeItem(at: dest)
try fm.createSymbolicLink(at: dest, withDestinationURL: other)
do { try complete(); try check(false, "terminal receipt accepted symlink") }
catch ReplayError.unsafe {}
try fm.removeItem(at: dest)
try fm.createDirectory(at: dest, withIntermediateDirectories: false)
do { try complete(); try check(false, "terminal receipt accepted directory") }
catch ReplayError.unsafe {}
try fm.removeItem(at: dest)
try check(try load().receipts == ["ticket"], "invalid terminal check rewrote receipt")
try check(try Data(contentsOf: other) == unrelated, "foreign target modified")
try original.write(to: dest, options: .atomic)
try complete()
try check(try load().receipts == ["ticket"], "recovery duplicated receipt")
try fm.removeItem(at: dest)
// Neither absent nor foreign destination bytes can authorize a receipt.
try save(Snapshot(entries: [Entry(id: "ticket", state: .importing, filename: "song.mp3")], receipts: []))
if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
do { try complete(); try check(false, "missing destination accepted") }
catch ReplayError.missing {}
try check(try load().receipts.isEmpty, "missing audio published receipt")
try Data("foreign recording".utf8).write(to: dest, options: .atomic)
do { try complete(); try check(false, "foreign destination accepted") }
catch ReplayError.conflict {}
try check(try load().receipts.isEmpty, "foreign audio published receipt")
try check(try Data(contentsOf: dest) == Data("foreign recording".utf8), "foreign audio modified")
// Journal entry substitution must fail closed without touching an external
// target or changing durable completion state.
try original.write(to: dest, options: .atomic)
try save(Snapshot(entries: [Entry(id: "ticket", state: .imported, filename: "song.mp3")],
                  receipts: ["ticket"]))
let trustedJournal = try Data(contentsOf: journal)
let outsideJournal = root.appendingPathComponent("outside-journal.json")
try trustedJournal.write(to: outsideJournal, options: .atomic)
try fm.removeItem(at: journal)
try fm.createSymbolicLink(at: journal, withDestinationURL: outsideJournal)
do { try complete(); try check(false, "symlink journal accepted") }
catch ReplayError.corrupt {}
do { try save(Snapshot(entries: [], receipts: [])); try check(false, "symlink journal overwritten") }
catch ReplayError.unsafe {}
try check(try Data(contentsOf: outsideJournal) == trustedJournal, "symlink target changed")
try fm.removeItem(at: journal)
try fm.createSymbolicLink(atPath: journal.path, withDestinationPath: root.appendingPathComponent("missing-journal").path)
do { try save(Snapshot(entries: [], receipts: [])); try check(false, "dangling symlink journal overwritten") }
catch ReplayError.unsafe {}
try fm.removeItem(at: journal)
try fm.linkItem(at: outsideJournal, to: journal)
do { try complete(); try check(false, "hard-linked journal accepted") }
catch ReplayError.corrupt {}
do { try save(Snapshot(entries: [], receipts: [])); try check(false, "hard-linked journal overwritten") }
catch ReplayError.unsafe {}
try check(try Data(contentsOf: outsideJournal) == trustedJournal, "hard-link target changed")
try fm.removeItem(at: journal)
try trustedJournal.write(to: journal, options: .atomic)
try complete()
try fm.removeItem(at: dest)
try fm.linkItem(at: other, to: dest)
do { try complete(); try check(false, "hard-linked foreign destination accepted") }
catch ReplayError.unsafe {}
try check(try Data(contentsOf: other) == unrelated, "hard-linked audio target changed")
try fm.removeItem(at: dest)
try original.write(to: dest, options: .atomic)
try complete()
try check(try Data(contentsOf: journal) == trustedJournal, "valid journal changed during recovery")

// Staged files are untrusted: a pending ticket must not follow a link,
// import a directory, or accept foreign audio after a process restart.
try save(Snapshot(entries: [Entry(id: "ticket", state: .pending, filename: "song.mp3")], receipts: []))
let stageCheckpoint = try Data(contentsOf: journal)
try fm.removeItem(at: dest)
if fm.fileExists(atPath: stage.path) { try fm.removeItem(at: stage) }
let externalStage = root.appendingPathComponent("external-stage.mp3")
try original.write(to: externalStage, options: .atomic)
try fm.createSymbolicLink(at: stage, withDestinationURL: externalStage)
do { try complete(); try check(false, "symlink stage accepted") }
catch ReplayError.unsafe {}
try check(try Data(contentsOf: journal) == stageCheckpoint, "symlink stage changed checkpoint")
try check(!fm.fileExists(atPath: dest.path), "symlink stage created recording")
try fm.removeItem(at: stage)
try fm.linkItem(at: externalStage, to: stage)
do { try complete(); try check(false, "hard-linked stage accepted") }
catch ReplayError.unsafe {}
try check(try Data(contentsOf: journal) == stageCheckpoint, "hard-linked stage changed checkpoint")
try fm.removeItem(at: stage)
try fm.createDirectory(at: stage, withIntermediateDirectories: false)
do { try complete(); try check(false, "directory stage accepted") }
catch ReplayError.unsafe {}
try check(try Data(contentsOf: journal) == stageCheckpoint, "directory stage changed checkpoint")
try fm.removeItem(at: stage)
try unrelated.write(to: stage, options: .atomic)
do { try complete(); try check(false, "foreign staged bytes accepted") }
catch ReplayError.conflict {}
try check(try Data(contentsOf: journal) == stageCheckpoint, "foreign stage changed checkpoint")
try check(!fm.fileExists(atPath: dest.path), "foreign stage created recording")
try check(try Data(contentsOf: other) == unrelated, "foreign stage mutated unrelated audio")
try check(try Data(contentsOf: externalStage) == original, "external stage mutated")
try original.write(to: stage, options: .atomic)
try complete()
try check(try Data(contentsOf: dest) == original, "valid retry did not recover audio")
try check(try load().receipts == ["ticket"], "valid retry did not publish one receipt")

// Reject terminal-state/receipt disagreement before replay. These are realistic
// interrupted or manually corrupted checkpoint shapes, not recoverable tickets.
let terminalMismatchCases: [Snapshot] = [
    Snapshot(entries: [Entry(id: "ticket", state: .imported, filename: "song.mp3")], receipts: []),
    Snapshot(entries: [Entry(id: "ticket", state: .cancelled, filename: "song.mp3")], receipts: ["ticket"]),
    Snapshot(entries: [Entry(id: "ticket", state: .pending, filename: "song.mp3")], receipts: ["ticket"]),
    Snapshot(entries: [Entry(id: "ticket", state: .importing, filename: "song.mp3")], receipts: ["ticket"]),
    Snapshot(entries: [Entry(id: "ticket", state: .imported, filename: "song.mp3")], receipts: ["ticket", "ticket"]),
    Snapshot(entries: [Entry(id: "ticket", state: .imported, filename: "song.mp3")], receipts: ["unknown"])
]
for (index, invalid) in terminalMismatchCases.enumerated() {
    try JSONEncoder().encode(invalid).write(to: journal, options: .atomic)
    let invalidBytes = try Data(contentsOf: journal)
    do { try complete(); try check(false, "terminal mismatch \(index) accepted") }
    catch ReplayError.corrupt {}
    try check(try Data(contentsOf: journal) == invalidBytes,
              "terminal mismatch \(index) rewrote corrupt journal")
    try check(try Data(contentsOf: dest) == original,
              "terminal mismatch \(index) changed owned recording")
    try check(try Data(contentsOf: other) == unrelated,
              "terminal mismatch \(index) changed unrelated recording")
}
try trustedJournal.write(to: journal, options: .atomic)
try complete()
try check(try Data(contentsOf: journal) == trustedJournal,
          "terminal mismatch recovery did not preserve valid checkpoint")


print("PASS: 48 crash/replay rounds (16 without staging), 48 duplicates, 24 corrupt journals, terminal receipt integrity and unsafe path rejection")
