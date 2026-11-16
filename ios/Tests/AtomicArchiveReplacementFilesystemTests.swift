import Foundation

// Independent Foundation filesystem regression. Tests atomic replacement
// invariants, not the MP3 Shelf production archive implementation.
struct ArchiveStore {
    let root: URL
    var destination: URL { root.appendingPathComponent("library.mp3shelf") }

    func replace(with bytes: Data, failBeforePublish: Bool = false) throws {
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
    enum Failure: Error { case interrupted, publish(Int32) }
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
