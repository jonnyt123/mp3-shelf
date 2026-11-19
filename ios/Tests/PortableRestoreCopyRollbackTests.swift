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
private func restore(failAtCopy: Int?, failAfterCopy: Int? = nil, failBeforeManifest: Bool = false, failDuringCopy: Int? = nil) throws {
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
            created.append(pair.1)
            if failDuringCopy == index {
                let input = try Data(contentsOf: pair.0)
                try input.prefix(max(1, input.count / 3)).write(to: pair.1)
                throw CopyFault.injected
            }
            try fm.copyItem(at: pair.0, to: pair.1)
            if failAfterCopy == index { throw CopyFault.injected }
        }
        if failBeforeManifest { throw CopyFault.injected }
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
    // Inject a failure after a truncated destination is written.
    for failAt in 0..<names.count {
        var rejected = false
        do { try restore(failAtCopy: nil, failDuringCopy: failAt) }
        catch CopyFault.injected { rejected = true }
        try require(rejected, "mid-copy failure injection missed")
        try require(Data(contentsOf: manifest) == before, "mid-copy published metadata")
        try require(names.allSatisfy { !fm.fileExists(atPath: library.appendingPathComponent($0).path) },
                    "mid-copy left partial audio")
        try require(Data(contentsOf: original) == originalBytes, "mid-copy damaged original audio")
    }
    // A crash/failure immediately after a successful copy must not orphan that file.
    for failAt in 0..<names.count {
        var rejected = false
        do { try restore(failAtCopy: nil, failAfterCopy: failAt) } catch CopyFault.injected { rejected = true }
        try require(rejected, "post-copy injection missed round \(round), copy \(failAt)")
        try require(Data(contentsOf: manifest) == before, "post-copy failure published manifest")
        try require(names.allSatisfy { !fm.fileExists(atPath: library.appendingPathComponent($0).path) }, "post-copy failure left orphan audio")
        try require(Data(contentsOf: original) == originalBytes, "post-copy failure damaged original")
    }
    var manifestRejected = false
    do { try restore(failAtCopy: nil, failBeforeManifest: true) } catch CopyFault.injected { manifestRejected = true }
    try require(manifestRejected, "pre-publication injection missed")
    try require(Data(contentsOf: manifest) == before, "pre-publication failure changed manifest")
    try require(names.allSatisfy { !fm.fileExists(atPath: library.appendingPathComponent($0).path) }, "pre-publication failure left orphan audio")
    try restore(failAtCopy: nil)
    try restore(failAtCopy: nil)
    try require(Data(contentsOf: manifest) == after, "successful retry failed")
    for (index, name) in names.enumerated() {
        try require(Data(contentsOf: library.appendingPathComponent(name)) == payloads[index], "recording corrupted")
    }
}

// Collision and hostile-filesystem regression: validation must finish before
// creating any new recording, and a retry must preserve previously owned bytes.
for collisionIndex in names.indices {
    for name in names {
        let path = library.appendingPathComponent(name)
        if fm.fileExists(atPath: path.path) { try fm.removeItem(at: path) }
    }
    try before.write(to: manifest, options: .atomic)
    let colliding = library.appendingPathComponent(names[collisionIndex])
    let foreignBytes = Data(repeating: UInt8(collisionIndex + 1), count: 4096)
    try foreignBytes.write(to: colliding)
    var rejected = false
    do { try restore(failAtCopy: nil) } catch CopyFault.invalidSource { rejected = true }
    try require(rejected, "conflicting destination was accepted")
    try require(Data(contentsOf: colliding) == foreignBytes, "existing conflicting recording overwritten")
    try require(Data(contentsOf: manifest) == before, "conflict published metadata")
    try require(names.enumerated().allSatisfy { index, name in
        index == collisionIndex || !fm.fileExists(atPath: library.appendingPathComponent(name).path)
    }, "conflict left new recordings")
    try require(Data(contentsOf: original) == originalBytes, "conflict damaged original library")
    try fm.removeItem(at: colliding)
    try payloads[collisionIndex].write(to: colliding)
    try restore(failAtCopy: nil)
    try require(Data(contentsOf: colliding) == payloads[collisionIndex], "identical pre-existing recording changed")
    try require(Data(contentsOf: manifest) == after, "safe retry did not publish metadata")
}

