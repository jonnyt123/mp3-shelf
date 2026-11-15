import Foundation
import Dispatch

// Independent Foundation concurrency regression; not production URLSession evidence.
struct TicketReceipt: Codable, Equatable {
    let id: Int
    let generation: Int
    let filename: String
}
struct DurableManifest: Codable {
    var receipts: [TicketReceipt]
}
enum PublicationError: Error { case duplicate, invalid }

let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("mp3shelf-concurrent-receipts-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let manifest = root.appendingPathComponent("manifest.json")
let fileCount = 16
let payloads = (0..<fileCount).map { id in Data((0..<8192).map { UInt8(($0 + id * 31) % 251) }) }
let audioPaths = (0..<fileCount).map { root.appendingPathComponent("audio-\($0).mp3") }
for id in 0..<fileCount { try payloads[id].write(to: audioPaths[id]) }
let lock = NSLock()
func read() throws -> DurableManifest {
    try JSONDecoder().decode(DurableManifest.self, from: Data(contentsOf: manifest))
}
func publish(_ id: Int, generation: Int) throws {
    lock.lock()
    defer { lock.unlock() }
    var state = try read()
    guard (0..<fileCount).contains(id), generation > 0 else { throw PublicationError.invalid }
    guard !state.receipts.contains(where: { $0.id == id }) else { throw PublicationError.duplicate }
    guard try Data(contentsOf: audioPaths[id]) == payloads[id] else { throw PublicationError.invalid }
    state.receipts.append(TicketReceipt(id: id, generation: generation, filename: audioPaths[id].lastPathComponent))
    try JSONEncoder().encode(state).write(to: manifest, options: .atomic)
}
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}
for round in 0..<32 {
    try JSONEncoder().encode(DurableManifest(receipts: [])).write(to: manifest, options: .atomic)
    let failures = NSLock()
    var unexpected: [String] = []
    DispatchQueue.concurrentPerform(iterations: fileCount * 2) { index in
        let id = (index * 7 + round) % fileCount
        do { try publish(id, generation: round + 1) }
        catch PublicationError.duplicate { }
        catch {
            failures.lock()
            unexpected.append("round \(round), callback \(index): \(error)")
            failures.unlock()
        }
    }
    check(unexpected.isEmpty, "unexpected publication failures: \(unexpected)")
    let state = try read()
    check(state.receipts.count == fileCount, "lost or duplicated receipts")
    check(Set(state.receipts.map(\.id)) == Set(0..<fileCount), "missing ticket")
    check(state.receipts.allSatisfy { $0.generation == round + 1 && $0.filename == "audio-\($0.id).mp3" }, "receipt metadata corrupted")
    for id in 0..<fileCount {
        let preserved = try Data(contentsOf: audioPaths[id]) == payloads[id]
        check(preserved, "audio modified")
    }
    let before = try read()
    do { try publish(round % fileCount, generation: round + 1); preconditionFailure("duplicate accepted") }
    catch PublicationError.duplicate { }
    let after = try read()
    check(before.receipts == after.receipts, "duplicate changed manifest")
}
print("PASS: 32 rounds, 1024 concurrent callbacks, 512 unique receipts, duplicate rejection, and 16 byte-preserved recordings")
