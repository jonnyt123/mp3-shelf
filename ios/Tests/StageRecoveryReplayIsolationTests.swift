import Foundation

// Run: swift ios/Tests/StageRecoveryReplayIsolationTests.swift
// Standalone filesystem regression model. It does not substitute for an iOS
// URLSession delegate integration test or an Xcode build.
private struct Journal: Codable, Equatable {
    let ticket: UUID
    let generation: UInt64
    let stageName: String
    let expectedBytes: Int
}
private enum RecoveryError: Error { case unsafe }
private let fm = FileManager.default
private let root = fm.temporaryDirectory.appendingPathComponent("mp3-replay-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
private let stage = root.appendingPathComponent("audio.part")
private let journal = root.appendingPathComponent("audio.json")
private let first = Journal(ticket: UUID(), generation: 1, stageName: "audio.part", expectedBytes: 8192)
private let next = Journal(ticket: UUID(), generation: 2, stageName: "audio.part", expectedBytes: 8192)
private let oldAudio = Data(repeating: 0x34, count: 8192)
private let newAudio = Data(repeating: 0x56, count: 8192)

private func identity(_ url: URL) throws -> UInt64 {
    let properties = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
    guard properties.isSymbolicLink != true, properties.isRegularFile == true,
          let inode = (try fm.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber)?.uint64Value
    else { throw RecoveryError.unsafe }
    return inode
}
private func persist(_ receipt: Journal, bytes: Data) throws {
    try bytes.write(to: stage, options: .atomic)
    try JSONEncoder().encode(receipt).write(to: journal, options: .atomic)
}
private func recover(_ expected: Journal, beforeCommit: () throws -> Void = {}) throws -> Data {
    // Capture both identities and exact journal bytes before any asynchronous
    // operation. A ticket generation alone is insufficient to identify media.
    let stageInode = try identity(stage)
    let journalInode = try identity(journal)
    let original = try Data(contentsOf: journal)
    guard let decoded = try? JSONDecoder().decode(Journal.self, from: original),
          decoded == expected, decoded.stageName == stage.lastPathComponent,
          decoded.expectedBytes > 0,
          let bytes = try? Data(contentsOf: stage), bytes.count == decoded.expectedBytes
    else { throw RecoveryError.unsafe }
    try beforeCommit()
    guard try identity(stage) == stageInode,
          try identity(journal) == journalInode,
          try Data(contentsOf: journal) == original,
          try Data(contentsOf: stage) == bytes
    else { throw RecoveryError.unsafe }
    return bytes
}
private func assert(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else {
        throw NSError(domain: "StageRecoveryReplayIsolation", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: message])
    }
}
var passed = 0
for scenario in ["baseline", "replacement-ticket", "same-generation-new-ticket",
                 "same-bytes-new-stage", "truncated-stage", "journal-symlink",
                 "journal-corruption", "stage-directory", "same-size-mutated-audio",
                 "stage-symlink", "journal-replaced-same-bytes", "stage-replaced-same-bytes",
                 "journal-ticket-mutated-in-place", "stage-hardlink-mutated", "journal-hardlink-mutated", "journal-symlink-retargeted"] {
    try persist(first, bytes: oldAudio)
    let expectedSuccess = scenario == "baseline"
    var recovered: Data?
    do {
        recovered = try recover(first) {
            switch scenario {
            case "replacement-ticket": try persist(next, bytes: newAudio)
            case "same-generation-new-ticket":
                try persist(Journal(ticket: next.ticket, generation: first.generation,
                                    stageName: first.stageName, expectedBytes: first.expectedBytes),
                            bytes: newAudio)
            case "same-bytes-new-stage":
                try fm.removeItem(at: stage)
                try oldAudio.write(to: stage)
            case "truncated-stage":
                let handle = try FileHandle(forWritingTo: stage)
                defer { try? handle.close() }
                try handle.truncate(atOffset: 12)
            case "journal-symlink":
                try fm.removeItem(at: journal)
                try fm.createSymbolicLink(at: journal, withDestinationURL: stage)
            case "journal-corruption":
                let handle = try FileHandle(forWritingTo: journal)
                defer { try? handle.close() }
                try handle.truncate(atOffset: 0)
                try handle.write(contentsOf: Data("{broken".utf8))
            case "stage-symlink":
                try fm.removeItem(at: stage)
                try fm.createSymbolicLink(at: stage, withDestinationURL: journal)
            case "journal-replaced-same-bytes":
                let saved = try Data(contentsOf: journal)
                try fm.removeItem(at: journal)
                try saved.write(to: journal)
            case "stage-replaced-same-bytes":
                // Same bytes are not sufficient: another writer owns the new inode.
                try fm.removeItem(at: stage)
                try oldAudio.write(to: stage)
            case "journal-hardlink-mutated":
                // A second path can mutate the original journal inode in place.
                let alias = root.appendingPathComponent("journal-alias-\(UUID().uuidString)")
                try fm.linkItem(at: journal, to: alias)
                defer { try? fm.removeItem(at: alias) }
                let handle = try FileHandle(forWritingTo: alias)
                defer { try? handle.close() }
                try handle.truncate(atOffset: 0)
                try handle.write(contentsOf: Data("{invalid".utf8))
            case "journal-symlink-retargeted":
                // The original journal is removed and replaced with a link to
                // another regular file. Never follow that link during replay.
                let decoy = root.appendingPathComponent("journal-decoy-\(UUID().uuidString)")
                try Data(contentsOf: journal).write(to: decoy)
                defer { try? fm.removeItem(at: decoy) }
                try fm.removeItem(at: journal)
                try fm.createSymbolicLink(at: journal, withDestinationURL: decoy)
            case "journal-ticket-mutated-in-place":
                let replacement = try JSONEncoder().encode(Journal(ticket: next.ticket,
                    generation: first.generation, stageName: first.stageName,
                    expectedBytes: first.expectedBytes))
                let handle = try FileHandle(forWritingTo: journal)
                defer { try? handle.close() }
                try handle.truncate(atOffset: 0)
                try handle.write(contentsOf: replacement)
            case "stage-hardlink-mutated":
                let alias = root.appendingPathComponent("stage-alias-\(UUID().uuidString)")
                try fm.linkItem(at: stage, to: alias)
                defer { try? fm.removeItem(at: alias) }
                let handle = try FileHandle(forWritingTo: alias)
                defer { try? handle.close() }
                try handle.write(contentsOf: newAudio)
            case "stage-directory":
                try fm.removeItem(at: stage)
                try fm.createDirectory(at: stage, withIntermediateDirectories: false)
            case "same-size-mutated-audio":
                let handle = try FileHandle(forWritingTo: stage)
                defer { try? handle.close() }
                try handle.write(contentsOf: newAudio)
            default: break
            }
        }
    } catch RecoveryError.unsafe {
        // Expected refusal: neither a replaced ticket nor modified audio may be replayed.
    } catch {
        // Filesystem failures are also a safe refusal, but report their scenario
        // rather than silently treating an unexpected failure as a passing replay.
        if expectedSuccess { throw error }
        print("INFO: \(scenario) refused with filesystem error: \(error)")
    }
    try assert((recovered != nil) == expectedSuccess, "\(scenario): wrong replay decision")
    if expectedSuccess {
        try assert(recovered == oldAudio, "baseline media changed")
    } else {
        try assert(fm.fileExists(atPath: journal.path), "\(scenario): journal removed")
        if scenario == "replacement-ticket" || scenario == "same-generation-new-ticket" {
            try assert(try Data(contentsOf: stage) == newAudio,
                       "\(scenario): replacement recording changed")
        }
    }
    passed += 1
}
print("PASS: \(passed) stage recovery replay isolation scenarios")
