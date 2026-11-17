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

func expectInvalid(_ label: String, _ action: () throws -> Void) throws {
    do { try action(); try assertQA(false, "\(label): unsafe file accepted") }
    catch TicketError.invalidAudio {}
}
func resetPending() throws {
    if fm.fileExists(atPath: stagedURL.path) { try fm.removeItem(at: stagedURL) }
    if fm.fileExists(atPath: finalURL.path) { try fm.removeItem(at: finalURL) }
    try writeJournal(TicketJournal(state: .pending, receiptCount: 0))
}
func verifyNoMutation(_ label: String, _ expectedFinal: Data? = nil) throws {
    try assertQA(try readJournal() == TicketJournal(state: .pending, receiptCount: 0),
                 "\(label): journal mutated on rejected input")
    if let expectedFinal {
        try assertQA(try Data(contentsOf: finalURL) == expectedFinal,
                     "\(label): existing destination overwritten")
    } else {
        try assertQA(!fm.fileExists(atPath: finalURL.path),
                     "\(label): unexpected destination created")
    }
    try assertQA(try Data(contentsOf: foreignURL) == foreign,
                 "\(label): unrelated recording changed")
}
// Filesystem adversaries: the journal must never authorize a symlink, hardlink,
// directory, empty/truncated payload or pre-existing different destination.
try resetPending()
try fm.createSymbolicLink(at: stagedURL, withDestinationURL: foreignURL)
try expectInvalid("staged symlink") { try replay() }
try verifyNoMutation("staged symlink")
try resetPending()
try fm.linkItem(at: foreignURL, to: stagedURL)
try expectInvalid("staged hardlink") { try replay() }
try verifyNoMutation("staged hardlink")
try resetPending()
try fm.createDirectory(at: stagedURL, withIntermediateDirectories: false)
try expectInvalid("staged directory") { try replay() }
try verifyNoMutation("staged directory")
try resetPending()
try Data().write(to: stagedURL)
try expectInvalid("empty staging") { try replay() }
try verifyNoMutation("empty staging")
try resetPending()
try audio.prefix(audio.count / 2).write(to: stagedURL)
try expectInvalid("truncated staging") { try replay() }
try verifyNoMutation("truncated staging")
try resetPending()
try audio.write(to: stagedURL)
try foreign.write(to: finalURL)
try expectInvalid("foreign destination") { try replay() }
try verifyNoMutation("foreign destination", foreign)
try resetPending()
try audio.write(to: stagedURL)
try audio.prefix(audio.count / 2).write(to: finalURL)
try expectInvalid("partial destination") { try replay() }
try verifyNoMutation("partial destination", Data(audio.prefix(audio.count / 2)))
try resetPending()
try audio.write(to: stagedURL)
try fm.createSymbolicLink(at: finalURL, withDestinationURL: foreignURL)
try expectInvalid("destination symlink") { try replay() }
try assertQA(try readJournal().receiptCount == 0, "destination symlink changed journal")
try assertQA(try Data(contentsOf: foreignURL) == foreign, "destination symlink followed")

print("PASS: \(scenarios) crash/restart combinations and 8 adversarial filesystem cases")


func expectCorruptJournal(_ label: String, _ data: Data) throws {
    try resetPending()
    try audio.write(to: stagedURL)
    try data.write(to: journalURL, options: .atomic)
    let original = try Data(contentsOf: journalURL)
    do { try replay(); try assertQA(false, "\(label): malformed journal accepted") }
    catch TicketError.corruptJournal {}
    try assertQA(try Data(contentsOf: journalURL) == original,
                 "\(label): malformed journal was rewritten")
    try assertQA(!fm.fileExists(atPath: finalURL.path),
                 "\(label): malformed journal created audio")
    try assertQA(try Data(contentsOf: foreignURL) == foreign,
                 "\(label): unrelated audio changed")
}
try expectCorruptJournal("pending with receipt", Data(#"{"state":"pending","receiptCount":1}"#.utf8))
try expectCorruptJournal("copying with receipt", Data(#"{"state":"copying","receiptCount":1}"#.utf8))
try expectCorruptJournal("complete without receipt", Data(#"{"state":"complete","receiptCount":0}"#.utf8))
try expectCorruptJournal("negative receipt", Data(#"{"state":"pending","receiptCount":-1}"#.utf8))
try expectCorruptJournal("duplicate receipt", Data(#"{"state":"complete","receiptCount":2}"#.utf8))
try expectCorruptJournal("unknown state", Data(#"{"state":"published","receiptCount":0}"#.utf8))
try expectCorruptJournal("oversized journal", Data(repeating: 0x20, count: 4097))

try resetPending()
try audio.write(to: stagedURL)
try fm.createDirectory(at: finalURL, withIntermediateDirectories: false)
try expectInvalid("destination directory") { try replay() }
try assertQA(try readJournal() == TicketJournal(state: .pending, receiptCount: 0),
             "destination directory advanced receipt")
try assertQA(try fm.attributesOfItem(atPath: finalURL.path)[.type] as? FileAttributeType == .typeDirectory,
             "destination directory replaced")

try resetPending()
try audio.write(to: stagedURL)
try fm.linkItem(at: foreignURL, to: finalURL)
try expectInvalid("destination hardlink") { try replay() }
try assertQA(try readJournal() == TicketJournal(state: .pending, receiptCount: 0),
             "destination hardlink advanced receipt")
try assertQA(try Data(contentsOf: foreignURL) == foreign,
             "destination hardlink modified unrelated recording")

print("PASS: 7 malformed journal cases and 2 destination filesystem adversaries")
