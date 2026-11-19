import Foundation

// Standalone Foundation regression model; does not execute production restore.
// Run: swift ios/Tests/JournalIdentityRaceTests.swift
private struct RecoveryJournal: Codable, Equatable {
    let generation: UUID
    let committed: Bool
    let ownedNames: [String]
}
private enum RecoveryFailure: Error { case journalChanged, unsafeJournal }
private let fm = FileManager.default
private let root = fm.temporaryDirectory.appendingPathComponent("journal-identity-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
private let journalURL = root.appendingPathComponent("recovery.json")
private let ownedURL = root.appendingPathComponent("new.mp3")
private let unrelatedURL = root.appendingPathComponent("unrelated.mp3")
private let originalAudio = Data(repeating: 0x4a, count: 8192)
private let unrelatedAudio = Data(repeating: 0x6b, count: 4096)
private func require(_ condition: @autoclosure () throws -> Bool, _ description: String) throws {
    if try !condition() { throw NSError(domain: "JournalIdentityQA", code: 1, userInfo: [NSLocalizedDescriptionKey: description]) }
}
private func journalBytes(_ value: RecoveryJournal) throws -> Data { try JSONEncoder().encode(value) }
private func verifyAndFinalize(_ beforeFinalization: () throws -> Void) throws {
    guard (try? fm.destinationOfSymbolicLink(atPath: journalURL.path)) == nil,
          let original = try? Data(contentsOf: journalURL),
          let record = try? JSONDecoder().decode(RecoveryJournal.self, from: original),
          record.ownedNames == ["new.mp3"] else { throw RecoveryFailure.unsafeJournal }
    guard (try? Data(contentsOf: ownedURL)) == originalAudio else { throw RecoveryFailure.unsafeJournal }
    try beforeFinalization()
    // Revalidate the exact journal bytes before destructive cleanup: a new
    // transaction must never inherit a previous transaction's ownership proof.
    guard (try? fm.destinationOfSymbolicLink(atPath: journalURL.path)) == nil,
          let current = try? Data(contentsOf: journalURL), current == original,
          (try? Data(contentsOf: ownedURL)) == originalAudio else { throw RecoveryFailure.journalChanged }
    if !record.committed { try fm.removeItem(at: ownedURL) }
    try fm.removeItem(at: journalURL)
}
for committed in [false, true] {
    for mode in 0..<6 {
        for iteration in 0..<4 {
            try? fm.removeItem(at: journalURL)
            try? fm.removeItem(at: ownedURL)
            try originalAudio.write(to: ownedURL)
            try unrelatedAudio.write(to: unrelatedURL)
            let original = RecoveryJournal(generation: UUID(), committed: committed, ownedNames: ["new.mp3"])
            try journalBytes(original).write(to: journalURL, options: .atomic)
            var rejected = false
            do {
                try verifyAndFinalize {
                    try fm.removeItem(at: journalURL)
                    switch mode {
                    case 0: try journalBytes(RecoveryJournal(generation: UUID(), committed: committed, ownedNames: ["new.mp3"])).write(to: journalURL)
                    case 1: try journalBytes(RecoveryJournal(generation: original.generation, committed: !committed, ownedNames: ["new.mp3"])).write(to: journalURL)
                    case 2: try Data("{".utf8).write(to: journalURL)
                    case 3: try fm.createSymbolicLink(at: journalURL, withDestinationURL: unrelatedURL)
                    case 4: try fm.createDirectory(at: journalURL, withIntermediateDirectories: false)
                    default: break
                    }
                }
            } catch { rejected = true }
            try require(rejected, "stale replay accepted journal replacement mode \(mode), iteration \(iteration)")
            try require(Data(contentsOf: ownedURL) == originalAudio, "stale replay deleted audio")
            try require(Data(contentsOf: unrelatedURL) == unrelatedAudio, "stale replay damaged unrelated bytes")
            if mode == 3 { try require((try? fm.destinationOfSymbolicLink(atPath: journalURL.path)) != nil, "symlink evidence lost") }
            if mode == 4 { var isDir: ObjCBool = false; try require(fm.fileExists(atPath: journalURL.path, isDirectory: &isDir) && isDir.boolValue, "directory substitution removed") }
        }
    }
}
for committed in [false, true] {
    try? fm.removeItem(at: journalURL)
    try? fm.removeItem(at: ownedURL)
    try originalAudio.write(to: ownedURL)
    try journalBytes(RecoveryJournal(generation: UUID(), committed: committed, ownedNames: ["new.mp3"])).write(to: journalURL)
    try verifyAndFinalize {}
    try require(!fm.fileExists(atPath: journalURL.path), "successful replay retained stale journal")
    try require(fm.fileExists(atPath: ownedURL.path) == committed, "commit state changed audio ownership")
}
print("PASS: 48 journal replacement/replay isolation scenarios; 2 uncontested controls")
