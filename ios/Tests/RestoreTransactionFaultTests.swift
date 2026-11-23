import Foundation

// Standalone fault-injection contract: swift ios/Tests/RestoreTransactionFaultTests.swift
// This tests a filesystem model, NOT the production archive restore implementation.
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("mp3-restore-fault-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let oldAudio = Data(repeating: 0x41, count: 4096)
let newAudio = Data(repeating: 0x42, count: 8192)
let oldIndex = Data("old-library".utf8)
let newIndex = Data("new-library".utf8)
enum Fault: Error { case injected(Int), unsafe }
func put(_ bytes: Data, _ path: URL) throws { try bytes.write(to: path, options: .atomic) }
func snapshot(_ folder: URL) throws -> [String: Data] {
    var output: [String: Data] = [:]
    for name in ["song.mp3", "library.json"] {
        output[name] = try Data(contentsOf: folder.appendingPathComponent(name))
    }
    return output
}
func reset() throws -> URL {
    let live = root.appendingPathComponent("live")
    if fm.fileExists(atPath: live.path) { try fm.removeItem(at: live) }
    try fm.createDirectory(at: live, withIntermediateDirectories: true)
    try put(oldAudio, live.appendingPathComponent("song.mp3"))
    try put(oldIndex, live.appendingPathComponent("library.json"))
    return live
}
func restore(_ live: URL, fault: Int?, corrupt: Bool = false) throws {
    let stage = root.appendingPathComponent("stage-\(UUID().uuidString)")
    try fm.createDirectory(at: stage, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: stage) }
    if fault == 0 { throw Fault.injected(0) }
    try put(newAudio, stage.appendingPathComponent("song.mp3"))
    if fault == 1 { throw Fault.injected(1) }
    try put(corrupt ? Data() : newIndex, stage.appendingPathComponent("library.json"))
    if fault == 2 { throw Fault.injected(2) }
    guard try Data(contentsOf: stage.appendingPathComponent("song.mp3")) == newAudio,
          try !Data(contentsOf: stage.appendingPathComponent("library.json")).isEmpty else { throw Fault.unsafe }
    if fault == 3 { throw Fault.injected(3) }
    let backup = root.appendingPathComponent("previous-\(UUID().uuidString)")
    try fm.moveItem(at: live, to: backup)
    do {
        if fault == 4 { throw Fault.injected(4) }
        try fm.moveItem(at: stage, to: live)
    } catch {
        if !fm.fileExists(atPath: live.path) { try fm.moveItem(at: backup, to: live) }
        throw error
    }
    try fm.removeItem(at: backup)
}
var rejected = 0
for point in 0...4 {
    let live = try reset()
    let before = try snapshot(live)
    do { try restore(live, fault: point); fatalError("Fault \(point) unexpectedly succeeded") }
    catch Fault.injected(let actual) where actual == point { rejected += 1 }
    guard try snapshot(live) == before else { fatalError("Fault \(point) damaged existing audio or index") }
}
let live = try reset()
let before = try snapshot(live)
do { try restore(live, fault: nil, corrupt: true); fatalError("Corrupt archive accepted") }
catch Fault.unsafe { rejected += 1 }
guard try snapshot(live) == before else { fatalError("Corrupt archive changed live library") }
try restore(live, fault: nil)
guard try snapshot(live) == ["song.mp3": newAudio, "library.json": newIndex] else { fatalError("Successful restore mismatch") }
print("PASS: \(rejected) failed restore cases preserve existing library; successful replacement verified")
