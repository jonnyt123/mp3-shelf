import Foundation

// Standalone filesystem QA fixture: swift ios/Tests/RecoveryDirectorySwapTests.swift
// Models the required fail-closed recovery boundary, not production integration.
struct Ticket: Codable { let generation: UUID; let fileName: String; let committed: Bool }
enum Reject: Error { case unsafe }
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("recovery-parent-race-\(UUID())")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let live = root.appendingPathComponent("Music")
let moved = root.appendingPathComponent("Music-moved")
let external = root.appendingPathComponent("External")
try fm.createDirectory(at: live, withIntermediateDirectories: true)
try fm.createDirectory(at: external, withIntermediateDirectories: true)
let sentinel = external.appendingPathComponent("recording.mp3")
let payload = Data(repeating: 0xA7, count: 4096)
try payload.write(to: sentinel)
let journalName = "recovery.json"
let audioName = "recording.mp3"
func identity(_ url: URL) throws -> (UInt64, UInt64) {
    guard (try? fm.destinationOfSymbolicLink(atPath: url.path)) == nil else { throw Reject.unsafe }
    let a = try fm.attributesOfItem(atPath: url.path)
    guard let inode = a[.systemFileNumber] as? NSNumber,
          let device = a[.systemNumber] as? NSNumber,
          (a[.type] as? FileAttributeType) == .typeDirectory,
          ((a[.referenceCount] as? NSNumber)?.intValue ?? 0) >= 1 else { throw Reject.unsafe }
    return (device.uint64Value, inode.uint64Value)
}
func replay(_ beforeCleanup: () throws -> Void) throws {
    let before = try identity(live)
    let journal = live.appendingPathComponent(journalName)
    let bytes = try Data(contentsOf: journal)
    let ticket = try JSONDecoder().decode(Ticket.self, from: bytes)
    guard ticket.fileName == audioName else { throw Reject.unsafe }
    try beforeCleanup()
    let after = try identity(live)
    guard before == after, (try? Data(contentsOf: journal)) == bytes else { throw Reject.unsafe }
    if !ticket.committed { try fm.removeItem(at: live.appendingPathComponent(audioName)) }
    try fm.removeItem(at: journal)
}
func reset(_ committed: Bool) throws {
    if fm.fileExists(atPath: live.path) || (try? fm.destinationOfSymbolicLink(atPath: live.path)) != nil { try fm.removeItem(at: live) }
    if fm.fileExists(atPath: moved.path) { try fm.removeItem(at: moved) }
    try fm.createDirectory(at: live, withIntermediateDirectories: true)
    try payload.write(to: live.appendingPathComponent(audioName))
    try JSONEncoder().encode(Ticket(generation: UUID(), fileName: audioName, committed: committed)).write(to: live.appendingPathComponent(journalName))
}
var rejected = 0
for committed in [false, true] {
    for mode in 0..<4 {
        try reset(committed)
        var callback = false
        do {
            try replay {
                callback = true
                switch mode {
                case 0: try fm.moveItem(at: live, to: moved); try fm.createSymbolicLink(at: live, withDestinationURL: external)
                case 1: try fm.moveItem(at: live, to: moved); try fm.createDirectory(at: live, withIntermediateDirectories: false); try payload.write(to: live.appendingPathComponent(audioName)); try fm.copyItem(at: moved.appendingPathComponent(journalName), to: live.appendingPathComponent(journalName))
                case 2: try fm.moveItem(at: live, to: moved); try fm.createSymbolicLink(at: live, withDestinationURL: moved)
                default: try fm.moveItem(at: live, to: moved); try fm.createDirectory(at: live, withIntermediateDirectories: false)
                }
            }
            fatalError("Accepted parent-directory substitution mode \(mode) committed \(committed)")
        } catch Reject.unsafe { rejected += 1 }
        guard callback, try Data(contentsOf: sentinel) == payload else { fatalError("External audio damaged") }
        guard try Data(contentsOf: moved.appendingPathComponent(audioName)) == payload else { fatalError("Original audio damaged") }
        guard fm.fileExists(atPath: moved.appendingPathComponent(journalName).path) else { fatalError("Original journal deleted") }
    }
    try reset(committed)
    try replay {}
    guard fm.fileExists(atPath: live.appendingPathComponent(audioName).path) == committed else { fatalError("Control failed") }
}
guard rejected == 8 else { fatalError("Missing race rejections") }
print("PASS: 8 parent-directory substitution rejections, 2 uncontested controls")
