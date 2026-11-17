import Foundation

// Standalone failure-injection reference model; not production importer coverage.
// swift ios/Tests/PortableRestoreCopyRollbackTests.swift
private enum CopyFault: Error { case injected, invalidSource }
private func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw NSError(domain: "RestoreRollbackQA", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
private let fm = FileManager.default
private let root = fm.temporaryDirectory.appendingPathComponent("mp3-copy-rollback-\(UUID())")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
private let source = root.appendingPathComponent("source")
private let library = root.appendingPathComponent("library")
try fm.createDirectory(at: source, withIntermediateDirectories: true)
try fm.createDirectory(at: library, withIntermediateDirectories: true)
private let payloads: [Data] = (0..<3).map { index in
    let bytes: [UInt8] = (0..<65536).map { offset in
        UInt8((offset * (index + 7) + index) % 251)
    }
    return Data(bytes)
}
private let names = ["one.mp3", "two.mp3", "three.mp3"]
for (index, name) in names.enumerated() {
    try payloads[index].write(to: source.appendingPathComponent(name))
}
private let original = library.appendingPathComponent("existing.mp3")
private let originalBytes = Data(repeating: 0x6D, count: 8192)
try originalBytes.write(to: original)
private let manifest = library.appendingPathComponent("manifest.json")
private let before = Data("{\"tracks\":[\"existing\"]}".utf8)
private let after = Data("{\"tracks\":[\"existing\",\"one\",\"two\",\"three\"]}".utf8)
try before.write(to: manifest, options: .atomic)

// Model the required all-or-nothing copy contract. Roll back only files that
// this attempt created; never delete pre-existing recordings on failure.
private func restore(failAtCopy: Int?) throws {
    var pending: [(URL, URL)] = []
    for name in names {
        let src = source.appendingPathComponent(name)
        let dst = library.appendingPathComponent(name)
        guard (try? fm.destinationOfSymbolicLink(atPath: src.path)) == nil,
              (try? fm.destinationOfSymbolicLink(atPath: dst.path)) == nil,
              fm.fileExists(atPath: src.path),
              let expected = try? Data(contentsOf: src), !expected.isEmpty else {
            throw CopyFault.invalidSource
        }
        if fm.fileExists(atPath: dst.path) {
            guard (try? Data(contentsOf: dst)) == expected else { throw CopyFault.invalidSource }
        } else {
            pending.append((src, dst))
        }
    }
    var created: [URL] = []
    do {
        for (index, pair) in pending.enumerated() {
            if failAtCopy == index { throw CopyFault.injected }
            try fm.copyItem(at: pair.0, to: pair.1)
            created.append(pair.1)
        }
        try after.write(to: manifest, options: .atomic)
    } catch {
        for path in created.reversed() { try fm.removeItem(at: path) }
        throw error
    }
}

for round in 0..<32 {
    for name in names {
        let path = library.appendingPathComponent(name)
        if fm.fileExists(atPath: path.path) { try fm.removeItem(at: path) }
    }
    try before.write(to: manifest, options: .atomic)
    for failAt in 0..<names.count {
        var rejected = false
        do { try restore(failAtCopy: failAt) } catch CopyFault.injected { rejected = true }
        try require(rejected, "failure injection missed round \(round), copy \(failAt)")
        try require(Data(contentsOf: manifest) == before, "partial manifest publication")
        try require(names.allSatisfy { !fm.fileExists(atPath: library.appendingPathComponent($0).path) }, "partial copy survived rollback")
        try require(Data(contentsOf: original) == originalBytes, "existing audio lost")
    }
    try restore(failAtCopy: nil)
    try restore(failAtCopy: nil)
    try require(Data(contentsOf: manifest) == after, "successful retry failed")
    for (index, name) in names.enumerated() {
        try require(Data(contentsOf: library.appendingPathComponent(name)) == payloads[index], "recording corrupted")
    }
}
print("PASS: 96 injected copy failures, rollback isolation, 32 successful idempotent retries, byte-preserving 3-track restore")
