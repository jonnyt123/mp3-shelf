import Foundation
import Dispatch

// Standalone Foundation model, not production URLSession evidence.
// Run: swift -swift-version 6 ios/Tests/CancelledTicketRestartIsolationTests.swift
struct CancellationTicket: Codable, Equatable {
    var generation: Int
    var status: String
    var filename: String?
}
struct CancellationManifest: Codable, Equatable {
    var tickets: [String: CancellationTicket]
}
enum CancellationFault: Error { case stale, cancelled, duplicate, invalid }
final class CallbackOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var value = "not-run"
    func set(_ next: String) { lock.lock(); defer { lock.unlock() }; value = next }
    func get() -> String { lock.lock(); defer { lock.unlock() }; return value }
}
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("mp3shelf-cancel-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let manifestURL = root.appendingPathComponent("manifest.json")
let audioURL = root.appendingPathComponent("saved.mp3")
let audio = Data((0..<32768).map { UInt8(($0 * 17 + 9) % 251) })
try audio.write(to: audioURL)
let gate = NSLock()
func readManifest() throws -> CancellationManifest {
    try JSONDecoder().decode(CancellationManifest.self, from: Data(contentsOf: manifestURL))
}
func change(_ body: (inout CancellationManifest) throws -> Void) throws {
    gate.lock()
    defer { gate.unlock() }
    var manifest = try readManifest()
    try body(&manifest)
    try JSONEncoder().encode(manifest).write(to: manifestURL, options: .atomic)
}
func complete(_ id: String, generation: Int) throws {
    try change { manifest in
        guard let ticket = manifest.tickets[id], ticket.generation == generation else { throw CancellationFault.stale }
        guard ticket.status != "cancelled" else { throw CancellationFault.cancelled }
        guard ticket.status != "imported" else { throw CancellationFault.duplicate }
        guard ticket.status == "pending", (try? Data(contentsOf: audioURL)) == audio else { throw CancellationFault.invalid }
        manifest.tickets[id] = CancellationTicket(generation: generation, status: "imported", filename: audioURL.lastPathComponent)
    }
}
func assertQA(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw NSError(domain: "CancellationQA", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
for round in 0..<64 {
    let old = round * 2 + 1
    let next = old + 1
    let id = "download-A"
    let other = "download-B"
    let baseline = CancellationManifest(tickets: [
        id: CancellationTicket(generation: old, status: "pending", filename: nil),
        other: CancellationTicket(generation: old, status: "imported", filename: "other.mp3")
    ])
    try JSONEncoder().encode(baseline).write(to: manifestURL, options: .atomic)
    let ready = DispatchSemaphore(value: 0)
    let proceed = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    let outcome = CallbackOutcome()
    DispatchQueue.global().async {
        ready.signal()
        proceed.wait()
        do { try complete(id, generation: old); outcome.set("accepted") }
        catch CancellationFault.stale { outcome.set("stale") }
        catch { outcome.set("unexpected: \(error)") }
        finished.signal()
    }
    ready.wait()
    try change { $0.tickets[id] = CancellationTicket(generation: old, status: "cancelled", filename: nil) }
    let cancelledBytes = try Data(contentsOf: manifestURL)
    do { try complete(id, generation: old); throw CancellationFault.invalid }
    catch CancellationFault.cancelled { }
    try assertQA(try Data(contentsOf: manifestURL) == cancelledBytes, "cancelled callback rewrote journal")
    try change { $0.tickets[id] = CancellationTicket(generation: next, status: "pending", filename: nil) }
    proceed.signal()
    finished.wait()
    try assertQA(outcome.get() == "stale", "obsolete callback escaped durable retry boundary: \(outcome.get())")
    let restarted = try readManifest()
    try assertQA(restarted.tickets[id]?.generation == next && restarted.tickets[id]?.status == "pending", "retry not persisted")
    try assertQA(restarted.tickets[other] == baseline.tickets[other], "unrelated ticket modified")
    try complete(id, generation: next)
    let committed = try readManifest()
    try assertQA(committed.tickets[id]?.status == "imported", "new generation failed")
    let committedBytes = try Data(contentsOf: manifestURL)
    do { try complete(id, generation: old); throw CancellationFault.invalid }
    catch CancellationFault.stale { }
    do { try complete(id, generation: next); throw CancellationFault.invalid }
    catch CancellationFault.duplicate { }
    try assertQA(try Data(contentsOf: manifestURL) == committedBytes, "rejected callback rewrote journal")
    try assertQA(try Data(contentsOf: audioURL) == audio, "saved recording changed")
}
print("PASS: 64 cancellation/retry/restart boundaries, stale/duplicate rejection, byte-preserved audio")


// A storage failure at the cancellation/retry boundary must not leave a
// half-updated journal or permit a delayed callback to own the replacement.
// Inject faults before atomic publication; do not rely on permissions (which
// behave differently under root, simulators and macOS sandboxes).
enum PublicationFault: Error { case injected }
func mutateWithFault(_ failBeforeCommit: Bool,
                     _ body: (inout CancellationManifest) throws -> Void) throws {
    gate.lock()
    defer { gate.unlock() }
    var state = try readManifest()
    try body(&state)
    let encoded = try JSONEncoder().encode(state)
    if failBeforeCommit { throw PublicationFault.injected }
    try encoded.write(to: manifestURL, options: .atomic)
}
for round in 0..<64 {
    let id = "faulted-ticket"
    let unrelated = "preserved-ticket"
    let old = 2000 + round * 2
    let next = old + 1
    let baseline = CancellationManifest(tickets: [
        id: CancellationTicket(generation: old, status: "pending", filename: nil),
        unrelated: CancellationTicket(generation: 7, status: "imported", filename: "existing.mp3")
    ])
    try JSONEncoder().encode(baseline).write(to: manifestURL, options: .atomic)
    let originalBytes = try Data(contentsOf: manifestURL)

    // A failed cancellation must not silently change the persisted ticket.
    do {
        try mutateWithFault(true) {
            $0.tickets[id] = CancellationTicket(generation: old, status: "cancelled", filename: nil)
        }
        preconditionFailure("injected cancellation fault was ignored")
    } catch PublicationFault.injected { }
    try assertQA(try Data(contentsOf: manifestURL) == originalBytes,
                 "failed cancellation changed durable bytes")

    // Publish cancellation, then fail the retry transition. A callback from
    // the cancelled generation must still be rejected after a fresh decode.
    try mutateWithFault(false) {
        $0.tickets[id] = CancellationTicket(generation: old, status: "cancelled", filename: nil)
    }
    let cancelledBytes = try Data(contentsOf: manifestURL)
    do {
        try mutateWithFault(true) {
            $0.tickets[id] = CancellationTicket(generation: next, status: "pending", filename: nil)
        }
        preconditionFailure("injected retry fault was ignored")
    } catch PublicationFault.injected { }
    try assertQA(try Data(contentsOf: manifestURL) == cancelledBytes,
                 "failed retry changed cancelled journal")
    do {
        try complete(id, generation: old)
        preconditionFailure("cancelled generation completed")
    } catch CancellationFault.cancelled { }

    // Commit the retry. A failed completion publication must leave the
    // replacement pending, allowing exactly one subsequent successful import.
    try mutateWithFault(false) {
        $0.tickets[id] = CancellationTicket(generation: next, status: "pending", filename: nil)
    }
    let pendingBytes = try Data(contentsOf: manifestURL)
    do {
        try mutateWithFault(true) { state in
            guard state.tickets[id]?.generation == next else { throw CancellationFault.stale }
            state.tickets[id] = CancellationTicket(generation: next, status: "imported",
                                                    filename: audioURL.lastPathComponent)
        }
        preconditionFailure("injected completion fault was ignored")
    } catch PublicationFault.injected { }
    try assertQA(try Data(contentsOf: manifestURL) == pendingBytes,
                 "failed completion wrote a phantom receipt")
    do {
        try complete(id, generation: old)
        preconditionFailure("old generation completed new transfer")
    } catch CancellationFault.stale { }
    try complete(id, generation: next)
    let recovered = try readManifest()
    try assertQA(recovered.tickets[id]?.status == "imported" &&
                 recovered.tickets[id]?.generation == next,
                 "successful completion not durable")
    try assertQA(recovered.tickets[unrelated] == baseline.tickets[unrelated],
                 "fault injection altered unrelated ticket")
    try assertQA(try Data(contentsOf: audioURL) == audio,
                 "fault injection modified user audio")
}
print("PASS: 64 injected cancellation/retry/completion publication failures, exact rollback, stale callback isolation, and audio preservation")
