import Foundation

// Standalone deterministic model of background callback reconciliation.
// It does not exercise URLSession or the production downloader.
struct Ticket: Hashable { let id: UUID; let generation: Int; let track: String }
enum Completion { case staged(Data), failed, cancelled }
enum Result: Equatable { case committed, duplicate, stale, rejected, retryable }

final class Ledger {
    private var active: [String: Ticket] = [:]
    private var completed = Set<Ticket>()
    private var saved: [String: Data] = [:]
    private var failures: [String: Int] = [:]
    func start(_ ticket: Ticket) { active[ticket.track] = ticket }
    func receive(_ ticket: Ticket, _ completion: Completion) -> Result {
        if completed.contains(ticket) { return .duplicate }
        guard active[ticket.track] == ticket else { return .stale }
        switch completion {
        case .staged(let bytes):
            guard !bytes.isEmpty else { return .rejected }
            saved[ticket.track] = bytes
            completed.insert(ticket)
            active.removeValue(forKey: ticket.track)
            return .committed
        case .failed, .cancelled:
            failures[ticket.track, default: 0] += 1
            active.removeValue(forKey: ticket.track)
            completed.insert(ticket)
            return .retryable
        }
    }
    func data(_ track: String) -> Data? { saved[track] }
    func failureCount(_ track: String) -> Int { failures[track, default: 0] }
}
func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}
let ledger = Ledger()
for round in 0..<128 {
    let track = "track-\(round)"
    let old = Ticket(id: UUID(), generation: 1, track: track)
    let current = Ticket(id: UUID(), generation: 2, track: track)
    let payload = Data(repeating: UInt8(round % 251), count: 2048 + round)
    ledger.start(old)
    assert(ledger.receive(old, .failed) == .retryable, "initial failure")
    ledger.start(current)
    assert(ledger.receive(old, .staged(Data(repeating: 0xFF, count: 32))) == .duplicate, "late success after failure")
    assert(ledger.receive(current, .staged(payload)) == .committed, "retry completion")
    assert(ledger.receive(current, .failed) == .duplicate, "duplicate error invalidated saved file")
    assert(ledger.receive(current, .staged(Data(repeating: 0xAA, count: 32))) == .duplicate, "duplicate success replaced saved file")
    assert(ledger.data(track) == payload, "saved audio overwritten")
    assert(ledger.failureCount(track) == 1, "failure count inflated")
}
for round in 0..<64 {
    let track = "cancel-\(round)"
    let old = Ticket(id: UUID(), generation: 1, track: track)
    let current = Ticket(id: UUID(), generation: 2, track: track)
    ledger.start(old)
    ledger.start(current)
    assert(ledger.receive(old, .cancelled) == .stale, "stale cancellation cleared current transfer")
    assert(ledger.receive(current, .staged(Data())) == .rejected, "empty staged audio committed")
    let bytes = Data(repeating: 0xAB, count: 4096)
    assert(ledger.receive(current, .staged(bytes)) == .committed, "valid retry after empty stage")
    assert(ledger.data(track) == bytes, "empty stage corrupted recording")
}
print("PASS: 128 duplicate/reordered callback sequences, 64 stale cancellation and empty-stage recoveries (model only)")
