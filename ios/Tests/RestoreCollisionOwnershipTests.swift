import Foundation

// Independent filesystem model: collision-safe restore, not MusicLibrary execution.
// Run: swift ios/Tests/RestoreCollisionOwnershipTests.swift
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("restore-collision-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let live = root.appendingPathComponent("live")
let stage = root.appendingPathComponent("stage")
try fm.createDirectory(at: live, withIntermediateDirectories: true)
try fm.createDirectory(at: stage, withIntermediateDirectories: true)
let original = Data(repeating: 0x31, count: 4096)
let incoming = Data(repeating: 0x52, count: 8192)
let neighbor = Data(repeating: 0x73, count: 1024)
let target = live.appendingPathComponent("song.mp3")
let other = live.appendingPathComponent("other.mp3")
let staged = stage.appendingPathComponent("song.mp3")
try neighbor.write(to: other)

func check(_ value: @autoclosure () throws -> Bool) throws {
    let ok = try value()
    precondition(ok)
}
enum RestoreError: Error { case collision, invalidStage }
func isSafeStage() -> Bool {
    guard (try? fm.destinationOfSymbolicLink(atPath: staged.path)) == nil,
          let attrs = try? fm.attributesOfItem(atPath: staged.path),
          attrs[.type] as? FileAttributeType == .typeRegular,
          (attrs[.referenceCount] as? NSNumber)?.intValue == 1 else { return false }
    return true
}
// Sequential collision model only: production needs atomic no-replace semantics
// to close the race between destination inspection and publication.
func publish() throws -> Bool {
    guard isSafeStage() else { throw RestoreError.invalidStage }
    guard !fm.fileExists(atPath: target.path) else { throw RestoreError.collision }
    try fm.moveItem(at: staged, to: target)
    return true
}
func recover(ownedByAttempt: Bool, committed: Bool) throws {
    if ownedByAttempt && !committed && fm.fileExists(atPath: target.path) {
        try fm.removeItem(at: target)
    }
}
func reset() throws {
    for url in [target, staged] where fm.fileExists(atPath: url.path) ||
        (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil {
        try fm.removeItem(at: url)
    }
}
for _ in 0..<50 {
    try reset()
    try original.write(to: target)
    try incoming.write(to: staged)
    do { _ = try publish(); fatalError("collision overwritten") }
    catch RestoreError.collision {}
    try recover(ownedByAttempt: false, committed: false)
    try check(Data(contentsOf: target) == original)
    try check(Data(contentsOf: staged) == incoming)

    try fm.removeItem(at: staged)
    try fm.createSymbolicLink(at: staged, withDestinationURL: other)
    do { _ = try publish(); fatalError("symlink accepted") }
    catch RestoreError.invalidStage {}
    try fm.removeItem(at: staged)
    try fm.linkItem(at: other, to: staged)
    do { _ = try publish(); fatalError("hardlink accepted") }
    catch RestoreError.invalidStage {}

    try reset()
    try incoming.write(to: staged)
    let owned = try publish()
    try check(Data(contentsOf: target) == incoming)
    try recover(ownedByAttempt: owned, committed: false)
    precondition(!fm.fileExists(atPath: target.path))
    try check(Data(contentsOf: other) == neighbor)

    try incoming.write(to: staged)
    let committedOwner = try publish()
    try recover(ownedByAttempt: committedOwner, committed: true)
    try check(Data(contentsOf: target) == incoming)
}
print("PASS: 50 collision, symlink, hardlink, rollback and committed-media preservation rounds")
