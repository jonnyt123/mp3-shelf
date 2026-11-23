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
func recover(beforePublication: () throws -> Void = {}) throws {
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
    try beforePublication()
    // The no-replace link operation must reject a destination introduced after
    // preflight. A copy operation would overwrite nothing on Darwin, but a
    // hard link models the actual production publication primitive.
    try fm.linkItem(at: staged, to: destination)
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

 
// Crash replay must not overwrite an already-published recording even when
// staging changes after publication or an attacker replaces the journal.
// Preserve the published bytes, foreign bytes, and the recovery evidence.
for scenario in ["stage-replaced-after-publish", "stage-removed-after-publish",
                 "journal-replaced-after-publish", "destination-hardlinked-after-publish"] {
    try reset()
    try recover()
    let published = try Data(contentsOf: destination)
    switch scenario {
    case "stage-replaced-after-publish":
        try foreign.write(to: staged)
    case "stage-removed-after-publish":
        try fm.removeItem(at: staged)
    case "journal-replaced-after-publish":
        let changed = Journal(ticket: "foreign-ticket", stagedName: entry.stagedName,
                              destinationName: entry.destinationName, length: entry.length)
        try JSONEncoder().encode(changed).write(to: journal, options: .atomic)
    default:
        // A second hardlink to the destination must not permit a replay.
        let alias = root.appendingPathComponent("published-alias.mp3")
        try remove(alias)
        try fm.linkItem(at: destination, to: alias)
        defer { try? remove(alias) }
    }
    var rejected = false
    do { try recover() } catch { rejected = true }
    try assertSafe(rejected, "\(scenario): replay accepted")
    try assertSafe(try Data(contentsOf: destination) == published,
                   "\(scenario): published audio overwritten")
    try assertSafe(try Data(contentsOf: other) == foreign,
                   "\(scenario): foreign audio modified")
    try assertSafe(fm.fileExists(atPath: journal.path),
                   "\(scenario): recovery evidence discarded")
    cases += 1
}
print("PASS: \(cases) crash/replay filesystem scenarios total")


// Inject a second writer *after* the destination absence check, at the exact
// publication boundary. This models two imports/recovery callbacks racing for
// one filename; the losing writer must not replace or unlink the winner.
for scenario in ["foreign-writer", "identical-writer", "directory-writer",
                 "symlink-writer", "dangling-symlink-writer", "hardlink-writer"] {
    try reset()
    var injected = false
    var rejected = false
    do {
        try recover(beforePublication: {
            injected = true
            switch scenario {
            case "foreign-writer": try foreign.write(to: destination)
            case "identical-writer": try audio.write(to: destination)
            case "directory-writer":
                try fm.createDirectory(at: destination, withIntermediateDirectories: false)
            case "symlink-writer":
                try fm.createSymbolicLink(at: destination, withDestinationURL: other)
            case "dangling-symlink-writer":
                try fm.createSymbolicLink(at: destination,
                    withDestinationURL: root.appendingPathComponent("missing-winner"))
            default: try fm.linkItem(at: other, to: destination)
            }
        })
    } catch { rejected = true }
    try assertSafe(injected && rejected, "\(scenario): racing publication accepted")
    try assertSafe(fm.fileExists(atPath: destination.path) ||
                   (try? fm.destinationOfSymbolicLink(atPath: destination.path)) != nil,
                   "\(scenario): winning destination removed")
    if scenario == "foreign-writer" || scenario == "hardlink-writer" {
        try assertSafe(try Data(contentsOf: destination) == foreign,
                       "\(scenario): winner bytes changed")
    } else if scenario == "identical-writer" {
        try assertSafe(try Data(contentsOf: destination) == audio,
                       "identical winner bytes changed")
    }
    try assertSafe(try Data(contentsOf: staged) == audio,
                   "\(scenario): losing staged bytes consumed")
    try assertSafe(try Data(contentsOf: other) == foreign,
                   "\(scenario): unrelated audio modified")
    try assertSafe(fm.fileExists(atPath: journal.path),
                   "\(scenario): recovery intent removed")
    cases += 1
}
print("PASS: \(cases) filesystem recovery and publication-race scenarios total")


// Independent stage-identity race matrix: a validated pathname is not a
// validated file descriptor. A second writer can replace the staging pathname
// after preflight; the publisher must detect that identity change before
// publishing bytes. This models a safe publication boundary using an inode
// identity snapshot, without changing production-owned recovery code.
func identity(_ url: URL) throws -> (UInt64, UInt64) {
    let attrs = try fm.attributesOfItem(atPath: url.path)
    guard let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value,
          let device = (attrs[.systemNumber] as? NSNumber)?.uint64Value
    else { throw RecoveryError.invalidAudio }
    return (device, inode)
}
func guardedRecover(beforePublication: () throws -> Void) throws {
    let expected = try identity(staged)
    guard regular(staged), try Data(contentsOf: staged) == audio else {
        throw RecoveryError.invalidAudio
    }
    try beforePublication()
    let actual = try identity(staged)
    guard actual == expected, regular(staged),
          try Data(contentsOf: staged) == audio else {
        throw RecoveryError.invalidAudio
    }
    try fm.linkItem(at: staged, to: destination)
}
for scenario in ["replace-stage-with-foreign", "replace-stage-with-identical",
                 "replace-stage-with-symlink", "replace-stage-with-hardlink",
                 "remove-stage", "replace-stage-with-directory"] {
    try reset()
    var injected = false
    var rejected = false
    do {
        try guardedRecover(beforePublication: {
            injected = true
            try fm.removeItem(at: staged)
            switch scenario {
            case "replace-stage-with-foreign": try foreign.write(to: staged)
            case "replace-stage-with-identical": try audio.write(to: staged)
            case "replace-stage-with-symlink":
                try fm.createSymbolicLink(at: staged, withDestinationURL: other)
            case "replace-stage-with-hardlink": try fm.linkItem(at: other, to: staged)
            case "replace-stage-with-directory":
                try fm.createDirectory(at: staged, withIntermediateDirectories: false)
            default: break
            }
        })
    } catch { rejected = true }
    try assertSafe(injected && rejected, "\(scenario): stage identity race accepted")
    try assertSafe(!fm.fileExists(atPath: destination.path),
                   "\(scenario): unvalidated stage published")
    try assertSafe(try Data(contentsOf: other) == foreign,
                   "\(scenario): foreign audio changed")
    try assertSafe(fm.fileExists(atPath: journal.path),
                   "\(scenario): recovery intent lost")
    cases += 1
}
print("PASS: \(cases) filesystem recovery, publication and stage-identity scenarios total")


// A journal is also mutable between validation and publication. A recovery
// callback must not publish audio under a replaced, deleted, or relinked
// recovery intent, even when the replacement has the same serialized bytes.
// These tests use a guarded reference publisher, not production service code.
func guardedJournalRecover(beforePublication: () throws -> Void) throws {
    guard regular(journal), let original = try? Data(contentsOf: journal),
          let decoded = try? JSONDecoder().decode(Journal.self, from: original),
          decoded.ticket == entry.ticket, decoded.stagedName == entry.stagedName,
          decoded.destinationName == entry.destinationName, decoded.length == audio.count,
          regular(staged), try Data(contentsOf: staged) == audio else {
        throw RecoveryError.invalidJournal
    }
    let journalIdentity = try identity(journal)
    let stageIdentity = try identity(staged)
    try beforePublication()
    guard regular(journal), regular(staged),
          try identity(journal) == journalIdentity,
          try identity(staged) == stageIdentity,
          try Data(contentsOf: journal) == original,
          try Data(contentsOf: staged) == audio else {
        throw RecoveryError.invalidJournal
    }
    try fm.linkItem(at: staged, to: destination)
}
for scenario in ["journal-removed", "journal-replaced-identical",
                 "journal-replaced-foreign-ticket", "journal-replaced-symlink",
                 "journal-replaced-hardlink", "journal-replaced-directory",
                 "journal-mutated-in-place", "stage-mutated-in-place"] {
    try reset()
    var injected = false
    var rejected = false
    do {
        try guardedJournalRecover(beforePublication: {
            injected = true
            switch scenario {
            case "journal-removed":
                try fm.removeItem(at: journal)
            case "journal-replaced-identical":
                let bytes = try Data(contentsOf: journal)
                try fm.removeItem(at: journal)
                try bytes.write(to: journal)
            case "journal-replaced-foreign-ticket":
                try fm.removeItem(at: journal)
                let changed = Journal(ticket: "foreign", stagedName: entry.stagedName,
                                      destinationName: entry.destinationName, length: entry.length)
                try JSONEncoder().encode(changed).write(to: journal)
            case "journal-replaced-symlink":
                try fm.removeItem(at: journal)
                try fm.createSymbolicLink(at: journal, withDestinationURL: other)
            case "journal-replaced-hardlink":
                try fm.removeItem(at: journal)
                try fm.linkItem(at: other, to: journal)
            case "journal-replaced-directory":
                try fm.removeItem(at: journal)
                try fm.createDirectory(at: journal, withIntermediateDirectories: false)
            case "journal-mutated-in-place":
                let handle = try FileHandle(forWritingTo: journal)
                defer { try? handle.close() }
                try handle.seek(toOffset: 0)
                try handle.write(contentsOf: Data("X".utf8))
            default:
                let handle = try FileHandle(forWritingTo: staged)
                defer { try? handle.close() }
                try handle.seek(toOffset: 0)
                try handle.write(contentsOf: Data("X".utf8))
            }
        })
    } catch { rejected = true }
    try assertSafe(injected && rejected, "\(scenario): changed recovery intent accepted")
    try assertSafe(!fm.fileExists(atPath: destination.path),
                   "\(scenario): unvalidated bytes published")
    try assertSafe(try Data(contentsOf: other) == foreign,
                   "\(scenario): unrelated audio modified")
    cases += 1
}
print("PASS: \(cases) filesystem recovery, publication and identity scenarios total")


// Recovery must remain retryable after a publication collision. The losing
// attempt must not consume staged bytes or discard its durable intent; after
// the competing destination is removed, the original validated audio can
// publish exactly once. This is a Foundation filesystem contract only.
for scenario in ["foreign-file", "identical-file", "directory", "symlink",
                 "dangling-symlink", "hardlink"] {
    try reset()
    switch scenario {
    case "foreign-file": try foreign.write(to: destination)
    case "identical-file": try audio.write(to: destination)
    case "directory":
        try fm.createDirectory(at: destination, withIntermediateDirectories: false)
    case "symlink": try fm.createSymbolicLink(at: destination, withDestinationURL: other)
    case "dangling-symlink":
        try fm.createSymbolicLink(at: destination,
                                  withDestinationURL: root.appendingPathComponent("absent"))
    default: try fm.linkItem(at: other, to: destination)
    }
    let journalBefore = try Data(contentsOf: journal)
    var collisionRejected = false
    do { try recover() } catch { collisionRejected = true }
    try assertSafe(collisionRejected, "\(scenario): collision did not fail closed")
    try assertSafe(try Data(contentsOf: staged) == audio,
                   "\(scenario): collision consumed staged recording")
    try assertSafe(try Data(contentsOf: journal) == journalBefore,
                   "\(scenario): collision discarded durable recovery intent")
    try assertSafe(try Data(contentsOf: other) == foreign,
                   "\(scenario): collision damaged unrelated recording")
    try remove(destination)
    try recover()
    try assertSafe(try Data(contentsOf: destination) == audio,
                   "\(scenario): safe retry did not publish original recording")
    try assertSafe(try Data(contentsOf: staged) == audio,
                   "\(scenario): retry consumed original stage")
    var replayRejected = false
    do { try recover() } catch RecoveryError.occupied { replayRejected = true }
    try assertSafe(replayRejected, "\(scenario): post-retry replay was accepted")
    try assertSafe(try Data(contentsOf: destination) == audio,
                   "\(scenario): replay replaced recovered recording")
    cases += 1
}
print("PASS: \(cases) filesystem recovery scenarios including collision-to-retry")
