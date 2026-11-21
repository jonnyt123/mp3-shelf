import Foundation

// Standalone recovery contract fixture: swift ios/Tests/RecoveryJournalIdentityTests.swift
// This tests the required fail-closed boundary, not the production recovery service.
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("mp3shelf-journal-identity-\(UUID())")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let music = root.appendingPathComponent("Music")
let outside = root.appendingPathComponent("Outside")
try fm.createDirectory(at: music, withIntermediateDirectories: true)
try fm.createDirectory(at: outside, withIntermediateDirectories: true)
let journal = music.appendingPathComponent("recovery.json")
let original = Data("{\"generation\":\"00000000-0000-0000-0000-000000000001\",\"committed\":false}".utf8)
let alternate = Data("{\"generation\":\"00000000-0000-0000-0000-000000000002\",\"committed\":false}".utf8)
let protected = outside.appendingPathComponent("protected.json")
try original.write(to: protected)
let recording = music.appendingPathComponent("recording.mp3")
let audio = Data(repeating: 0x7D, count: 2048)
try audio.write(to: recording)

struct Fingerprint: Equatable {
    let device: UInt64
    let inode: UInt64
    let bytes: Data
}
enum UnsafeJournal: Error { case changed }
func fingerprint(_ url: URL) throws -> Fingerprint {
    guard (try? fm.destinationOfSymbolicLink(atPath: url.path)) == nil else { throw UnsafeJournal.changed }
    let attributes = try fm.attributesOfItem(atPath: url.path)
    guard attributes[.type] as? FileAttributeType == .typeRegular,
          let device = attributes[.systemNumber] as? NSNumber,
          let inode = attributes[.systemFileNumber] as? NSNumber,
          let links = attributes[.referenceCount] as? NSNumber,
          links.intValue == 1 else { throw UnsafeJournal.changed }
    return Fingerprint(device: device.uint64Value, inode: inode.uint64Value, bytes: try Data(contentsOf: url))
}
func replay(_ race: () throws -> Void) throws {
    let before = try fingerprint(journal)
    guard before.bytes == original else { throw UnsafeJournal.changed }
    try race()
    guard try fingerprint(journal) == before else { throw UnsafeJournal.changed }
    try fm.removeItem(at: recording)
    try fm.removeItem(at: journal)
}
func reset() throws {
    if fm.fileExists(atPath: journal.path) || (try? fm.destinationOfSymbolicLink(atPath: journal.path)) != nil { try fm.removeItem(at: journal) }
    if !fm.fileExists(atPath: recording.path) { try audio.write(to: recording) }
    try original.write(to: journal)
}
var rejected = 0
for mode in 0..<5 {
    try reset()
    do {
        try replay {
            switch mode {
            case 0:
                let replacement = music.appendingPathComponent("replacement.json")
                try original.write(to: replacement)
                try fm.removeItem(at: journal)
                try fm.moveItem(at: replacement, to: journal)
            case 1: try alternate.write(to: journal)
            case 2:
                try fm.removeItem(at: journal)
                try fm.createSymbolicLink(at: journal, withDestinationURL: protected)
            case 3:
                try fm.removeItem(at: journal)
                try fm.linkItem(at: protected, to: journal)
            default: try Data(original.prefix(12)).write(to: journal)
            }
        }
        fatalError("Accepted unsafe journal mutation \(mode)")
    } catch UnsafeJournal.changed { rejected += 1 }
    guard try Data(contentsOf: recording) == audio, try Data(contentsOf: protected) == original else {
        fatalError("Audio or external journal changed after rejection \(mode)")
    }
}
try reset()
try replay {}
guard !fm.fileExists(atPath: journal.path), !fm.fileExists(atPath: recording.path), rejected == 5 else {
    fatalError("Control or mutation rejection failed")
}
print("PASS: 5 journal-entry mutation rejections and 1 uncontested cleanup")
