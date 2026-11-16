import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// Independent Foundation fixture for native backup sidecar path ownership.
// Execute: swift ios/Tests/ArchiveSidecarPathOwnershipTests.swift
// This exercises filesystem semantics, not PortableShelfArchive integration.
func assertSafe(_ condition: Bool, _ message: String) {
    precondition(condition, message)
}
func identity(_ handle: FileHandle, _ path: URL) -> Bool {
    var opened = stat()
    var named = stat()
    return fstat(handle.fileDescriptor, &opened) == 0 &&
        lstat(path.path, &named) == 0 &&
        (opened.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) &&
        opened.st_dev == named.st_dev && opened.st_ino == named.st_ino &&
        opened.st_size == named.st_size
}
func safeRead(_ name: String, _ root: URL, maxBytes: Int = 4096) throws -> Data? {
    guard !name.isEmpty, name != ".", name != "..",
          !name.contains("/"), !name.contains("\\"), !name.contains("\0") else { return nil }
    let path = root.appendingPathComponent(name)
    guard path.deletingLastPathComponent().standardizedFileURL.path ==
          root.standardizedFileURL.path else { return nil }
    let file = try FileHandle(forReadingFrom: path)
    defer { try? file.close() }
    guard identity(file, path) else { return nil }
    let data = try file.readToEnd() ?? Data()
    guard data.count <= maxBytes, identity(file, path) else { return nil }
    return data
}
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("mp3-sidecar-\(UUID())")
let owned = root.appendingPathComponent("owned")
try fm.createDirectory(at: owned, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let audio = owned.appendingPathComponent("artwork.bin")
let outside = root.appendingPathComponent("private.bin")
try Data("artwork".utf8).write(to: audio)
try Data("private".utf8).write(to: outside)
assertSafe(try safeRead("artwork.bin", owned) == Data("artwork".utf8), "Regular file rejected")
for bad in ["", ".", "..", "../private.bin", "nested/../private.bin", "nested\\private.bin"] {
    assertSafe(try safeRead(bad, owned) == nil, "Unsafe path accepted: \(bad)")
}
let externalLink = owned.appendingPathComponent("external.bin")
try fm.createSymbolicLink(at: externalLink, withDestinationURL: outside)
assertSafe(try safeRead("external.bin", owned) == nil, "External symlink accepted")
let internalLink = owned.appendingPathComponent("internal.bin")
try fm.createSymbolicLink(at: internalLink, withDestinationURL: audio)
assertSafe(try safeRead("internal.bin", owned) == nil, "Internal symlink accepted")
let directory = owned.appendingPathComponent("directory.bin")
try fm.createDirectory(at: directory, withIntermediateDirectories: false)
assertSafe(try safeRead("directory.bin", owned) == nil, "Directory accepted")
let oversized = owned.appendingPathComponent("large.bin")
try Data(repeating: 65, count: 4097).write(to: oversized)
assertSafe(try safeRead("large.bin", owned) == nil, "Oversized sidecar accepted")
let replaced = owned.appendingPathComponent("replaced.bin")
try Data("old".utf8).write(to: replaced)
let handle = try FileHandle(forReadingFrom: replaced)
assertSafe(identity(handle, replaced), "Original identity invalid")
let replacement = owned.appendingPathComponent("new.bin")
try Data("new".utf8).write(to: replacement)
try fm.removeItem(at: replaced)
try fm.moveItem(at: replacement, to: replaced)
assertSafe(!identity(handle, replaced), "Same-size pathname replacement accepted")
try handle.close()
print("PASS: sidecar path, symlink, type, size and replacement ownership fixture")
