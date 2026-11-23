import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// Standalone POSIX filesystem model, NOT production restore integration.
// swift -swift-version 6 ios/Tests/ConcurrentRestorePublicationTests.swift
enum PublishFailure: Error { case unsafeStage, conflict, io(Int32) }
func publish(_ stage: URL, to destination: URL) throws {
    let attrs = try FileManager.default.attributesOfItem(atPath: stage.path)
    guard attrs[.type] as? FileAttributeType == .typeRegular,
          (attrs[.size] as? NSNumber)?.int64Value ?? 0 > 0,
          (attrs[.referenceCount] as? NSNumber)?.intValue == 1 else { throw PublishFailure.unsafeStage }
    // link(2) creates the destination exclusively; rename(2) would overwrite.
    let result = stage.path.withCString { a in destination.path.withCString { b in link(a, b) } }
    guard result == 0 else {
        let code = errno
        if code == EEXIST { throw PublishFailure.conflict }
        throw PublishFailure.io(code)
    }
    try FileManager.default.removeItem(at: stage)
}
func check(_ ok: @autoclosure () throws -> Bool, _ message: String) {
    guard (try? ok()) == true else { fatalError(message) }
}
final class Outcomes: @unchecked Sendable {
    private let lock = NSLock()
    private var winners: [Int] = []
    private var conflicts = 0
    private var errors: [String] = []
    func win(_ i: Int) { lock.lock(); defer { lock.unlock() }; winners.append(i) }
    func conflict() { lock.lock(); defer { lock.unlock() }; conflicts += 1 }
    func error(_ e: Error) { lock.lock(); defer { lock.unlock() }; errors.append(String(describing: e)) }
    func snapshot() -> ([Int], Int, [String]) {
        lock.lock(); defer { lock.unlock() }
        return (winners, conflicts, errors)
    }
}
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("mp3-exclusive-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let outside = root.appendingPathComponent("owned.mp3")
let original = Data((0..<16384).map { UInt8($0 % 251) })
try original.write(to: outside)
for round in 0..<48 {
    let target = root.appendingPathComponent("record-\(round).mp3")
    let bytes = (0..<6).map { Data(repeating: UInt8($0 + 1), count: 4096 + $0) }
    let stages = (0..<6).map { root.appendingPathComponent("stage-\(round)-\($0)") }
    for i in 0..<6 { try bytes[i].write(to: stages[i]) }
    let outcomes = Outcomes()
    let group = DispatchGroup()
    let queue = DispatchQueue(label: "qa.restore.race", attributes: .concurrent)
    for i in 0..<6 {
        group.enter()
        queue.async {
            defer { group.leave() }
            do { try publish(stages[i], to: target); outcomes.win(i) }
            catch PublishFailure.conflict { outcomes.conflict() }
            catch { outcomes.error(error) }
        }
    }
    group.wait()
    let (winners, conflicts, errors) = outcomes.snapshot()
    check(errors.isEmpty && winners.count == 1 && conflicts == 5, "unexpected race outcome \(round): \(errors)")
    check((try Data(contentsOf: target)) == bytes[winners[0]], "winner audio corrupted")
    check(!fm.fileExists(atPath: stages[winners[0]].path), "winner stage retained")
    for i in 0..<6 where i != winners[0] {
        check((try Data(contentsOf: stages[i])) == bytes[i], "loser audio discarded")
    }
    check((try Data(contentsOf: outside)) == original, "unrelated user audio changed")
}
let occupied = root.appendingPathComponent("occupied.mp3")
let pending = root.appendingPathComponent("pending.part")
try original.write(to: occupied)
try Data(repeating: 0xAA, count: 5000).write(to: pending)
do { try publish(pending, to: occupied); fatalError("overwrote occupied audio") }
catch PublishFailure.conflict { }
check((try Data(contentsOf: occupied)) == original, "occupied audio modified")
check(fm.fileExists(atPath: pending.path), "pending audio discarded on conflict")
let symlink = root.appendingPathComponent("linked.part")
let linkedTarget = root.appendingPathComponent("linked.mp3")
try fm.createSymbolicLink(at: symlink, withDestinationURL: outside)
do { try publish(symlink, to: linkedTarget); fatalError("accepted symlink stage") }
catch PublishFailure.unsafeStage { }
check(!fm.fileExists(atPath: linkedTarget.path), "published symlink")
check((try Data(contentsOf: outside)) == original, "external audio modified")

func expectUnsafe(_ stage: URL, _ destination: URL, _ reason: String) throws {
    do { try publish(stage, to: destination); fatalError("accepted unsafe stage: \(reason)") }
    catch PublishFailure.unsafeStage { }
    check(!fm.fileExists(atPath: destination.path), "unsafe stage published: \(reason)")
    check(fm.fileExists(atPath: stage.path), "unsafe stage discarded: \(reason)")
}
let emptyStage = root.appendingPathComponent("empty.part")
try Data().write(to: emptyStage)
try expectUnsafe(emptyStage, root.appendingPathComponent("empty.mp3"), "zero-length stage")

let hardlinkStage = root.appendingPathComponent("alias.part")
let hardlinkDestination = root.appendingPathComponent("alias.mp3")
let hardlinkResult = outside.path.withCString { source in
    hardlinkStage.path.withCString { destination in link(source, destination) }
}
check(hardlinkResult == 0, "could not construct hardlink fixture")
try expectUnsafe(hardlinkStage, hardlinkDestination, "multiply-linked user audio")
check((try Data(contentsOf: outside)) == original, "hardlink target changed")

let occupiedSymlink = root.appendingPathComponent("occupied-symlink.mp3")
let symlinkStage = root.appendingPathComponent("symlink-target.part")
try Data(repeating: 0xBB, count: 1024).write(to: symlinkStage)
try fm.createSymbolicLink(at: occupiedSymlink, withDestinationURL: outside)
do { try publish(symlinkStage, to: occupiedSymlink); fatalError("replaced occupied symlink") }
catch PublishFailure.conflict { }
check((try Data(contentsOf: outside)) == original, "symlink target overwritten")
check(fm.fileExists(atPath: symlinkStage.path), "stage lost on symlink collision")

let occupiedDirectory = root.appendingPathComponent("occupied-directory.mp3")
let directoryStage = root.appendingPathComponent("directory-target.part")
try fm.createDirectory(at: occupiedDirectory, withIntermediateDirectories: false)
try Data(repeating: 0xCC, count: 1024).write(to: directoryStage)
do { try publish(directoryStage, to: occupiedDirectory); fatalError("replaced occupied directory") }
catch PublishFailure.conflict { }
check(fm.fileExists(atPath: directoryStage.path), "stage lost on directory collision")
check((try fm.attributesOfItem(atPath: occupiedDirectory.path))[.type] as? FileAttributeType == .typeDirectory, "directory replaced")
print("PASS: 288 concurrent attempts, 48 winners, 240 retained losers, occupied destination, symlink, directory, empty and hardlink stage rejection")
print("LIMITATION: model-only; production restore, macOS/Xcode and physical iPhone UNVERIFIED")
