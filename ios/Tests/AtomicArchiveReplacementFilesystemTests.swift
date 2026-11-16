import Foundation

// Independent Foundation filesystem regression. Tests atomic replacement
// invariants, not the MP3 Shelf production archive implementation.
struct ArchiveStore {
    let root: URL
    var destination: URL { root.appendingPathComponent("library.mp3shelf") }

    func replace(with bytes: Data, failBeforePublish: Bool = false) throws {
        // Reject hostile destinations before staging or publishing an archive.
        if FileManager.default.fileExists(atPath: destination.path)
            || (try? FileManager.default.destinationOfSymbolicLink(atPath: destination.path)) != nil {
            let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw Failure.untrustedDestination
            }
        }
        let temporary = root.appendingPathComponent(UUID().uuidString + ".pending")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try bytes.write(to: temporary, options: .atomic)
        guard !failBeforePublish else { throw Failure.interrupted }
        // Same-volume POSIX rename atomically replaces the existing archive.
        let result = temporary.path.withCString { source in
            destination.path.withCString { target in rename(source, target) }
        }
        guard result == 0 else { throw Failure.publish(errno) }
    }
    enum Failure: Error { case interrupted, publish(Int32), untrustedDestination }
}

func require(_ condition: @autoclosure () throws -> Bool, _ reason: String) rethrows {
    if try !condition() { preconditionFailure(reason) }
}
func payload(_ seed: Int, count: Int) -> Data {
    Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ seed) })
}

let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("mp3-shelf-atomic-qa-" + UUID().uuidString)
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let store = ArchiveStore(root: root)
let original = payload(7, count: 256 * 1024)
try store.replace(with: original)
try require(try Data(contentsOf: store.destination) == original, "initial archive mismatch")

for cycle in 0..<64 {
    let candidate = payload(cycle + 11, count: 128 * 1024 + cycle)
    let previous = try Data(contentsOf: store.destination)
    do {
        try store.replace(with: candidate, failBeforePublish: true)
        preconditionFailure("fault injection unexpectedly published")
    } catch ArchiveStore.Failure.interrupted { }
    try require(try Data(contentsOf: store.destination) == previous,
            "interrupted write changed durable archive at cycle \(cycle)")
    let entries = try fm.contentsOfDirectory(atPath: root.path)
    require(entries == ["library.mp3shelf"], "temporary file leaked at cycle \(cycle)")
    try store.replace(with: candidate)
    try require(try Data(contentsOf: store.destination) == candidate,
            "successful replacement mismatch at cycle \(cycle)")
}

// Reject archive destinations that are symlinks rather than trusted files.
let outside = fm.temporaryDirectory.appendingPathComponent("mp3-shelf-archive-canary-" + UUID().uuidString)
try original.write(to: outside)
defer { try? fm.removeItem(at: outside) }
let link = root.appendingPathComponent("untrusted.mp3shelf")
try fm.createSymbolicLink(at: link, withDestinationURL: outside)
let attrs = try fm.attributesOfItem(atPath: link.path)
require(attrs[.type] as? FileAttributeType == .typeSymbolicLink,
        "symlink detection did not identify an untrusted destination")
try require(try Data(contentsOf: outside) == original, "external canary changed")
print("PASS: 64 interrupted/published atomic archive cycles, cleanup and symlink detection")

// A symlink occupying the actual archive destination must not be silently
// replaced. A destination directory must also be rejected before staging.
let protected = payload(211, count: 32768)
let trustedArchive = try Data(contentsOf: store.destination)
let displaced = root.appendingPathComponent("previous-archive")
try fm.moveItem(at: store.destination, to: displaced)
try fm.createSymbolicLink(at: store.destination, withDestinationURL: outside)
do {
    try store.replace(with: protected)
    preconditionFailure("symlink destination was accepted")
} catch ArchiveStore.Failure.untrustedDestination { }
require((try? fm.destinationOfSymbolicLink(atPath: store.destination.path)) != nil,
        "symlink was overwritten")
try require(try Data(contentsOf: outside) == original, "symlink target modified")
try fm.removeItem(at: store.destination)
try fm.createDirectory(at: store.destination, withIntermediateDirectories: false)
do {
    try store.replace(with: protected)
    preconditionFailure("directory destination was accepted")
} catch ArchiveStore.Failure.untrustedDestination { }
require((try fm.contentsOfDirectory(atPath: store.destination.path)).isEmpty,
        "directory contents changed")
try fm.removeItem(at: store.destination)
try fm.moveItem(at: displaced, to: store.destination)
try require(try Data(contentsOf: store.destination) == trustedArchive,
            "previous archive was not recoverable after hostile destinations")
let remaining = try fm.contentsOfDirectory(atPath: root.path).sorted()
require(remaining == ["library.mp3shelf", "untrusted.mp3shelf"].sorted(),
        "failed publication leaked staging files")
print("PASS: symlink and directory destinations rejected; external bytes and prior archive preserved")
