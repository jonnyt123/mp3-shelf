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

// Swift 6 forbids mutable array captures in concurrent closures.
// A locked Sendable box makes the error collection race-free.
final class ConcurrentFailures: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []
    func record(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        messages.append(message)
    }
    func snapshot() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return messages
    }
}

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
    let failures = ConcurrentFailures()
    DispatchQueue.concurrentPerform(iterations: fileCount * 2) { index in
        let id = (index * 7 + round) % fileCount
        do { try publish(id, generation: round + 1) }
        catch PublicationError.duplicate { }
        catch {
            failures.record("round \(round), callback \(index): \(error)")
        }
    }
    check(failures.snapshot().isEmpty, "unexpected publication failures: \(failures.snapshot())")
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


// A replacement generation must never be completed by an old callback.
// Reusing the same ticket identity after a retry is particularly dangerous:
// an obsolete callback can arrive after the new generation is queued.
enum GenerationError: Error { case stale, duplicate, invalid }
struct GenerationReceipt: Codable, Equatable {
    let id: Int
    let generation: Int
    let filename: String
}
struct GenerationJournal: Codable {
    var pending: [Int: Int]
    var completed: [GenerationReceipt]
}
let generationManifest = root.appendingPathComponent("generation-manifest.json")
let generationLock = NSLock()
func publishGeneration(_ id: Int, generation: Int) throws {
    generationLock.lock()
    defer { generationLock.unlock() }
    var state = try JSONDecoder().decode(GenerationJournal.self, from: Data(contentsOf: generationManifest))
    guard let current = state.pending[id], current == generation else { throw GenerationError.stale }
    guard !state.completed.contains(where: { $0.id == id }) else { throw GenerationError.duplicate }
    guard (0..<fileCount).contains(id),
          try Data(contentsOf: audioPaths[id]) == payloads[id] else { throw GenerationError.invalid }
    state.completed.append(GenerationReceipt(id: id, generation: generation,
                                              filename: audioPaths[id].lastPathComponent))
    try JSONEncoder().encode(state).write(to: generationManifest, options: .atomic)
}
for round in 0..<48 {
    let currentGeneration = 100 + round
    let journal = GenerationJournal(pending: Dictionary(uniqueKeysWithValues:
        (0..<fileCount).map { ($0, currentGeneration) }), completed: [])
    try JSONEncoder().encode(journal).write(to: generationManifest, options: .atomic)
    let failures = ConcurrentFailures()
    DispatchQueue.concurrentPerform(iterations: fileCount * 3) { callback in
        let id = (callback * 11 + round) % fileCount
        let generation = callback % 3 == 0 ? currentGeneration - 1 : currentGeneration
        do { try publishGeneration(id, generation: generation) }
        catch GenerationError.stale { }
        catch GenerationError.duplicate { }
        catch {
            failures.record("round \(round), callback \(callback): \(error)")
        }
    }
    check(failures.snapshot().isEmpty, "generation callback failed unexpectedly: \(failures.snapshot())")
    let recovered = try JSONDecoder().decode(GenerationJournal.self, from: Data(contentsOf: generationManifest))
    // Each ticket receives two valid-generation callbacks in every round.
    check(recovered.completed.count == fileCount, "lost generation completion")
    check(Set(recovered.completed.map(\.id)) == Set(0..<fileCount), "duplicate or missing ticket")
    check(recovered.completed.allSatisfy { $0.generation == currentGeneration &&
        $0.filename == "audio-\($0.id).mp3" }, "stale callback took ownership")
    let before = try Data(contentsOf: generationManifest)
    for id in 0..<fileCount {
        do { try publishGeneration(id, generation: currentGeneration - 1)
            preconditionFailure("stale callback accepted after commit")
        } catch GenerationError.stale { }
        do { try publishGeneration(id, generation: currentGeneration)
            preconditionFailure("duplicate callback accepted after commit")
        } catch GenerationError.duplicate { }
        let preservedAudio = try Data(contentsOf: audioPaths[id]) == payloads[id]
        check(preservedAudio, "generation changed audio")
    }
    let unchangedJournal = try Data(contentsOf: generationManifest) == before
    check(unchangedJournal, "rejected callback rewrote journal")
}
print("PASS: 48 rounds of mixed-generation concurrent callbacks; stale and duplicate rejection, exact journal and audio preservation")


// Retry and cancellation are journal mutations, not merely callback filters.
// Exercise an actual generation transition while callback workers are waiting.
// The old callback must not publish after the retry is durably recorded.
func replaceGeneration(_ id: Int, with next: Int) throws {
    generationLock.lock()
    defer { generationLock.unlock() }
    var state = try JSONDecoder().decode(GenerationJournal.self, from: Data(contentsOf: generationManifest))
    guard state.pending[id] != nil, !state.completed.contains(where: { $0.id == id }) else {
        throw GenerationError.invalid
    }
    state.pending[id] = next
    try JSONEncoder().encode(state).write(to: generationManifest, options: .atomic)
}
for round in 0..<64 {
    let old = 500 + round * 2
    let next = old + 1
    let ticket = round % fileCount
    let initial = GenerationJournal(pending: [ticket: old], completed: [])
    try JSONEncoder().encode(initial).write(to: generationManifest, options: .atomic)
    let ready = DispatchSemaphore(value: 0)
    let proceed = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    let results = NSLock()
    var staleRejected = false
    var unexpectedError: String?
    DispatchQueue.global(qos: .userInitiated).async {
        ready.signal()
        proceed.wait()
        do {
            try publishGeneration(ticket, generation: old)
            results.lock()
            unexpectedError = "old generation published after retry"
            results.unlock()
        } catch GenerationError.stale {
            results.lock()
            staleRejected = true
            results.unlock()
        } catch {
            results.lock()
            unexpectedError = String(describing: error)
            results.unlock()
        }
        finished.signal()
    }
    ready.wait()
    try replaceGeneration(ticket, with: next)
    let persisted = try JSONDecoder().decode(GenerationJournal.self, from: Data(contentsOf: generationManifest))
    check(persisted.pending[ticket] == next && persisted.completed.isEmpty, "retry not durably published")
    proceed.signal()
    finished.wait()
    check(staleRejected && unexpectedError == nil, "old callback escaped retry boundary: \(unexpectedError ?? "unknown")")
    try publishGeneration(ticket, generation: next)
    let committed = try JSONDecoder().decode(GenerationJournal.self, from: Data(contentsOf: generationManifest))
    check(committed.completed == [GenerationReceipt(id: ticket, generation: next,
        filename: audioPaths[ticket].lastPathComponent)], "retry completion incorrect")
    let snapshot = try Data(contentsOf: generationManifest)
    do {
        try publishGeneration(ticket, generation: old)
        preconditionFailure("stale callback replaced retry completion")
    } catch GenerationError.stale { }
    let journalUnchanged = try Data(contentsOf: generationManifest) == snapshot
    check(journalUnchanged, "stale callback mutated durable receipt")
    let recordingUnchanged = try Data(contentsOf: audioPaths[ticket]) == payloads[ticket]
    check(recordingUnchanged, "retry changed recording")
}
print("PASS: 64 coordinated retry/callback boundaries, durable generation replacement, and byte-preserved recordings")
