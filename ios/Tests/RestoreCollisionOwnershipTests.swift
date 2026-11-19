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
// Atomic hard-link publication: link(2) must fail if the destination already exists.
// Unlike an existence-check followed by move, this does not replace a racing writer.
// This remains an independent filesystem model, not a MusicLibrary implementation.
func publishFile(from source: URL, to destination: URL) throws {
    guard (try? fm.destinationOfSymbolicLink(atPath: source.path)) == nil,
          let attrs = try? fm.attributesOfItem(atPath: source.path),
          attrs[.type] as? FileAttributeType == .typeRegular,
          (attrs[.referenceCount] as? NSNumber)?.intValue == 1 else {
        throw RestoreError.invalidStage
    }
    do {
        try fm.linkItem(at: source, to: destination)
    } catch {
        // A concurrent writer may have won; never touch its destination.
        if fm.fileExists(atPath: destination.path) { throw RestoreError.collision }
        throw error
    }
    // Publication succeeded. The destination now owns its inode even if
    // removing the temporary link fails; the caller must journal that state.
    try fm.removeItem(at: source)
}
func publish() throws -> Bool {
    try publishFile(from: staged, to: target)
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
// Race regression: each worker publishes a different payload to one absent name.
// Exactly one atomic link may succeed; no failed worker may replace winner bytes.
let raceRoot = root.appendingPathComponent("race")
try fm.createDirectory(at: raceRoot, withIntermediateDirectories: true)
let raceTarget = raceRoot.appendingPathComponent("shared.mp3")
for round in 0..<25 {
    if fm.fileExists(atPath: raceTarget.path) { try fm.removeItem(at: raceTarget) }
    let sources = try (0..<16).map { index -> URL in
        let source = raceRoot.appendingPathComponent("source-\(round)-\(index).mp3")
        try Data(repeating: UInt8(index + 1), count: 2048).write(to: source)
        return source
    }
    let group = DispatchGroup()
    let lock = NSLock()
    var winners: [Int] = []
    var failures: [Error] = []
    for (index, source) in sources.enumerated() {
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            do {
                try publishFile(from: source, to: raceTarget)
                lock.lock(); winners.append(index); lock.unlock()
            } catch RestoreError.collision {
                // Expected: another publisher owns the destination.
            } catch {
                lock.lock(); failures.append(error); lock.unlock()
            }
        }
    }
    group.wait()
    precondition(failures.isEmpty, "unexpected publication failure: \(failures)")
    precondition(winners.count == 1, "multiple writers published")
    try check(Data(contentsOf: raceTarget) == Data(repeating: UInt8(winners[0] + 1), count: 2048))
    for (index, source) in sources.enumerated() where index != winners[0] {
        try check(Data(contentsOf: source) == Data(repeating: UInt8(index + 1), count: 2048))
    }
    for source in sources where fm.fileExists(atPath: source.path) { try fm.removeItem(at: source) }
}
print("PASS: 50 restore ownership rounds and 25 x 16 atomic publication races")


// Interrupted publication regression: a hard link was installed, but unlinking
// the stage failed before the journal could mark the operation committed.
// Recovery must identify the same inode, not merely the same filename/bytes.
let interruptedRoot = root.appendingPathComponent("interrupted")
try fm.createDirectory(at: interruptedRoot, withIntermediateDirectories: true)
let interruptedStage = interruptedRoot.appendingPathComponent("stage.mp3")
let interruptedTarget = interruptedRoot.appendingPathComponent("target.mp3")
let interruptedPayload = Data(repeating: 0xA7, count: 32768)
try interruptedPayload.write(to: interruptedStage)
try fm.linkItem(at: interruptedStage, to: interruptedTarget)
func inode(_ url: URL) throws -> NSNumber {
    let attrs = try fm.attributesOfItem(atPath: url.path)
    guard let number = attrs[.systemFileNumber] as? NSNumber else {
        throw RestoreError.invalidStage
    }
    return number
}
try check(inode(interruptedStage) == inode(interruptedTarget))
try check(Data(contentsOf: interruptedTarget) == interruptedPayload)
// A crash after linking leaves both paths. Replaying a cleanup of the stage
// must preserve the published destination and its original bytes.
try fm.removeItem(at: interruptedStage)
try check(Data(contentsOf: interruptedTarget) == interruptedPayload)
// A later unrelated writer may reuse the stage pathname; recovery must never
// delete it based solely on the old journal's pathname.
let unrelatedPayload = Data(repeating: 0xD4, count: 1024)
try unrelatedPayload.write(to: interruptedStage)
try check(inode(interruptedStage) != inode(interruptedTarget))
try check(Data(contentsOf: interruptedStage) == unrelatedPayload)
try check(Data(contentsOf: interruptedTarget) == interruptedPayload)
// Two identical byte sequences are not proof of ownership. An independently
// created destination must not be removed by a stale restore attempt.
let identicalTarget = interruptedRoot.appendingPathComponent("identical.mp3")
try interruptedPayload.write(to: identicalTarget)
try check(Data(contentsOf: identicalTarget) == Data(contentsOf: interruptedTarget))
try check(inode(identicalTarget) != inode(interruptedTarget))
print("PASS: interrupted link publication, stage reuse and inode ownership isolation")
