import Foundation

// swift ios/Tests/CompletionCrashWindowMatrixTests.swift --fixture-only
// Reference-model crash injection; does not execute production URLSession or importer.
struct CrashTicket: Codable, Equatable {
    enum State: String, Codable { case queued, importing, imported, cancelled }
    let id: UUID
    var state: State
}
struct CrashJournal: Codable {
    var tickets: [CrashTicket]
    var receipts: Set<UUID>
}
enum CrashPoint: Error { case afterCopy, beforeReceipt, afterReceipt }
enum JournalWriteFault: Error { case injected }
func ensure(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { fatalError("FAIL: \(message)") }
}
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("mp3-crash-matrix-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let staged = root.appendingPathComponent("staged.mp3")
let unrelated = root.appendingPathComponent("unrelated.mp3")
let imported = root.appendingPathComponent("library.mp3")
let journal = root.appendingPathComponent("tickets.json")
let bytes = Data((0..<131072).map { UInt8(($0 * 17 + 31) % 251) })
let otherBytes = Data((0..<131072).map { UInt8(($0 * 11 + 7) % 251) })
try bytes.write(to: staged)
try otherBytes.write(to: unrelated)
let primary = UUID(), retired = UUID(), other = UUID()
let initial = CrashJournal(tickets: [
    CrashTicket(id: primary, state: .queued),
    CrashTicket(id: retired, state: .cancelled),
    CrashTicket(id: other, state: .queued)
], receipts: [])
var failNextReceiptPublication = false
func publish(_ value: CrashJournal) throws {
    // Inject a failure at the actual receipt publication boundary, after the
    // library copy exists but before the terminal state becomes durable.
    if failNextReceiptPublication && value.receipts.contains(primary) {
        failNextReceiptPublication = false
        throw JournalWriteFault.injected
    }
    try JSONEncoder().encode(value).write(to: journal, options: .atomic)
}
enum RecoveryValidationError: Error {
    case duplicateTicket, orphanReceipt, nonterminalReceipt, importedWithoutReceipt
}
func recover() throws -> CrashJournal {
    let decoded = try JSONDecoder().decode(CrashJournal.self, from: Data(contentsOf: journal))
    let ids = decoded.tickets.map(\.id)
    guard Set(ids).count == ids.count else { throw RecoveryValidationError.duplicateTicket }
    let byID = Dictionary(uniqueKeysWithValues: decoded.tickets.map { ($0.id, $0.state) })
    for receipt in decoded.receipts {
        guard let state = byID[receipt] else { throw RecoveryValidationError.orphanReceipt }
        guard state == .imported else { throw RecoveryValidationError.nonterminalReceipt }
    }
    guard !decoded.tickets.contains(where: { $0.state == .imported && !decoded.receipts.contains($0.id) }) else {
        throw RecoveryValidationError.importedWithoutReceipt
    }
    return decoded
}
var acknowledged = 0
func complete(_ id: UUID, crash: CrashPoint? = nil) throws {
    var state = try recover()
    guard id == primary,
          let index = state.tickets.firstIndex(where: { $0.id == id }),
          state.tickets[index].state != .imported,
          state.tickets[index].state != .cancelled,
          !state.receipts.contains(id) else { return }
    if state.tickets[index].state == .queued {
        state.tickets[index].state = .importing
        try publish(state)
    }
    try ensure(Data(contentsOf: staged) == bytes, "staged source modified")
    try bytes.write(to: imported, options: .atomic)
    if crash == .afterCopy { throw CrashPoint.afterCopy }
    state = try recover()
    try ensure(state.tickets[index].state == .importing, "replay lost importing state")
    if crash == .beforeReceipt { throw CrashPoint.beforeReceipt }
    state.tickets[index].state = .imported
    state.receipts.insert(id)
    try publish(state)
    if crash == .afterReceipt { throw CrashPoint.afterReceipt }
    acknowledged += 1
}
for point in [CrashPoint.afterCopy, .beforeReceipt, .afterReceipt] {
    try publish(initial)
    if fm.fileExists(atPath: imported.path) { try fm.removeItem(at: imported) }
    acknowledged = 0
    do {
        try complete(primary, crash: point)
        fatalError("injected crash not reached")
    } catch let actual as CrashPoint {
        try ensure(actual == point, "wrong injected crash")
    }
    let interrupted = try recover()
    try ensure(interrupted.tickets[1].state == .cancelled &&
               interrupted.tickets[2].state == .queued, "other tickets modified")
    for _ in 0..<64 { try complete(retired) }
    for _ in 0..<64 { try complete(primary) }
    let restored = try recover()
    try ensure(restored.receipts == Set([primary]), "receipt duplicated or lost")
    try ensure(restored.tickets[0].state == .imported, "terminal state not durable")
    try ensure(acknowledged <= 1, "completion acknowledged more than once")
    try ensure(Data(contentsOf: imported) == bytes, "library bytes damaged")
    try ensure(Data(contentsOf: staged) == bytes &&
               Data(contentsOf: unrelated) == otherBytes, "user audio damaged")
}
// The import copy may already exist when durable receipt publication fails.
// Retrying must recover from the importing journal, preserve the audio bytes,
// and publish exactly one receipt without acknowledging the failed attempt.
for iteration in 0..<32 {
    try publish(initial)
    if fm.fileExists(atPath: imported.path) { try fm.removeItem(at: imported) }
    acknowledged = 0
    failNextReceiptPublication = true
    var rejected = false
    do {
        try complete(primary)
    } catch JournalWriteFault.injected {
        rejected = true
    }
    try ensure(rejected, "receipt write failure not propagated at iteration \\(iteration)")
    let interrupted = try recover()
    try ensure(interrupted.tickets[0].state == .importing && interrupted.receipts.isEmpty,
               "failed receipt write published terminal state")
    try ensure(acknowledged == 0, "failed receipt write acknowledged completion")
    try ensure(Data(contentsOf: imported) == bytes, "failed receipt write damaged copied audio")
    try ensure(Data(contentsOf: staged) == bytes && Data(contentsOf: unrelated) == otherBytes,
               "failed receipt write damaged staged or unrelated audio")
    try complete(primary)
    for _ in 0..<16 { try complete(primary) }
    let resumed = try recover()
    try ensure(resumed.tickets[0].state == .imported && resumed.receipts == Set([primary]),
               "retry failed to durably publish exactly one completion receipt")
    try ensure(acknowledged == 1, "retry acknowledged completion more than once")
    try ensure(Data(contentsOf: imported) == bytes, "retry damaged imported audio")
}
// A corrupt persisted receipt journal is not an empty queue. Completion must
// fail closed, preserve the exact corrupt evidence, and leave audio untouched.
// Test actual decoder failures rather than inventing a successful recovery.
let validJournal = try Data(contentsOf: journal)
let validImported = try Data(contentsOf: imported)
let invalidJournals: [Data] = [
    Data("{".utf8),
    Data("null".utf8),
    Data("{\"tickets\":[],\"receipts\":\"invalid\"}".utf8)
]
for (index, invalid) in invalidJournals.enumerated() {
    try invalid.write(to: journal, options: .atomic)
    var rejected = false
    do {
        try complete(primary)
    } catch is DecodingError {
        rejected = true
    }
    try ensure(rejected, "corrupt receipt journal accepted in case \(index)")
    try ensure(Data(contentsOf: journal) == invalid,
               "corrupt receipt evidence overwritten in case \(index)")
    try ensure(Data(contentsOf: imported) == validImported,
               "corrupt receipt recovery damaged imported audio in case \(index)")
    try ensure(Data(contentsOf: staged) == bytes &&
               Data(contentsOf: unrelated) == otherBytes,
               "corrupt receipt recovery damaged staged audio in case \(index)")
}
// Syntactically valid but semantically unsafe journals must also fail closed.
// These can arise from partial migrations, interrupted writes or stale callbacks.
// Preserve both the evidence and all user audio on every rejected recovery.
let malformedModels: [(String, CrashJournal)] = [
    ("duplicate-ticket", CrashJournal(tickets: initial.tickets + [initial.tickets[0]], receipts: [])),
    ("orphan-receipt", CrashJournal(tickets: initial.tickets, receipts: [UUID()])),
    ("receipt-for-queued", CrashJournal(tickets: initial.tickets, receipts: [primary])),
    ("receipt-for-cancelled", CrashJournal(tickets: initial.tickets, receipts: [retired])),
    ("imported-without-receipt", CrashJournal(
        tickets: [CrashTicket(id: primary, state: .imported)] + Array(initial.tickets.dropFirst()),
        receipts: []))
]
for (name, model) in malformedModels {
    let invalid = try JSONEncoder().encode(model)
    try invalid.write(to: journal, options: .atomic)
    var rejected = false
    do {
        try complete(primary)
    } catch is RecoveryValidationError {
        rejected = true
    }
    try ensure(rejected, "unsafe journal accepted: \(name)")
    try ensure(Data(contentsOf: journal) == invalid, "unsafe journal overwritten: \(name)")
    try ensure(Data(contentsOf: imported) == validImported, "imported audio changed: \(name)")
    try ensure(Data(contentsOf: staged) == bytes &&
               Data(contentsOf: unrelated) == otherBytes, "staged audio changed: \(name)")
}
try validJournal.write(to: journal, options: .atomic)
try complete(primary)
try ensure((try recover()).receipts == Set([primary]),
           "valid receipt journal not recoverable after corruption")

print("PASS: 3 crash windows, 32 failed receipt writes with retries, 384 callback replays, 8 corrupt/unsafe journals, byte-exact 256 KiB staged audio")
if !CommandLine.arguments.contains("--fixture-only") {
    let path = "ios/MP3Shelf/Services/BackgroundAudioDownloader.swift"
    guard fm.fileExists(atPath: path) else {
        fputs("UNVERIFIED: native downloader source missing\n", stderr)
        exit(2)
    }
    let source = try String(contentsOfFile: path, encoding: .utf8)
    guard source.contains("didFinishDownloadingTo") else {
        fputs("FAIL: downloader completion entry point absent\n", stderr)
        exit(1)
    }
    print("SOURCE INSPECTION ONLY: production crash recovery UNVERIFIED")
}
