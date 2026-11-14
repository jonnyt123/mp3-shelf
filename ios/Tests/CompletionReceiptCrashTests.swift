import Foundation

// swift ios/Tests/CompletionReceiptCrashTests.swift --fixture-only
// Standalone fault injection, not a production URLSession integration test.
struct Ticket: Codable { let id: UUID; var state: String }
struct Journal: Codable { var tickets: [Ticket]; var receipts: Set<UUID> }
enum Fault: Error { case write }
func assertSafe(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { fatalError(message) }
}
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("mp3-receipt-\(UUID())")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let manifest = root.appendingPathComponent("journal.json")
let audioURL = root.appendingPathComponent("recording.mp3")
let unrelatedURL = root.appendingPathComponent("unrelated.mp3")
let audio = Data((0..<65536).map { UInt8($0 % 251) })
let unrelated = Data((0..<65536).map { UInt8(($0 + 37) % 251) })
try audio.write(to: audioURL)
try unrelated.write(to: unrelatedURL)
let retired = UUID(), successor = UUID(), other = UUID()
let initial = Journal(tickets: [Ticket(id: retired, state: "cancelled"),
                                Ticket(id: successor, state: "queued"),
                                Ticket(id: other, state: "queued")], receipts: [])
func save(_ journal: Journal, fail: Bool = false) throws {
    if fail { throw Fault.write }
    try JSONEncoder().encode(journal).write(to: manifest, options: .atomic)
}
func load() throws -> Journal {
    try JSONDecoder().decode(Journal.self, from: Data(contentsOf: manifest))
}
try save(initial)
var imports = 0
func complete(_ id: UUID, fail: Bool = false) throws {
    var current = try load()
    guard let index = current.tickets.firstIndex(where: { $0.id == id }),
          current.tickets[index].state == "queued",
          !current.receipts.contains(id) else { return }
    current.tickets[index].state = "imported"
    current.receipts.insert(id)
    try save(current, fail: fail)
    imports += 1
}
for _ in 0..<48 {
    do { try complete(successor, fail: true); fatalError("acknowledged failed write") }
    catch Fault.write {}
    try assertSafe(imports == 0 && (try load()).receipts.isEmpty,
                   "failed journal publication acknowledged import")
    try assertSafe(Data(contentsOf: audioURL) == audio &&
                   Data(contentsOf: unrelatedURL) == unrelated, "staged audio modified")
}
for _ in 0..<48 { try complete(retired) }
try assertSafe(imports == 0, "retired callback imported")
try complete(successor)
for _ in 0..<96 { try complete(successor) }
let recovered = try load()
try assertSafe(imports == 1 && recovered.receipts == Set([successor]),
               "duplicate callback imported more than once")
try assertSafe(recovered.tickets.first(where: { $0.id == other })?.state == "queued",
               "unrelated transfer modified")
try assertSafe(Data(contentsOf: audioURL) == audio &&
               Data(contentsOf: unrelatedURL) == unrelated, "audio bytes changed")
print("PASS: 48 failed writes, 48 retired callbacks, 96 duplicate callbacks; 128 KiB unchanged")

if !CommandLine.arguments.contains("--fixture-only") {
    let path = "ios/MP3Shelf/Services/BackgroundAudioDownloader.swift"
    guard fm.fileExists(atPath: path) else {
        fputs("UNVERIFIED: production downloader source missing\n", stderr)
        exit(2)
    }
    let source = try String(contentsOfFile: path, encoding: .utf8)
    guard source.contains("didFinishDownloadingTo"),
          source.contains("BackgroundTicketManifestPolicy.write(") else {
        fatalError("downloader completion or persistence contract missing")
    }
    print("SOURCE INSPECTION ONLY: production callback atomicity UNVERIFIED")
}
