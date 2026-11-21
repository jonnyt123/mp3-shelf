import Foundation

// Standalone deterministic failure-injection model; production archive behavior is NOT verified.
// swift ios/Tests/RestoreManifestPublicationFailureTests.swift
private enum Injected: Error { case publication, copy, missingSource }
private func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw NSError(domain: "ManifestPublicationQA", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
private let fm = FileManager.default
private let root = fm.temporaryDirectory.appendingPathComponent("mp3-manifest-fault-\(UUID())")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
private let sources = root.appendingPathComponent("sources")
private let library = root.appendingPathComponent("library")
try fm.createDirectory(at: sources, withIntermediateDirectories: true)
try fm.createDirectory(at: library, withIntermediateDirectories: true)
private let names = ["first.mp3", "second.mp3", "third.mp3"]
private let payloads: [Data] = (0..<3).map { i in
    let factor = i + 3
    let offset = i * 11
    let bytes: [UInt8] = (0..<32768).map { position in
        UInt8((position * factor + offset) % 251)
    }
    return Data(bytes)
}
for (i, name) in names.enumerated() {
    try payloads[i].write(to: sources.appendingPathComponent(name))
}
private let preexisting = library.appendingPathComponent(names[0])
try payloads[0].write(to: preexisting)
private let unrelated = library.appendingPathComponent("unrelated.mp3")
private let unrelatedBytes = Data(repeating: 0xA7, count: 16384)
try unrelatedBytes.write(to: unrelated)
private let manifest = library.appendingPathComponent("manifest.json")
private let before = Data("{\"tracks\":[\"unrelated\",\"first\"]}".utf8)
private let after = Data("{\"tracks\":[\"unrelated\",\"first\",\"second\",\"third\"]}".utf8)
try before.write(to: manifest, options: .atomic)

// Preflight all sources and existing destinations before any mutation. Once
// copies begin, a failed copy or manifest publication removes only new files.
private func restore(failCopy: Int? = nil, failPublish: Bool = false) throws {
    var missing: [(URL, URL)] = []
    for (i, name) in names.enumerated() {
        let src = sources.appendingPathComponent(name)
        let dst = library.appendingPathComponent(name)
        guard (try? fm.destinationOfSymbolicLink(atPath: src.path)) == nil,
              (try? fm.destinationOfSymbolicLink(atPath: dst.path)) == nil,
              let bytes = try? Data(contentsOf: src), bytes == payloads[i] else {
            throw Injected.missingSource
        }
        if fm.fileExists(atPath: dst.path) {
            guard (try? Data(contentsOf: dst)) == bytes else { throw Injected.missingSource }
        } else {
            missing.append((src, dst))
        }
    }
    var created: [URL] = []
    do {
        for (index, pair) in missing.enumerated() {
            if failCopy == index { throw Injected.copy }
            try fm.copyItem(at: pair.0, to: pair.1)
            created.append(pair.1)
        }
        if failPublish { throw Injected.publication }
        try after.write(to: manifest, options: .atomic)
    } catch {
        for path in created.reversed() { try fm.removeItem(at: path) }
        throw error
    }
}

for round in 0..<40 {
    for name in names.dropFirst() {
        let url = library.appendingPathComponent(name)
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
    }
    try before.write(to: manifest, options: .atomic)
    for failedCopy in 0..<2 {
        do { try restore(failCopy: failedCopy); throw NSError(domain: "UnexpectedSuccess", code: 1) }
        catch Injected.copy { }
        try check(Data(contentsOf: manifest) == before, "copy failure changed manifest in round \(round)")
        try check(names.dropFirst().allSatisfy { !fm.fileExists(atPath: library.appendingPathComponent($0).path) }, "copy failure left partial audio")
    }
    do { try restore(failPublish: true); throw NSError(domain: "UnexpectedSuccess", code: 2) }
    catch Injected.publication { }
    try check(Data(contentsOf: manifest) == before, "publication failure changed manifest in round \(round)")
    try check(names.dropFirst().allSatisfy { !fm.fileExists(atPath: library.appendingPathComponent($0).path) }, "publication failure left partial audio")
    try check(Data(contentsOf: preexisting) == payloads[0], "preexisting audio changed")
    try check(Data(contentsOf: unrelated) == unrelatedBytes, "unrelated recording changed")
    try restore()
    try restore()
    try check(Data(contentsOf: manifest) == after, "successful retry did not publish manifest")
    for (i, name) in names.enumerated() {
        try check(Data(contentsOf: library.appendingPathComponent(name)) == payloads[i], "audio bytes changed at \(name)")
    }
}
print("PASS: 80 copy faults, 40 publication faults, 40 idempotent retries, existing audio and manifest preserved")