// A matching pre-existing destination is borrowed, never owned by this restore.
// Inject failures before and after copying later tracks and ensure rollback
// removes only newly created recordings, preserving the borrowed bytes.
for borrowedIndex in names.indices {
    for failurePoint in 0..<2 {
        for name in names {
            let path = library.appendingPathComponent(name)
            if fm.fileExists(atPath: path.path) { try fm.removeItem(at: path) }
        }
        try before.write(to: manifest, options: .atomic)
        let borrowed = library.appendingPathComponent(names[borrowedIndex])
        try payloads[borrowedIndex].write(to: borrowed)
        let pendingCount = names.count - 1
        for copyIndex in 0..<pendingCount {
            var rejected = false
            do {
                if failurePoint == 0 {
                    try restore(failAtCopy: copyIndex)
                } else {
                    try restore(failAtCopy: nil, failAfterCopy: copyIndex)
                }
            } catch CopyFault.injected { rejected = true }
            try require(rejected, "borrowed destination injection not reached")
            try require(Data(contentsOf: borrowed) == payloads[borrowedIndex],
                        "borrowed recording was modified or removed")
            try require(Data(contentsOf: manifest) == before,
                        "borrowed destination failure published metadata")
            try require(names.enumerated().allSatisfy { index, name in
                index == borrowedIndex || !fm.fileExists(atPath: library.appendingPathComponent(name).path)
            }, "borrowed destination failure left orphan recording")
            try require(Data(contentsOf: original) == originalBytes,
                        "borrowed destination failure damaged original library")
        }
        try restore(failAtCopy: nil)
        try require(Data(contentsOf: borrowed) == payloads[borrowedIndex],
                    "successful borrowed destination retry replaced audio")
        try require(Data(contentsOf: manifest) == after,
                    "successful borrowed destination retry did not publish metadata")
    }
}

// A pre-existing matching recording must survive an interrupted copy of a
// different recording, even when the new destination contains partial bytes.
// This combines borrowed ownership with the mid-copy failure path.
for borrowedIndex in names.indices {
    for interruptedIndex in 0..<(names.count - 1) {
        for name in names {
            let path = library.appendingPathComponent(name)
            if fm.fileExists(atPath: path.path) { try fm.removeItem(at: path) }
        }
        try before.write(to: manifest, options: .atomic)
        let borrowed = library.appendingPathComponent(names[borrowedIndex])
        try payloads[borrowedIndex].write(to: borrowed)
        var rejected = false
        do { try restore(failAtCopy: nil, failDuringCopy: interruptedIndex) }
        catch CopyFault.injected { rejected = true }
        try require(rejected, "borrowed mid-copy failure was not injected")
        try require(Data(contentsOf: borrowed) == payloads[borrowedIndex],
                    "borrowed audio removed by partial-copy rollback")
        try require(Data(contentsOf: manifest) == before,
                    "borrowed mid-copy failure published metadata")
        try require(names.enumerated().allSatisfy { index, name in
            index == borrowedIndex || !fm.fileExists(atPath: library.appendingPathComponent(name).path)
        }, "partial destination survived borrowed rollback")
        try require(Data(contentsOf: original) == originalBytes,
                    "borrowed mid-copy rollback modified existing audio")
        try restore(failAtCopy: nil)
        try require(Data(contentsOf: manifest) == after, "borrowed mid-copy retry failed")
        for (index, name) in names.enumerated() {
            try require(Data(contentsOf: library.appendingPathComponent(name)) == payloads[index],
                        "borrowed mid-copy retry corrupted audio")
        }
    }
}

