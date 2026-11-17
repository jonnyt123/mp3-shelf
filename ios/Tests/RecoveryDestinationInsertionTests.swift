import Foundation

// Run: swift ios/Tests/RecoveryDestinationInsertionTests.swift
// Filesystem contract fixture only: not production downloader or iPhone proof.
enum InsertionError: Error { case unsafeDestination, invalidSource }
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("destination-insertion-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let staged = root.appendingPathComponent("staged.mp3")
let final = root.appendingPathComponent("final.mp3")
let unrelated = root.appendingPathComponent("unrelated.mp3")
let audio = Data((0..<32768).map { UInt8(($0 * 19) % 251) })
let foreign = Data((0..<32768).map { UInt8(($0 * 23 + 7) % 251) })
try foreign.write(to: unrelated)
func assertSafe(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw NSError(domain: "DestinationInsertionQA", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
func clear() throws {
    for url in [staged, final] {
        if (try? fm.attributesOfItem(atPath: url.path)) != nil ||
           (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil {
            try fm.removeItem(at: url)
        }
    }
    try audio.write(to: staged)
}
func publish(afterSourceValidation mutation: () throws -> Void) throws {
    guard (try? fm.destinationOfSymbolicLink(atPath: staged.path)) == nil,
          let attributes = try? fm.attributesOfItem(atPath: staged.path),
          attributes[.type] as? FileAttributeType == .typeRegular,
          (attributes[.referenceCount] as? NSNumber)?.intValue == 1,
          try Data(contentsOf: staged) == audio else { throw InsertionError.invalidSource }
    try mutation()
    // Recheck immediately before publication: an existing file, symlink,
    // hardlink or directory must never be overwritten or counted as success.
    guard !fm.fileExists(atPath: final.path),
          (try? fm.destinationOfSymbolicLink(atPath: final.path)) == nil else {
        throw InsertionError.unsafeDestination
    }
    try fm.copyItem(at: staged, to: final) // copyItem rejects an existing destination
}
var count = 0
for kind in ["foreign", "symlink", "dangling", "hardlink", "directory", "partial"] {
    try clear()
    do {
        try publish {
            switch kind {
            case "foreign": try foreign.write(to: final)
            case "symlink": try fm.createSymbolicLink(at: final, withDestinationURL: unrelated)
            case "dangling": try fm.createSymbolicLink(at: final, withDestinationURL: root.appendingPathComponent("missing"))
            case "hardlink": try fm.linkItem(at: unrelated, to: final)
            case "directory": try fm.createDirectory(at: final, withIntermediateDirectories: false)
            default: try audio.prefix(128).write(to: final)
            }
        }
        try assertSafe(false, "\(kind): existing destination accepted")
    } catch InsertionError.unsafeDestination {}
    try assertSafe(try Data(contentsOf: unrelated) == foreign, "\(kind): unrelated audio modified")
    try assertSafe(try Data(contentsOf: staged) == audio, "\(kind): staged audio consumed")
    count += 1
}
try clear()
try publish {}
try assertSafe(try Data(contentsOf: final) == audio, "valid publish failed")
do { try publish {}; try assertSafe(false, "duplicate callback republished") }
catch InsertionError.unsafeDestination {}
try assertSafe(try Data(contentsOf: final) == audio, "duplicate callback changed audio")
print("PASS: \(count) destination insertion cases, valid publication, duplicate callback")
