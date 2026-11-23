import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// Standalone adversarial filesystem fixture. Not a production downloader test.
// swift -swift-version 6 ios/Tests/BackgroundTicketSymlinkBoundaryTests.swift
struct SafeJournal: Codable, Equatable { let id: String; let generation: Int }
enum BoundaryError: Error { case unsafe, stale, identityMismatch }
func hasSafeParent(_ url: URL) -> Bool {
    // Validate every existing ancestor: checking only the immediate parent
    // misses a symlink higher in a nested journal directory.
    var current = url.deletingLastPathComponent().standardizedFileURL
    while true {
        var info = stat()
        let safe = current.path.withCString {
            lstat($0, &info) == 0 &&
            (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
        }
        if !safe { return false }
        let parent = current.deletingLastPathComponent()
        if parent.path == current.path { return true }
        current = parent
    }
}
func isRegularNoFollow(_ url: URL) -> Bool {
    var info = stat()
    return url.path.withCString { lstat($0, &info) == 0 && (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) }
}
func readJournal(_ url: URL, expectedID: String? = nil) throws -> SafeJournal? {
    var info = stat()
    guard hasSafeParent(url) else { throw BoundaryError.unsafe }
    let exists = url.path.withCString { lstat($0, &info) == 0 }
    if !exists { return nil }
    guard isRegularNoFollow(url) else { throw BoundaryError.unsafe }
    let record = try JSONDecoder().decode(SafeJournal.self, from: Data(contentsOf: url))
    guard record.generation > 0, record.id.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { throw BoundaryError.unsafe }
    if let expectedID, record.id != expectedID { throw BoundaryError.identityMismatch }
    return record
}
func publish(_ record: SafeJournal, to destination: URL) throws {
    guard record.id.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil,
          record.generation > 0 else { throw BoundaryError.unsafe }
    guard hasSafeParent(destination) else { throw BoundaryError.unsafe }
    if let old = try readJournal(destination, expectedID: record.id), old.generation >= record.generation { throw BoundaryError.stale }
    let temporary = destination.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".tmp")
    defer { try? FileManager.default.removeItem(at: temporary) }
    try JSONEncoder().encode(record).write(to: temporary, options: .atomic)
    guard isRegularNoFollow(temporary) else { throw BoundaryError.unsafe }
    let status = temporary.path.withCString { src in destination.path.withCString { dst in rename(src, dst) } }
    guard status == 0 else { throw BoundaryError.unsafe }
}
func check(_ value: @autoclosure () throws -> Bool, _ message: String) {
    guard (try? value()) == true else { fatalError(message) }
}
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("mp3-symlink-qa-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let outside = root.appendingPathComponent("outside.txt")
let sentinel = Data("DO-NOT-CHANGE".utf8)
try sentinel.write(to: outside)
for i in 0..<128 {
    let journal = root.appendingPathComponent("ticket_\(i).json")
    try fm.createSymbolicLink(at: journal, withDestinationURL: outside)
    do { _ = try readJournal(journal); fatalError("symlink journal accepted") }
    catch BoundaryError.unsafe { }
    do { try publish(SafeJournal(id: "ticket_\(i)", generation: 1), to: journal); fatalError("symlink journal overwritten") }
    catch BoundaryError.unsafe { }
    check(try Data(contentsOf: outside) == sentinel, "external bytes changed")
    try fm.removeItem(at: journal)
    try publish(SafeJournal(id: "ticket_\(i)", generation: 1), to: journal)
    check(try readJournal(journal) == SafeJournal(id: "ticket_\(i)", generation: 1), "valid journal missing")
    do { try publish(SafeJournal(id: "ticket_\(i)", generation: 1), to: journal); fatalError("stale journal accepted") }
    catch BoundaryError.stale { }
    try publish(SafeJournal(id: "ticket_\(i)", generation: 2), to: journal)
    check(try readJournal(journal)?.generation == 2, "replacement failed")
}
for i in 0..<64 {
    let journal = root.appendingPathComponent("corrupt_\(i).json")
    try Data("{not-json".utf8).write(to: journal)
    do { try publish(SafeJournal(id: "corrupt_\(i)", generation: 1), to: journal); fatalError("corrupt journal silently overwritten") }
    catch is DecodingError { }
    check(try Data(contentsOf: journal) == Data("{not-json".utf8), "corrupt evidence lost")
}
print("PASS: 128 symlink journal isolation and replacement sequences; 64 corrupt journal preservation cases (standalone model only)")

// Cross-ticket substitution must never be mistaken for a valid older generation.
// A foreign journal with a high or low generation is preserved for recovery.
for i in 0..<128 {
    let destination = root.appendingPathComponent("identity_\(i).json")
    let original = SafeJournal(id: "owner_\(i)", generation: i + 1)
    let foreign = SafeJournal(id: "foreign_\(i)", generation: 1)
    try JSONEncoder().encode(foreign).write(to: destination)
    let originalBytes = try Data(contentsOf: destination)
    do {
        try publish(original, to: destination)
        fatalError("foreign ticket journal replaced")
    } catch BoundaryError.identityMismatch { }
    check(try Data(contentsOf: destination) == originalBytes, "foreign journal bytes changed")
    do {
        _ = try readJournal(destination, expectedID: original.id)
        fatalError("foreign journal accepted during recovery")
    } catch BoundaryError.identityMismatch { }
}
for i in 0..<64 {
    let destination = root.appendingPathComponent("invalid-generation_\(i).json")
    try JSONEncoder().encode(SafeJournal(id: "ticket_\(i)", generation: 0)).write(to: destination)
    let originalBytes = try Data(contentsOf: destination)
    do {
        try publish(SafeJournal(id: "ticket_\(i)", generation: 1), to: destination)
        fatalError("invalid persisted generation overwritten")
    } catch BoundaryError.unsafe { }
    check(try Data(contentsOf: destination) == originalBytes, "invalid journal evidence changed")
}
print("PASS: 128 cross-ticket substitution and 64 invalid-generation preservation cases (standalone model only)")

// Parent-directory symlinks bypass final-component lstat checks. A journal
// read or publication must reject redirected directories before touching files.
let redirected = root.appendingPathComponent("redirected")
try fm.createDirectory(at: redirected, withIntermediateDirectories: true)
let alias = root.appendingPathComponent("alias")
try fm.createSymbolicLink(at: alias, withDestinationURL: redirected)
for i in 0..<96 {
    let target = redirected.appendingPathComponent("journal_\(i).json")
    let throughAlias = alias.appendingPathComponent("journal_\(i).json")
    let original = Data("PRESERVE-EXTERNAL-JOURNAL-\(i)".utf8)
    try original.write(to: target)
    do { _ = try readJournal(throughAlias); fatalError("redirected journal read accepted") }
    catch BoundaryError.unsafe { }
    do { try publish(SafeJournal(id: "journal_\(i)", generation: 1), to: throughAlias)
         fatalError("redirected journal publication accepted") }
    catch BoundaryError.unsafe { }
    check(try Data(contentsOf: target) == original, "redirected journal modified")
    check(!fm.fileExists(atPath: redirected.appendingPathComponent("journal_\(i).json.tmp").path),
          "unexpected temporary publication")
}
print("PASS: 96 parent-directory symlink read/write rejection cases (standalone model only)")

// A symlink in a grandparent directory must be rejected even when the
// immediate parent is a real directory. Also reject dangling ancestors.
let nestedExternal = root.appendingPathComponent("nested-external")
let nestedReal = nestedExternal.appendingPathComponent("real")
try fm.createDirectory(at: nestedReal, withIntermediateDirectories: true)
let nestedAlias = root.appendingPathComponent("nested-alias")
try fm.createSymbolicLink(at: nestedAlias, withDestinationURL: nestedExternal)
for i in 0..<96 {
    let external = nestedReal.appendingPathComponent("nested_\(i).json")
    let viaAlias = nestedAlias.appendingPathComponent("real/nested_\(i).json")
    let bytes = Data("PRESERVE-NESTED-\(i)".utf8)
    try bytes.write(to: external)
    do { _ = try readJournal(viaAlias); fatalError("nested ancestor symlink read accepted") }
    catch BoundaryError.unsafe { }
    do { try publish(SafeJournal(id: "nested_\(i)", generation: 1), to: viaAlias)
         fatalError("nested ancestor symlink publication accepted") }
    catch BoundaryError.unsafe { }
    check(try Data(contentsOf: external) == bytes, "nested external bytes modified")
}
let missingAlias = root.appendingPathComponent("missing-alias")
try fm.createSymbolicLink(at: missingAlias, withDestinationURL: root.appendingPathComponent("nonexistent"))
do { _ = try readJournal(missingAlias.appendingPathComponent("nested/journal.json"))
     fatalError("dangling ancestor accepted") }
catch BoundaryError.unsafe { }
print("PASS: 96 nested-ancestor symlink isolation cases and dangling ancestor rejection (standalone model only)")
