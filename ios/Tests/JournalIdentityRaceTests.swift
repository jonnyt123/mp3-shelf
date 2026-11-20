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
// Byte equality alone cannot prove ownership when an identical file replaces it.
private func ownedIdentity() throws -> NSNumber {
    guard (try? fm.destinationOfSymbolicLink(atPath: ownedURL.path)) == nil else { throw RecoveryFailure.unsafeJournal }
    let attributes = try fm.attributesOfItem(atPath: ownedURL.path)
    guard (attributes[.type] as? FileAttributeType) == .typeRegular,
          let inode = attributes[.systemFileNumber] as? NSNumber,
          (attributes[.referenceCount] as? NSNumber)?.intValue == 1 else { throw RecoveryFailure.unsafeJournal }
    return inode
}
// Reject shared journal inodes: aliases can mutate evidence during replay.
private func journalIdentity() throws -> NSNumber {
    guard (try? fm.destinationOfSymbolicLink(atPath: journalURL.path)) == nil else { throw RecoveryFailure.unsafeJournal }
    let attributes = try fm.attributesOfItem(atPath: journalURL.path)
    guard (attributes[.type] as? FileAttributeType) == .typeRegular,
          let inode = attributes[.systemFileNumber] as? NSNumber,
          (attributes[.referenceCount] as? NSNumber)?.intValue == 1 else { throw RecoveryFailure.unsafeJournal }
    return inode
}
private func verifyAndFinalize(_ beforeFinalization: () throws -> Void) throws {
    guard (try? fm.destinationOfSymbolicLink(atPath: journalURL.path)) == nil,
          let original = try? Data(contentsOf: journalURL),
          let record = try? JSONDecoder().decode(RecoveryJournal.self, from: original),
          record.ownedNames == ["new.mp3"] else { throw RecoveryFailure.unsafeJournal }
    let originalJournalIdentity = try journalIdentity()
    let originalIdentity = try ownedIdentity()
    guard (try? Data(contentsOf: ownedURL)) == originalAudio else { throw RecoveryFailure.unsafeJournal }
    try beforeFinalization()
    // Revalidate the exact journal bytes before destructive cleanup: a new
    // transaction must never inherit a previous transaction's ownership proof.
    guard (try? fm.destinationOfSymbolicLink(atPath: journalURL.path)) == nil,
          let current = try? Data(contentsOf: journalURL), current == original,
          (try? journalIdentity()) == originalJournalIdentity,
          (try? ownedIdentity()) == originalIdentity,
          (try? Data(contentsOf: ownedURL)) == originalAudio else { throw RecoveryFailure.journalChanged }
    if !record.committed { try fm.removeItem(at: ownedURL) }
    try fm.removeItem(at: journalURL)
}
for committed in [false, true] {
    for mode in 0..<18 {
        for iteration in 0..<4 {
            try? fm.removeItem(at: journalURL)
            try? fm.removeItem(at: ownedURL)
            try originalAudio.write(to: ownedURL)
            try unrelatedAudio.write(to: unrelatedURL)
            let original = RecoveryJournal(generation: UUID(), committed: committed, ownedNames: ["new.mp3"])
            try journalBytes(original).write(to: journalURL, options: .atomic)
            var rejectedForIdentity = false
            var mutationCompleted = false
            do {
                try verifyAndFinalize {
                    // Audio-only mutations must retain the *original* journal
                    // inode; otherwise a missing journal masks an audio
                    // identity regression and yields a false-positive PASS.
                    if ![6, 7, 8, 9, 10, 14, 15, 17].contains(mode) {
                        try fm.removeItem(at: journalURL)
                    }
                    switch mode {
                    case 0: try journalBytes(RecoveryJournal(generation: UUID(), committed: committed, ownedNames: ["new.mp3"])).write(to: journalURL)
                    case 1: try journalBytes(RecoveryJournal(generation: original.generation, committed: !committed, ownedNames: ["new.mp3"])).write(to: journalURL)
                    case 2: try Data("{".utf8).write(to: journalURL)
                    case 3: try fm.createSymbolicLink(at: journalURL, withDestinationURL: unrelatedURL)
                    case 4: try fm.createDirectory(at: journalURL, withIntermediateDirectories: false)
                    case 5: break // removed journal
                    case 6: try Data(repeating: 0x99, count: 8192).write(to: ownedURL, options: .atomic)
                    case 7:
                        try fm.removeItem(at: ownedURL)
                        try fm.createSymbolicLink(at: ownedURL, withDestinationURL: unrelatedURL)
                    case 8:
                        try fm.removeItem(at: ownedURL)
                        try fm.createDirectory(at: ownedURL, withIntermediateDirectories: false)
                    case 9: try originalAudio.write(to: ownedURL, options: .atomic)
                    case 10:
                        let twin = root.appendingPathComponent("identical.mp3")
                        try originalAudio.write(to: twin)
                        try fm.removeItem(at: ownedURL)
                        try fm.createSymbolicLink(at: ownedURL, withDestinationURL: twin)
                    case 11: try journalBytes(original).write(to: journalURL, options: .atomic) // identical bytes, new inode
                    case 13:
                        // A hard link is not a symlink; content-only checks accept
                        // the substituted journal even though its inode changed.
                        let twinJournal = root.appendingPathComponent("hardlinked-recovery.json")
                        try? fm.removeItem(at: twinJournal)
                        try journalBytes(original).write(to: twinJournal)
                        try fm.linkItem(at: twinJournal, to: journalURL)
                    case 14:
                        // Same-byte hard-link substitution of user audio must not
                        // be treated as the transaction's original owned file.
                        let twinAudio = root.appendingPathComponent("hardlinked-audio.mp3")
                        try? fm.removeItem(at: twinAudio)
                        try originalAudio.write(to: twinAudio)
                        try fm.removeItem(at: ownedURL)
                        try fm.linkItem(at: twinAudio, to: ownedURL)
                    case 15:
                        // An empty replacement is never valid owned audio.
                        try Data().write(to: ownedURL, options: .atomic)
                    case 16:
                        // A different hard link to the *same* journal inode can
                        // disappear and reappear while the recovery owns it.
                        // Identity checks must not accidentally delete its peer.
                        let peer = root.appendingPathComponent("peer-recovery.json")
                        try? fm.removeItem(at: peer)
                        try journalBytes(original).write(to: journalURL)
                        try fm.linkItem(at: journalURL, to: peer)
                    case 17:
                        // The owned audio gains a second filesystem name during
                        // finalization. Never delete a file whose ownership is
                        // no longer exclusive, even when its bytes are unchanged.
                        let peer = root.appendingPathComponent("peer-audio.mp3")
                        try? fm.removeItem(at: peer)
                        try fm.linkItem(at: ownedURL, to: peer)
                    case 12:
                        let twinJournal = root.appendingPathComponent("identical-recovery.json")
                        try journalBytes(original).write(to: twinJournal)
                        try fm.createSymbolicLink(at: journalURL, withDestinationURL: twinJournal)
                    default: break
                    }
                    mutationCompleted = true
                }
            } catch RecoveryFailure.journalChanged {
                rejectedForIdentity = true
            } catch {
                throw NSError(domain: "JournalIdentityQA", code: 2, userInfo: [NSLocalizedDescriptionKey: "mode \(mode), iteration \(iteration) failed during setup or with unexpected error: \(error)"])
            }
            try require(mutationCompleted, "mutation never completed for mode \(mode), iteration \(iteration)")
            try require(rejectedForIdentity, "stale replay accepted journal replacement mode \(mode), iteration \(iteration)")
            if mode == 17 { try require(Data(contentsOf: ownedURL) == originalAudio, "linked audio was deleted") }
            else if mode == 14 { try require(Data(contentsOf: ownedURL) == originalAudio, "hard-linked replacement audio deleted") }
            else if mode == 15 { try require(Data(contentsOf: ownedURL).isEmpty, "empty replacement audio overwritten") }
            else if mode == 6 { try require(Data(contentsOf: ownedURL) == Data(repeating: 0x99, count: 8192), "replacement audio overwritten") }
            else if mode == 7 { try require((try? fm.destinationOfSymbolicLink(atPath: ownedURL.path)) != nil, "replacement audio symlink removed") }
            else if mode == 8 { var isDir: ObjCBool = false; try require(fm.fileExists(atPath: ownedURL.path, isDirectory: &isDir) && isDir.boolValue, "replacement audio directory removed") }
            else if mode == 10 { try require((try? fm.destinationOfSymbolicLink(atPath: ownedURL.path)) != nil, "same-byte symlink substitution removed") }
            else { try require(Data(contentsOf: ownedURL) == originalAudio, "stale replay deleted audio") }
            try require(Data(contentsOf: unrelatedURL) == unrelatedAudio, "stale replay damaged unrelated bytes")
            if mode == 16 {
                let peer = root.appendingPathComponent("peer-recovery.json")
                try require(fm.fileExists(atPath: journalURL.path) && fm.fileExists(atPath: peer.path), "shared journal inode deleted")
            }
            if mode == 17 {
                let peer = root.appendingPathComponent("peer-audio.mp3")
                try require(fm.fileExists(atPath: peer.path) && Data(contentsOf: peer) == originalAudio, "shared audio inode deleted")
            }
            if mode == 13 {
                let twinJournal = root.appendingPathComponent("hardlinked-recovery.json")
                try require(fm.fileExists(atPath: journalURL.path), "hard-linked journal substitution removed")
                try require(fm.fileExists(atPath: twinJournal.path), "hard-link source journal removed")
            }
            if mode == 11 { try require(Data(contentsOf: journalURL) == journalBytes(original), "same-byte journal replacement damaged") }
            if mode == 12 { try require((try? fm.destinationOfSymbolicLink(atPath: journalURL.path)) != nil, "same-byte journal symlink substitution removed") }
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
// A journal or recording already shared with another pathname at the start of
// replay must fail before the cleanup callback. These cases differ from the
// mid-replay alias mutations above: no trusted exclusive inode ever existed.
for committed in [false, true] {
    for aliasJournal in [false, true] {
        try? fm.removeItem(at: journalURL)
        try? fm.removeItem(at: ownedURL)
        let alias = root.appendingPathComponent(aliasJournal ? "initial-journal-peer.json" : "initial-audio-peer.mp3")
        try? fm.removeItem(at: alias)
        try originalAudio.write(to: ownedURL)
        try journalBytes(RecoveryJournal(generation: UUID(), committed: committed, ownedNames: ["new.mp3"])).write(to: journalURL)
        let protectedURL = aliasJournal ? journalURL : ownedURL
        let expected = try Data(contentsOf: protectedURL)
        try fm.linkItem(at: protectedURL, to: alias)
        var callbackCalled = false
        var rejected = false
        do {
            try verifyAndFinalize { callbackCalled = true }
        } catch RecoveryFailure.unsafeJournal {
            rejected = true
        }
        try require(rejected, "initial shared inode accepted (journal=\\(aliasJournal), committed=\\(committed))")
        try require(!callbackCalled, "cleanup callback ran with initial shared inode")
        try require(Data(contentsOf: protectedURL) == expected && Data(contentsOf: alias) == expected,
                    "initial hard-link evidence changed during rejected replay")
        try require(fm.fileExists(atPath: journalURL.path) && fm.fileExists(atPath: ownedURL.path),
                    "initial shared inode caused destructive cleanup")
    }
}
print("PASS: 144 journal/audio replacement/replay isolation scenarios; 4 initial-alias rejections; 2 uncontested controls")
