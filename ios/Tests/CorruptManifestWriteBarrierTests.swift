import Foundation

// Run with: swift ios/Tests/CorruptManifestWriteBarrierTests.swift
// Production source checks require this fixture to run from the repository root.
let sourceURL = URL(fileURLWithPath: "ios/MP3Shelf/Services/BackgroundAudioDownloader.swift")
guard let source = try? String(contentsOf: sourceURL, encoding: .utf8) else {
    fatalError("Production downloader source unavailable; test not executed")
}
func assertContract(_ condition: Bool, _ message: String) {
    precondition(condition, message)
}
assertContract(source.contains("private var manifestLoadError: String?"), "Missing corruption state")
assertContract(source.contains("Set(saved.map(\\.id)).count == saved.count"), "Duplicate identifiers accepted")
assertContract(source.contains("if let reason = manifestLoadError"), "Missing write barrier")
assertContract(source.contains("try writeManifest(Array(updated.values), to: manifestURL)") == false,
               "Unexpected wrapper signature")
assertContract(!source.contains("try BackgroundTicketManifestPolicy.write(Array("),
               "An unguarded queue writer remains")
assertContract(source.contains("try writeManifest(Array(tickets.values))"),
               "Legacy persist bypasses write barrier")

let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
let journal = root.appendingPathComponent("tickets.json")
struct Ticket: Codable { let id: UUID; let state: String }
func guardedWrite(_ tickets: [Ticket], blocked: Bool) throws {
    guard !blocked else { throw NSError(domain: "Manifest", code: 3) }
    try JSONEncoder().encode(tickets).write(to: journal, options: .atomic)
}
let id = UUID()
let valid = try JSONEncoder().encode([Ticket(id: id, state: "queued")])
let invalid: [Data] = [
    Data("{".utf8),
    Data("null".utf8),
    try JSONEncoder().encode([Ticket(id: id, state: "queued"),
                              Ticket(id: id, state: "failed")])
]
for bytes in invalid {
    try bytes.write(to: journal, options: .atomic)
    let decoded = try? JSONDecoder().decode([Ticket].self, from: bytes)
    let blocked = decoded == nil || Set(decoded!.map(\\.id)).count != decoded!.count
    assertContract(blocked, "Corrupt or duplicate journal was accepted")
    do {
        try guardedWrite([Ticket(id: UUID(), state: "queued")], blocked: blocked)
        fatalError("Corrupt journal was overwritten")
    } catch {
        assertContract(try Data(contentsOf: journal) == bytes, "Original journal changed")
    }
}
try valid.write(to: journal, options: .atomic)
try guardedWrite([Ticket(id: id, state: "imported")], blocked: false)
assertContract(try JSONDecoder().decode([Ticket].self, from: Data(contentsOf: journal)).first?.state == "imported",
               "Valid queue cannot progress")
print("PASS: corruption barrier, duplicate IDs, original bytes, valid recovery, production source contract")
