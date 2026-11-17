import Foundation

// Run: swift ios/Tests/RecoveryJournalCrashMatrixTests.swift
// Independent Foundation filesystem contract; NOT a production downloader or device test.
enum RecoveryError: Error { case invalidJournal, invalidAudio, occupied }
struct Journal: Codable {
    let ticket: String
    let stagedName: String
    let destinationName: String
    let length: Int
}
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("journal-crash-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let staged = root.appendingPathComponent("staged.mp3")
let destination = root.appendingPathComponent("destination.mp3")
let journal = root.appendingPathComponent("journal.json")
let other = root.appendingPathComponent("other.mp3")
let audio = Data((0..<65536).map { UInt8(($0 * 29 + 17) % 251) })
let foreign = Data((0..<65536).map { UInt8(($0 * 31 + 9) % 251) })
try foreign.write(to: other)
let entry = Journal(ticket: "ticket-1", stagedName: "staged.mp3", destinationName: "destination.mp3", length: audio.count)
func assertSafe(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw NSError(domain: "RecoveryJournalCrashMatrix", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
func remove(_ url: URL) throws {
    if fm.fileExists(atPath: url.path) || (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil {
        try fm.removeItem(at: url)
    }
}
func reset() throws {
    for url in [staged, destination, journal] { try remove(url) }
    try audio.write(to: staged)
    try JSONEncoder().encode(entry).write(to: journal, options: .atomic)
}
func regular(_ url: URL) -> Bool {
    guard (try? fm.destinationOfSymbolicLink(atPath: url.path)) == nil,
          let attrs = try? fm.attributesOfItem(atPath: url.path),
          attrs[.type] as? FileAttributeType == .typeRegular,
          (attrs[.referenceCount] as? NSNumber)?.intValue == 1 else { return false }
    return true
}
func recover() throws {
    guard regular(journal), let data = try? Data(contentsOf: journal),
          let saved = try? JSONDecoder().decode(Journal.self, from: data),
          saved.ticket == entry.ticket, saved.stagedName == entry.stagedName,
          saved.destinationName == entry.destinationName,
          !saved.stagedName.contains("/"), !saved.destinationName.contains("/") else {
        throw RecoveryError.invalidJournal
    }
    guard regular(staged), let bytes = try? Data(contentsOf: staged),
          bytes.count == saved.length, bytes == audio else { throw RecoveryError.invalidAudio }
    guard !fm.fileExists(atPath: destination.path),
          (try? fm.destinationOfSymbolicLink(atPath: destination.path)) == nil else {
        throw RecoveryError.occupied
    }
    try fm.copyItem(at: staged, to: destination)
    // Simulated crash before cleanup: staged bytes and journal remain for retry.
}
var cases = 0
for scenario in ["missing-stage", "truncated-stage", "same-length-corrupt", "symlink-stage",
                 "hardlink-stage", "directory-stage", "foreign-destination",
                 "identical-destination", "symlink-destination", "dangling-destination",
                 "corrupt-journal", "path-traversal"] {
    try reset()
    switch scenario {
    case "missing-stage": try fm.removeItem(at: staged)
    case "truncated-stage": try audio.prefix(64).write(to: staged)
    case "same-length-corrupt": try foreign.write(to: staged)
    case "symlink-stage": try fm.removeItem(at: staged); try fm.createSymbolicLink(at: staged, withDestinationURL: other)
    case "hardlink-stage": try fm.removeItem(at: staged); try fm.linkItem(at: other, to: staged)
    case "directory-stage": try fm.removeItem(at: staged); try fm.createDirectory(at: staged, withIntermediateDirectories: false)
    case "foreign-destination": try foreign.write(to: destination)
    case "identical-destination": try audio.write(to: destination)
    case "symlink-destination": try fm.createSymbolicLink(at: destination, withDestinationURL: other)
    case "dangling-destination": try fm.createSymbolicLink(at: destination, withDestinationURL: root.appendingPathComponent("missing"))
    case "corrupt-journal": try Data("{".utf8).write(to: journal)
    default:
        let malicious = Journal(ticket: entry.ticket, stagedName: "../other.mp3",
                                destinationName: entry.destinationName, length: entry.length)
        try JSONEncoder().encode(malicious).write(to: journal)
    }
    var rejected = false
    do { try recover() } catch { rejected = true }
    try assertSafe(rejected, "\(scenario): unsafe recovery accepted")
    try assertSafe(try Data(contentsOf: other) == foreign, "\(scenario): unrelated audio modified")
    try assertSafe(fm.fileExists(atPath: journal.path), "\(scenario): journal lost")
    cases += 1
}
try reset()
try recover()
try assertSafe(try Data(contentsOf: destination) == audio, "successful copy corrupted audio")
try assertSafe(try Data(contentsOf: staged) == audio, "staged audio consumed before commit")
var replayRejected = false
do { try recover() } catch RecoveryError.occupied { replayRejected = true }
try assertSafe(replayRejected, "crash replay overwrote published destination")
try assertSafe(try Data(contentsOf: destination) == audio, "replay modified published audio")
try assertSafe(fm.fileExists(atPath: journal.path), "replay discarded journal")
print("PASS: \(cases) unsafe recovery cases, successful copy, crash replay protection")

 
// Additional independent fail-closed publication matrix. These scenarios are
// deliberately filesystem-backed, not a substitute for URLSession integration.
for scenario in ["empty-stage", "empty-journal", "symlink-journal", "hardlink-journal",
                 "directory-journal", "directory-destination", "hardlink-destination",
                 "wrong-ticket", "wrong-length", "absolute-stage", "nested-destination"] {
    try reset()
    switch scenario {
    case "empty-stage": try Data().write(to: staged)
    case "empty-journal": try Data().write(to: journal)
    case "symlink-journal":
        try remove(journal)
        try fm.createSymbolicLink(at: journal, withDestinationURL: other)
    case "hardlink-journal":
        try remove(journal)
        try fm.linkItem(at: other, to: journal)
    case "directory-journal":
        try remove(journal)
        try fm.createDirectory(at: journal, withIntermediateDirectories: false)
    case "directory-destination":
        try fm.createDirectory(at: destination, withIntermediateDirectories: false)
    case "hardlink-destination":
        try fm.linkItem(at: other, to: destination)
    default:
        let changed: Journal
        switch scenario {
        case "wrong-ticket":
            changed = Journal(ticket: "ticket-2", stagedName: entry.stagedName,
                              destinationName: entry.destinationName, length: entry.length)
        case "wrong-length":
            changed = Journal(ticket: entry.ticket, stagedName: entry.stagedName,
                              destinationName: entry.destinationName, length: entry.length + 1)
        case "absolute-stage":
            changed = Journal(ticket: entry.ticket, stagedName: "/tmp/staged.mp3",
                              destinationName: entry.destinationName, length: entry.length)
        default:
            changed = Journal(ticket: entry.ticket, stagedName: entry.stagedName,
                              destinationName: "nested/destination.mp3", length: entry.length)
        }
        try JSONEncoder().encode(changed).write(to: journal, options: .atomic)
    }
    var rejected = false
    do { try recover() } catch { rejected = true }
    try assertSafe(rejected, "\(scenario): invalid recovery accepted")
    try assertSafe(try Data(contentsOf: other) == foreign,
                   "\(scenario): unrelated bytes modified")
    // The adversarial stage may be a directory or other nonregular entry.
    // Only compare payload bytes when the scenario retained a regular file.
    if regular(staged) {
        try assertSafe(try Data(contentsOf: staged) == audio,
                       "\(scenario): staged bytes consumed or modified")
    } else {
        try assertSafe(fm.fileExists(atPath: staged.path),
                       "\(scenario): nonregular staged entry was removed")
    }
    try assertSafe(fm.fileExists(atPath: journal.path) ||
                   (try? fm.destinationOfSymbolicLink(atPath: journal.path)) != nil,
                   "\(scenario): rejected journal was removed")
    cases += 1
}
print("PASS: \(cases) unsafe recovery scenarios total")