// Missing source and symlink attempts must not mutate a valid existing library.
for sourceIndex in names.indices {
    for name in names {
        let path = library.appendingPathComponent(name)
        if fm.fileExists(atPath: path.path) { try fm.removeItem(at: path) }
    }
    try before.write(to: manifest, options: .atomic)
    let src = source.appendingPathComponent(names[sourceIndex])
    let held = source.appendingPathComponent("held-\(sourceIndex)")
    try fm.moveItem(at: src, to: held)
    var missingRejected = false
    do { try restore(failAtCopy: nil) } catch CopyFault.invalidSource { missingRejected = true }
    try require(missingRejected, "missing source was accepted")
    try require(Data(contentsOf: manifest) == before, "missing source published metadata")
    try require(names.allSatisfy { !fm.fileExists(atPath: library.appendingPathComponent($0).path) }, "missing source left audio")
    try fm.createSymbolicLink(at: src, withDestinationURL: held)
    var symlinkRejected = false
    do { try restore(failAtCopy: nil) } catch CopyFault.invalidSource { symlinkRejected = true }
    try require(symlinkRejected, "source symlink was accepted")
    try require(Data(contentsOf: manifest) == before, "source symlink published metadata")
    try require(names.allSatisfy { !fm.fileExists(atPath: library.appendingPathComponent($0).path) }, "source symlink left audio")
    try fm.removeItem(at: src)
    try fm.moveItem(at: held, to: src)
    try require(Data(contentsOf: original) == originalBytes, "source failure damaged existing audio")
}
// Validate all three destination positions against filesystem substitution.
// A destination directory or symlink must never be treated as an existing
// identical audio recording, and must not be deleted during rollback.
for destinationIndex in names.indices {
    for substitution in 0..<2 {
        for name in names {
            let path = library.appendingPathComponent(name)
            if fm.fileExists(atPath: path.path) { try fm.removeItem(at: path) }
        }
        try before.write(to: manifest, options: .atomic)
        let dst = library.appendingPathComponent(names[destinationIndex])
        if substitution == 0 {
            try fm.createDirectory(at: dst, withIntermediateDirectories: false)
        } else {
            try fm.createSymbolicLink(at: dst, withDestinationURL: original)
        }
        var rejected = false
        do { try restore(failAtCopy: nil) } catch CopyFault.invalidSource { rejected = true }
        try require(rejected, "destination substitution accepted at index \(destinationIndex)")
        try require(Data(contentsOf: manifest) == before, "destination substitution published manifest")
        try require(Data(contentsOf: original) == originalBytes, "destination substitution modified original")
        try require(names.enumerated().allSatisfy { index, name in
            index == destinationIndex || !fm.fileExists(atPath: library.appendingPathComponent(name).path)
        }, "destination substitution created orphan audio")
        if substitution == 0 {
            var isDirectory: ObjCBool = false
            try require(fm.fileExists(atPath: dst.path, isDirectory: &isDirectory) && isDirectory.boolValue,
                        "destination directory was removed")
        } else {
            try require((try? fm.destinationOfSymbolicLink(atPath: dst.path)) != nil,
                        "destination symlink was removed")
        }
        try fm.removeItem(at: dst)
    }
}

// A zero-byte or directory source must be rejected before any copy starts.
for sourceIndex in names.indices {
    for substitution in 0..<2 {
        for name in names {
            let path = library.appendingPathComponent(name)
            if fm.fileExists(atPath: path.path) { try fm.removeItem(at: path) }
        }
        try before.write(to: manifest, options: .atomic)
        let src = source.appendingPathComponent(names[sourceIndex])
        let held = source.appendingPathComponent("invalid-held-\(sourceIndex)")
        try fm.moveItem(at: src, to: held)
        if substitution == 0 {
            try Data().write(to: src)
        } else {
            try fm.createDirectory(at: src, withIntermediateDirectories: false)
        }
        var rejected = false
        do { try restore(failAtCopy: nil) } catch CopyFault.invalidSource { rejected = true }
        try require(rejected, "invalid source accepted at index \(sourceIndex)")
        try require(Data(contentsOf: manifest) == before, "invalid source published manifest")
        try require(names.allSatisfy { !fm.fileExists(atPath: library.appendingPathComponent($0).path) },
                    "invalid source created orphan audio")
        try require(Data(contentsOf: original) == originalBytes, "invalid source damaged original")
        try fm.removeItem(at: src)
        try fm.moveItem(at: held, to: src)
    }
}
print("PASS: 18 borrowed-destination rollback failures plus 320 injected failures, 3 collision, 6 missing/symlink, 6 destination substitution and 6 empty/directory source rejection scenarios across pre-copy/post-copy/pre-manifest boundaries, rollback isolation, 32 successful idempotent retries, byte-preserving 3-track restore")
