import Foundation

// Standalone filesystem contract fixture, not production code or iPhone evidence.
// Run: swift ios/Tests/MultiRecordingRecoveryIsolationTests.swift
struct Record: Codable { let name: String; let bytes: Data }
struct Intent: Codable { let generation: Int; let records: [Record] }
enum RecoveryError: Error { case invalid, interrupted }
final class RecoveryModel {
    let root: URL
    let fm = FileManager.default
    var interruptAfter: Int?
    init(_ root: URL) throws {
        self.root = root
        try fm.createDirectory(at: root.appendingPathComponent("stage"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("live"), withIntermediateDirectories: true)
    }
    func path(_ relative: String) -> URL { root.appendingPathComponent(relative) }
    func regular(_ url: URL) -> Bool {
        guard (try? fm.destinationOfSymbolicLink(atPath: url.path)) == nil,
              let attributes = try? fm.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular else { return false }
        return true
    }
    func prepare(_ intent: Intent) throws {
        try JSONEncoder().encode(intent).write(to: path("intent.json"), options: .atomic)
        for record in intent.records {
            try record.bytes.write(to: path("stage/" + record.name), options: .atomic)
        }
    }
    func recover(generation: Int) throws {
        guard regular(path("intent.json")),
              let intent = try? JSONDecoder().decode(Intent.self, from: Data(contentsOf: path("intent.json"))),
              intent.generation == generation, !intent.records.isEmpty else { throw RecoveryError.invalid }
        var names = Set<String>()
        // Validate the entire batch before writing any destination.
        for record in intent.records {
            guard !record.name.isEmpty, record.name != ".", record.name != "..",
                  !record.name.hasPrefix("."), !record.name.contains("/"),
                  !record.name.contains("\\"), !record.name.contains("\0"),
                  names.insert(record.name).inserted, !record.bytes.isEmpty,
                  regular(path("stage/" + record.name)),
                  let staged = try? Data(contentsOf: path("stage/" + record.name)),
                  staged == record.bytes else { throw RecoveryError.invalid }
            let target = path("live/" + record.name)
            if fm.fileExists(atPath: target.path) ||
                (try? fm.destinationOfSymbolicLink(atPath: target.path)) != nil {
                guard regular(target),
                      let existing = try? Data(contentsOf: target), existing == staged else {
                    throw RecoveryError.invalid
                }
            }
        }
        for (index, record) in intent.records.enumerated() {
            if interruptAfter == index { throw RecoveryError.interrupted }
            let target = path("live/" + record.name)
            if !fm.fileExists(atPath: target.path) {
                try record.bytes.write(to: target, options: .atomic)
            }
        }
    }
}
func verify(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try value() else { fatalError(message) }
}
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("mp3-multi-recovery-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let first = Data((0..<4096).map { UInt8($0 % 251) })
let second = Data((0..<8192).map { UInt8(($0 + 43) % 251) })
let unrelated = Data(repeating: 0x6f, count: 512)
let intent = Intent(generation: 44, records: [
    Record(name: "first.mp3", bytes: first), Record(name: "second.mp3", bytes: second)
])
var passed = 0
func scenario(_ name: String, _ run: (RecoveryModel) throws -> Void) throws {
    let model = try RecoveryModel(root.appendingPathComponent(name))
    try unrelated.write(to: model.path("live/unrelated.mp3"))
    try run(model)
    try verify(Data(contentsOf: model.path("live/unrelated.mp3")) == unrelated, "unrelated audio changed")
    passed += 1
}
try scenario("crash-and-retry") { m in
    try m.prepare(intent)
    m.interruptAfter = 1
    do { try m.recover(generation: 44); fatalError("expected interruption") }
    catch RecoveryError.interrupted {}
    try verify(Data(contentsOf: m.path("live/first.mp3")) == first, "first publication lost")
    try verify(!fm.fileExists(atPath: m.path("live/second.mp3").path), "second published early")
    m.interruptAfter = nil
    for _ in 0..<3 { try m.recover(generation: 44) }
    try verify(Data(contentsOf: m.path("live/second.mp3")) == second, "retry lost audio")
}
try scenario("conflict-after-crash") { m in
    try m.prepare(intent)
    m.interruptAfter = 1
    do { try m.recover(generation: 44); fatalError("expected interruption") }
    catch RecoveryError.interrupted {}
    let conflict = Data(repeating: 0xa5, count: 200)
    try conflict.write(to: m.path("live/second.mp3"))
    m.interruptAfter = nil
    do { try m.recover(generation: 44); fatalError("overwrote conflict") }
    catch RecoveryError.invalid {}
    try verify(Data(contentsOf: m.path("live/first.mp3")) == first, "first audio changed")
    try verify(Data(contentsOf: m.path("live/second.mp3")) == conflict, "conflict changed")
}
try scenario("missing-second-stage") { m in
    try m.prepare(intent)
    try fm.removeItem(at: m.path("stage/second.mp3"))
    do { try m.recover(generation: 44); fatalError("accepted missing stage") }
    catch RecoveryError.invalid {}
    try verify(!fm.fileExists(atPath: m.path("live/first.mp3").path), "partial publish")
}
try scenario("corrupt-second-stage") { m in
    try m.prepare(intent)
    try Data(repeating: 0, count: second.count).write(to: m.path("stage/second.mp3"))
    do { try m.recover(generation: 44); fatalError("accepted corruption") }
    catch RecoveryError.invalid {}
    try verify(!fm.fileExists(atPath: m.path("live/first.mp3").path), "partial publish")
}
try scenario("duplicate-target") { m in
    try m.prepare(Intent(generation: 44, records: [intent.records[0], intent.records[0]]))
    do { try m.recover(generation: 44); fatalError("accepted duplicate") }
    catch RecoveryError.invalid {}
    try verify(!fm.fileExists(atPath: m.path("live/first.mp3").path), "duplicate published")
}
try scenario("stale-generation") { m in
    try m.prepare(intent)
    do { try m.recover(generation: 43); fatalError("accepted stale generation") }
    catch RecoveryError.invalid {}
    try verify(!fm.fileExists(atPath: m.path("live/first.mp3").path), "stale published")
}
try scenario("symlinked-second-stage") { m in
    try m.prepare(intent)
    let outside = root.appendingPathComponent("outside-stage.mp3")
    try second.write(to: outside)
    try fm.removeItem(at: m.path("stage/second.mp3"))
    try fm.createSymbolicLink(at: m.path("stage/second.mp3"), withDestinationURL: outside)
    do { try m.recover(generation: 44); fatalError("accepted symlink stage") }
    catch RecoveryError.invalid {}
    try verify(!fm.fileExists(atPath: m.path("live/first.mp3").path), "partial publish")
    try verify(Data(contentsOf: outside) == second, "outside audio changed")
}
try scenario("symlinked-second-destination") { m in
    try m.prepare(intent)
    let outside = root.appendingPathComponent("outside-destination.mp3")
    try second.write(to: outside)
    try fm.createSymbolicLink(at: m.path("live/second.mp3"), withDestinationURL: outside)
    do { try m.recover(generation: 44); fatalError("accepted symlink destination") }
    catch RecoveryError.invalid {}
    try verify(!fm.fileExists(atPath: m.path("live/first.mp3").path), "partial publish")
    try verify(Data(contentsOf: outside) == second, "outside audio changed")
}
print("PASS: \(passed) multi-recording crash/replay filesystem scenarios")
