import Foundation

// Run: swift ios/Tests/StageCleanupGenerationIsolationTests.swift
// Independent filesystem contract, not a production URLSession integration test.
private enum Failure: Error { case unsafeCleanup }
private struct Receipt: Codable, Equatable {
    let ticket: UUID
    let generation: Int
    let stagedName: String
}
private let fm = FileManager.default
private let root = fm.temporaryDirectory.appendingPathComponent("mp3-stage-generation-\(UUID())")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
private let stage = root.appendingPathComponent("download.part")
private let journal = root.appendingPathComponent("download.json")
private let older = Receipt(ticket: UUID(), generation: 1, stagedName: "download.part")
private let newer = Receipt(ticket: UUID(), generation: 2, stagedName: "download.part")
private let oldBytes = Data(repeating: 0x31, count: 8192)
private let newBytes = Data(repeating: 0x72, count: 8192)
private func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw NSError(domain: "StageCleanupGenerationIsolation", code: 1,
        userInfo: [NSLocalizedDescriptionKey: message]) }
}
private func inode(_ url: URL) throws -> UInt64 {
    let attrs = try fm.attributesOfItem(atPath: url.path)
    guard attrs[.type] as? FileAttributeType == .typeRegular,
          let number = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value,
          (attrs[.referenceCount] as? NSNumber)?.intValue == 1,
          (try? fm.destinationOfSymbolicLink(atPath: url.path)) == nil else {
        throw Failure.unsafeCleanup
    }
    return number
}
private func write(_ receipt: Receipt, bytes: Data) throws {
    try bytes.write(to: stage, options: .atomic)
    try JSONEncoder().encode(receipt).write(to: journal, options: .atomic)
}
private func cleanup(_ expected: Receipt, stageInode: UInt64, journalInode: UInt64,
                     stageBytes: Data,
                     beforeDelete: () throws -> Void = {}) throws {
    guard (try? inode(journal)) == journalInode,
          let bytes = try? Data(contentsOf: journal),
          let current = try? JSONDecoder().decode(Receipt.self, from: bytes),
          current == expected, current.stagedName == stage.lastPathComponent,
          try inode(stage) == stageInode,
          (try? Data(contentsOf: stage)) == stageBytes else { throw Failure.unsafeCleanup }
    try beforeDelete()
    // Detect replacement after asynchronous completion. This reference model
    // does not prove atomicity against a writer racing after this last check.
    guard (try? inode(journal)) == journalInode,
          let latest = try? Data(contentsOf: journal), latest == bytes,
          let decoded = try? JSONDecoder().decode(Receipt.self, from: latest),
          decoded == expected, try inode(stage) == stageInode,
          (try? Data(contentsOf: stage)) == stageBytes else {
        throw Failure.unsafeCleanup
    }
    try fm.removeItem(at: stage)
    guard (try? inode(journal)) == journalInode,
          let final = try? Data(contentsOf: journal), final == bytes else {
        throw Failure.unsafeCleanup
    }
    try fm.removeItem(at: journal)
}
var passed = 0
for scenario in ["new-generation", "same-bytes-new-inode", "symlink-stage", "journal-replaced", "removed-stage", "journal-symlink", "journal-same-bytes-new-inode", "journal-hardlink", "stage-hardlink", "stage-mutated-in-place", "journal-mutated-in-place", "journal-corrupted-in-place", "stage-truncated-in-place", "stage-directory-replacement", "same-generation-different-ticket"] {
    try write(older, bytes: oldBytes)
    let originalInode = try inode(stage)
    let originalJournalInode = try inode(journal)
    var rejected = false
    do {
        try cleanup(older, stageInode: originalInode, journalInode: originalJournalInode,
                    stageBytes: oldBytes, beforeDelete: {
            switch scenario {
            case "new-generation": try write(newer, bytes: newBytes)
            case "same-generation-different-ticket":
                try write(Receipt(ticket: newer.ticket, generation: older.generation,
                                  stagedName: older.stagedName), bytes: newBytes)
            case "stage-truncated-in-place":
                let handle = try FileHandle(forWritingTo: stage)
                defer { try? handle.close() }
                try handle.truncate(atOffset: 0)
            case "stage-directory-replacement":
                try fm.removeItem(at: stage)
                try fm.createDirectory(at: stage, withIntermediateDirectories: false)
            case "journal-corrupted-in-place":
                let handle = try FileHandle(forWritingTo: journal)
                defer { try? handle.close() }
                try handle.truncate(atOffset: 0)
                try handle.write(contentsOf: Data("{invalid-json".utf8))
            case "same-bytes-new-inode":
                try fm.removeItem(at: stage)
                try oldBytes.write(to: stage)
            case "symlink-stage":
                try fm.removeItem(at: stage)
                try fm.createSymbolicLink(at: stage, withDestinationURL: journal)
            case "journal-replaced":
                try JSONEncoder().encode(newer).write(to: journal, options: .atomic)
            case "journal-symlink":
                try fm.removeItem(at: journal)
                try fm.createSymbolicLink(at: journal, withDestinationURL: stage)
            case "journal-same-bytes-new-inode":
                try fm.removeItem(at: journal)
                try JSONEncoder().encode(older).write(to: journal)
            case "journal-hardlink":
                let alias = root.appendingPathComponent("journal-alias")
                try fm.linkItem(at: journal, to: alias)
            case "stage-hardlink":
                let alias = root.appendingPathComponent("stage-alias")
                try fm.linkItem(at: stage, to: alias)
            case "stage-mutated-in-place":
                let handle = try FileHandle(forWritingTo: stage)
                defer { try? handle.close() }
                try handle.write(contentsOf: newBytes)
            case "journal-mutated-in-place":
                let handle = try FileHandle(forWritingTo: journal)
                defer { try? handle.close() }
                try handle.truncate(atOffset: 0)
                try handle.write(contentsOf: JSONEncoder().encode(newer))
            default: try fm.removeItem(at: stage)
            }
        })
    } catch { rejected = true }
    try require(rejected, "\(scenario): stale callback cleanup accepted")
    try require(fm.fileExists(atPath: journal.path), "\(scenario): recovery journal lost")
    if scenario.hasPrefix("journal-") || scenario == "stage-hardlink" {
        try require(try Data(contentsOf: stage) == oldBytes, "\(scenario): audio deleted on unsafe journal")
    }
    if scenario == "new-generation" || scenario == "same-generation-different-ticket" {
        try require(try Data(contentsOf: stage) == newBytes, "new ticket audio deleted")
        try require(try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: journal)) == (scenario == "new-generation" ? newer : Receipt(ticket: newer.ticket, generation: older.generation, stagedName: older.stagedName)),
                    "new ticket journal overwritten")
    }
    if scenario == "stage-truncated-in-place" {
        try require(try Data(contentsOf: stage).isEmpty, "truncated stage was removed or rewritten")
    }
    if scenario == "stage-directory-replacement" {
        var isDirectory: ObjCBool = false
        try require(fm.fileExists(atPath: stage.path, isDirectory: &isDirectory) && isDirectory.boolValue,
                    "replacement directory was removed")
    }
    if scenario == "journal-corrupted-in-place" {
        try require(try Data(contentsOf: journal) == Data("{invalid-json".utf8),
                    "corrupted journal was removed or overwritten")
    }
    if scenario == "stage-mutated-in-place" {
        try require(try Data(contentsOf: stage) == newBytes, "mutated stage was deleted or rewritten")
    }
    if scenario == "same-bytes-new-inode" {
        try require(try Data(contentsOf: stage) == oldBytes, "replacement stage removed")
    }
    passed += 1
}
try write(older, bytes: oldBytes)
try cleanup(older, stageInode: inode(stage), journalInode: inode(journal), stageBytes: oldBytes)
try require(!fm.fileExists(atPath: stage.path) && !fm.fileExists(atPath: journal.path),
            "successful cleanup left orphan files")
passed += 1
print("PASS: \(passed) stage cleanup generation and replacement scenarios")
