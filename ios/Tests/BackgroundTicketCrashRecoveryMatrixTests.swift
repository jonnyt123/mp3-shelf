import Foundation

// Run: swift ios/Tests/BackgroundTicketCrashRecoveryMatrixTests.swift
// Standalone Foundation filesystem contract test; not an app/device integration test.
enum CrashPoint: CaseIterable { case beforeCopy, afterCopy, beforeReceipt, afterReceipt }
enum TicketError: Error { case interrupted, invalidAudio, corruptJournal }
struct TicketJournal: Codable, Equatable {
    enum State: String, Codable { case pending, copying, complete }
    var state: State
    var receiptCount: Int
}
func assertQA(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw NSError(domain: "TicketQA", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("mp3-ticket-matrix-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let journalURL = root.appendingPathComponent("ticket.json")
let stagedURL = root.appendingPathComponent("staged.mp3")
let finalURL = root.appendingPathComponent("final.mp3")
let foreignURL = root.appendingPathComponent("foreign.mp3")
let audio = Data((0..<65536).map { UInt8(($0 * 31 + 7) % 251) })
let foreign = Data((0..<65536).map { UInt8(($0 * 13 + 5) % 251) })
try foreign.write(to: foreignURL)
func readJournal() throws -> TicketJournal {
    let data = try Data(contentsOf: journalURL)
    guard data.count <= 4096, let value = try? JSONDecoder().decode(TicketJournal.self, from: data),
          value.receiptCount == 0 || value.receiptCount == 1,
          (value.state == .complete) == (value.receiptCount == 1) else { throw TicketError.corruptJournal }
    return value
}
func writeJournal(_ value: TicketJournal) throws {
    try JSONEncoder().encode(value).write(to: journalURL, options: .atomic)
}
func validFile(_ url: URL) throws -> Bool {
    if (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil { throw TicketError.invalidAudio }
    guard let attrs = try? fm.attributesOfItem(atPath: url.path) else { return false }
    guard attrs[.type] as? FileAttributeType == .typeRegular,
          (attrs[.referenceCount] as? NSNumber)?.intValue == 1 else { throw TicketError.invalidAudio }
    guard (attrs[.size] as? NSNumber)?.intValue == audio.count,
          try Data(contentsOf: url) == audio else { throw TicketError.invalidAudio }
    return true
}
func replay(crashAt point: CrashPoint? = nil) throws {
    var journal = try readJournal()
    if journal.state == .complete {
        guard try validFile(finalURL) else { throw TicketError.invalidAudio }
        return
    }
    let destinationValid = try validFile(finalURL)
    if !destinationValid {
        guard try validFile(stagedURL) else { throw TicketError.invalidAudio }
        if point == .beforeCopy { throw TicketError.interrupted }
        journal.state = .copying
        try writeJournal(journal)
        try fm.copyItem(at: stagedURL, to: finalURL)
        if point == .afterCopy { throw TicketError.interrupted }
    }
    if point == .beforeReceipt { throw TicketError.interrupted }
    journal.state = .complete
    journal.receiptCount = 1
    try writeJournal(journal)
    if point == .afterReceipt { throw TicketError.interrupted }
}
var scenarios = 0
for point in CrashPoint.allCases {
    for removeStaged in [false, true] {
        if fm.fileExists(atPath: finalURL.path) { try fm.removeItem(at: finalURL) }
        try audio.write(to: stagedURL, options: .atomic)
        try writeJournal(TicketJournal(state: .pending, receiptCount: 0))
        do { try replay(crashAt: point); try assertQA(false, "crash injection did not fire") }
        catch TicketError.interrupted {}
        let beforeRecovery = try readJournal()
        try assertQA(beforeRecovery.receiptCount <= 1, "duplicate receipt before restart")
        if removeStaged && fm.fileExists(atPath: stagedURL.path) { try fm.removeItem(at: stagedURL) }
        let destinationExists = fm.fileExists(atPath: finalURL.path)
        if !destinationExists && removeStaged {
            do { try replay(); try assertQA(false, "missing staged audio incorrectly recovered") }
            catch TicketError.invalidAudio {}
            try assertQA(try readJournal() == beforeRecovery, "failed retry changed durable journal")
            try audio.write(to: stagedURL, options: .atomic)
        }
        try replay()
        try replay() // repeated OS delegate completion must not republish a receipt
        try assertQA(try readJournal() == TicketJournal(state: .complete, receiptCount: 1), "replay not idempotent")
        try assertQA(try Data(contentsOf: finalURL) == audio, "audio not preserved")
        try assertQA(try Data(contentsOf: foreignURL) == foreign, "foreign audio changed")
        scenarios += 1
    }
}
try writeJournal(TicketJournal(state: .complete, receiptCount: 1))
try foreign.write(to: finalURL, options: .atomic)
do { try replay(); try assertQA(false, "foreign terminal recording accepted") }
catch TicketError.invalidAudio {}
try assertQA(try Data(contentsOf: finalURL) == foreign, "foreign recording overwritten")
try assertQA(try readJournal().receiptCount == 1, "invalid terminal file changed receipt")
try Data("{invalid".utf8).write(to: journalURL, options: .atomic)
do { try replay(); try assertQA(false, "corrupt journal accepted") }
catch TicketError.corruptJournal {}
try assertQA(try Data(contentsOf: finalURL) == foreign, "corrupt journal changed recording")
print("PASS: \(scenarios) crash/restart combinations, duplicate callbacks, foreign audio and corrupt journal")
