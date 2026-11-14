import Foundation

// Run from repository root: swift ios/Tests/CorruptManifestCallbackPreservationTests.swift
// Regression: an unreadable queue journal must never turn a valid completed
// URLSession task into an unknown/cancelled ticket whose staged bytes are deleted.
let source = try String(contentsOfFile: "ios/MP3Shelf/Services/BackgroundAudioDownloader.swift", encoding: .utf8)
func require(_ ok: @autoclosure () -> Bool, _ message: String) {
    precondition(ok(), message)
}
let recoveryStart = source.range(of: "private func importStagedDownloadsPass() async {")!
let sweep = source.range(of: "for ticket in tickets.values where ticket.status != .queued", range: recoveryStart.lowerBound..<source.endIndex)!
let preSweep = source[recoveryStart.lowerBound..<sweep.lowerBound]
require(preSweep.contains("guard manifestLoadError == nil else { return }"),
        "Corrupt queue must prevent import and staged-file sweeping")
let callback = source.range(of: "guard self.tickets[id]?.status == .queued else {")!
let callbackEnd = source.range(of: "await self.recoverStagedDownloads()", range: callback.lowerBound..<source.endIndex)!
let callbackBody = source[callback.lowerBound..<callbackEnd.lowerBound]
require(callbackBody.contains("if self.manifestLoadError != nil { return }"),
        "Unknown ticket callback must retain bytes when journal is unreadable")
require(callbackBody.range(of: "if self.manifestLoadError != nil { return }")!.lowerBound <
        callbackBody.range(of: "self.fm.removeItem(at: destination)")!.lowerBound,
        "Corruption guard must precede staging deletion")

// Deterministic state-machine fixture for both valid and corrupt journals.
struct Ticket: Codable { let id: UUID }
func decode(_ data: Data) -> (known: Set<UUID>, corrupt: Bool) {
    guard let tickets = try? JSONDecoder().decode([Ticket].self, from: data) else {
        return ([], true)
    }
    let ids = Set(tickets.map(\.id))
    return (ids, ids.count != tickets.count)
}
func shouldRetainStaging(_ id: UUID, _ state: (known: Set<UUID>, corrupt: Bool)) -> Bool {
    state.corrupt || state.known.contains(id)
}
let id = UUID()
let valid = decode(try JSONEncoder().encode([Ticket(id: id)]))
let invalid = decode(Data("{".utf8))
let duplicate = decode(try JSONEncoder().encode([Ticket(id: id), Ticket(id: id)]))
require(shouldRetainStaging(id, valid), "Known ticket must retain staged bytes")
require(!shouldRetainStaging(UUID(), valid), "Healthy journal may discard unknown staging")
require(shouldRetainStaging(id, invalid), "Invalid JSON must preserve staging")
require(shouldRetainStaging(id, duplicate), "Duplicate-ID journal must preserve staging")
require(invalid.corrupt && duplicate.corrupt && !valid.corrupt, "Corruption fixture invalid")
print("PASS: corrupt journal preserves callback staging and disables recovery sweep")
