import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// Standalone POSIX fixture, not production recovery or iPhone acceptance.
// Pin the inode before reading; reject substituted paths and truncated bytes.
enum PinnedReadError: Error { case unsafe, changed, truncated }

func readPinned(_ url: URL, hook: (() throws -> Void)? = nil) throws -> Data {
    let fd = url.path.withCString { open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK) }
    guard fd >= 0 else { throw PinnedReadError.unsafe }
    defer { _ = close(fd) }
    var first = stat()
    guard fstat(fd, &first) == 0,
          (first.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
          first.st_nlink == 1, first.st_size > 0,
          first.st_size <= 1024 * 1024 else { throw PinnedReadError.unsafe }
    try hook?()
    func samePath() -> Bool {
        var pathStat = stat()
        return url.path.withCString { lstat($0, &pathStat) } == 0
            && pathStat.st_dev == first.st_dev && pathStat.st_ino == first.st_ino
    }
    guard samePath() else { throw PinnedReadError.changed }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while data.count < Int(first.st_size) {
        let remaining = min(buffer.count, Int(first.st_size) - data.count)
        let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, remaining) }
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { throw PinnedReadError.truncated }
        data.append(contentsOf: buffer.prefix(count))
    }
    var after = stat()
    guard fstat(fd, &after) == 0,
          after.st_dev == first.st_dev, after.st_ino == first.st_ino,
          after.st_size == first.st_size, samePath() else { throw PinnedReadError.changed }
    return data
}

let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("mp3shelf-pinned-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
for index in 0..<128 {
    let staged = root.appendingPathComponent("staged-\(index)")
    let foreign = root.appendingPathComponent("foreign-\(index)")
    let payload = Data((0..<8192).map { UInt8(($0 + index) % 251) })
    let foreignBytes = Data(repeating: 0xAA, count: 8192)
    try payload.write(to: staged)
    try foreignBytes.write(to: foreign)
    switch index % 4 {
    case 0:
        let actual = try readPinned(staged)
        precondition(actual == payload, "valid archive bytes changed")
    case 1:
        do {
            _ = try readPinned(staged) {
                try fm.removeItem(at: staged)
                try fm.createSymbolicLink(at: staged, withDestinationURL: foreign)
            }
            fatalError("symlink swap accepted")
        } catch PinnedReadError.changed { }
    case 2:
        do {
            _ = try readPinned(staged) {
                try fm.removeItem(at: staged)
                try fm.moveItem(at: foreign, to: staged)
            }
            fatalError("inode replacement accepted")
        } catch PinnedReadError.changed { }
    default:
        do {
            _ = try readPinned(staged) { try Data([0x42]).write(to: staged) }
            fatalError("truncated archive accepted")
        } catch PinnedReadError.changed { } catch PinnedReadError.truncated { }
    }
    if fm.fileExists(atPath: foreign.path) {
        let untouched = try Data(contentsOf: foreign)
        precondition(untouched == foreignBytes, "foreign audio mutated")
    }
}
print("PASS: 128 descriptor-pinned archive read and substitution scenarios")
