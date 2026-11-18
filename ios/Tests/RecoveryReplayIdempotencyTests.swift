import Foundation

// Run: swift ios/Tests/RecoveryReplayIdempotencyTests.swift
// Standalone crash/replay state-machine fixture; not a production delegate or device test.
private struct Ticket: Codable, Equatable {
    let id: UUID
    let generation: UInt64
    let byteCount: Int
    let digest: String
}
private struct Receipt: Codable, Equatable {
    let ticket: Ticket
    let destination: String
}
private enum RecoveryFailure: Error { case invalid, interrupted }
private final class RecoveryStore {
    let root: URL
    let fm = FileManager.default
    var failAfterMove = false
    var failAfterReceipt = false
    init(_ root: URL) throws {
        self.root = root
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func path(_ name: String) -> URL { root.appendingPathComponent(name) }
    func writeStage(_ data: Data, ticket: Ticket) throws {
        try data.write(to: path("staged.part"), options: .atomic)
        try JSONEncoder().encode(ticket).write(to: path("ticket.json"), options: .atomic)
    }
    func requireRegularFile(_ url: URL) throws {
        let attrs = try fm.attributesOfItem(atPath: url.path)
        guard attrs[.type] as? FileAttributeType == .typeRegular else { throw RecoveryFailure.invalid }
    }
    func recover(_ expected: Ticket) throws -> Receipt {
        let receiptURL = path("receipt.json")
        let destination = path("recording.mp3")
        if fm.fileExists(atPath: receiptURL.path) {
            try requireRegularFile(receiptURL)
            try requireRegularFile(destination)
            guard let receipt = try? JSONDecoder().decode(Receipt.self, from: Data(contentsOf: receiptURL)),
                  receipt.ticket == expected, receipt.destination == destination.lastPathComponent,
                  let audio = try? Data(contentsOf: destination),
                  audio.count == expected.byteCount, digest(audio) == expected.digest
            else { throw RecoveryFailure.invalid }
            return receipt // Duplicate callback is read-only; never replay an old stage.
        }
        try requireRegularFile(path("ticket.json"))
        try requireRegularFile(path("staged.part"))
        guard let ticket = try? JSONDecoder().decode(Ticket.self, from: Data(contentsOf: path("ticket.json"))),
              ticket == expected, ticket.byteCount > 0,
              let stage = try? Data(contentsOf: path("staged.part")),
              stage.count == ticket.byteCount, digest(stage) == ticket.digest
        else { throw RecoveryFailure.invalid }
        if fm.fileExists(atPath: destination.path) {
            try requireRegularFile(destination)
            // Crash after move but before receipt: reconcile only identical audio.
            guard let existing = try? Data(contentsOf: destination), existing == stage
            else { throw RecoveryFailure.invalid }
        } else {
            try stage.write(to: destination, options: .atomic)
        }
        if failAfterMove { throw RecoveryFailure.interrupted }
        let receipt = Receipt(ticket: ticket, destination: destination.lastPathComponent)
        try JSONEncoder().encode(receipt).write(to: receiptURL, options: .atomic)
        if failAfterReceipt { throw RecoveryFailure.interrupted }
        return receipt
    }
}
private func digest(_ data: Data) -> String {
    // Deterministic fixture fingerprint only, NOT a cryptographic production digest.
    data.map { String(format: "%02x", $0) }.joined()
}
private func check(_ value: @autoclosure () throws -> Bool, _ reason: String) throws {
    let result = try value()
    precondition(result, reason)
}
private let root = FileManager.default.temporaryDirectory.appendingPathComponent("mp3-idempotency-\(UUID())")
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
let original = Data([0x49, 0x44, 0x33, 0x04, 0x00, 0x01])
let other = Data([0x49, 0x44, 0x33, 0x05, 0x00, 0x02])
private let first = Ticket(id: UUID(), generation: 8, byteCount: original.count, digest: digest(original))
private let second = Ticket(id: UUID(), generation: 9, byteCount: other.count, digest: digest(other))
var passed = 0
private func scenario(_ name: String, _ run: (RecoveryStore) throws -> Void) throws {
    let store = try RecoveryStore(root.appendingPathComponent(name))
    try run(store)
    passed += 1
}
try scenario("duplicate-callback") { s in
    try s.writeStage(original, ticket: first)
    let receipt = try s.recover(first)
    try s.writeStage(other, ticket: second)
    try check(s.recover(first) == receipt, "duplicate callback changed receipt")
    try check(Data(contentsOf: s.path("recording.mp3")) == original, "duplicate overwrote audio")
}
try scenario("crash-after-move") { s in
    try s.writeStage(original, ticket: first)
    s.failAfterMove = true
    do { _ = try s.recover(first); preconditionFailure("expected interruption") }
    catch RecoveryFailure.interrupted {}
    s.failAfterMove = false
    try check(s.recover(first).ticket == first, "crash recovery failed")
    try check(Data(contentsOf: s.path("recording.mp3")) == original, "recovered bytes changed")
}
try scenario("crash-after-receipt") { s in
    try s.writeStage(original, ticket: first)
    s.failAfterReceipt = true
    do { _ = try s.recover(first); preconditionFailure("expected interruption") }
    catch RecoveryFailure.interrupted {}
    s.failAfterReceipt = false
    try s.writeStage(other, ticket: second)
    try check(s.recover(first).ticket == first, "receipt replay failed")
    try check(Data(contentsOf: s.path("recording.mp3")) == original, "receipt replay overwrote bytes")
}
try scenario("conflicting-destination") { s in
    try s.writeStage(original, ticket: first)
    try other.write(to: s.path("recording.mp3"))
    do { _ = try s.recover(first); preconditionFailure("overwrote existing audio") }
    catch RecoveryFailure.invalid {}
    try check(Data(contentsOf: s.path("recording.mp3")) == other, "conflicting file mutated")
}
try scenario("wrong-ticket") { s in
    try s.writeStage(original, ticket: first)
    do { _ = try s.recover(second); preconditionFailure("accepted wrong ticket") }
    catch RecoveryFailure.invalid {}
    try check(!s.fm.fileExists(atPath: s.path("recording.mp3").path), "wrong ticket published audio")
}
try scenario("corrupt-receipt") { s in
    try s.writeStage(original, ticket: first)
    _ = try s.recover(first)
    try Data("invalid".utf8).write(to: s.path("receipt.json"))
    do { _ = try s.recover(first); preconditionFailure("accepted corrupt receipt") }
    catch RecoveryFailure.invalid {}
    try check(Data(contentsOf: s.path("recording.mp3")) == original, "corrupt receipt mutated audio")
}
try scenario("receipt-audio-tamper") { s in
    try s.writeStage(original, ticket: first)
    _ = try s.recover(first)
    try other.write(to: s.path("recording.mp3"))
    do { _ = try s.recover(first); preconditionFailure("accepted tampered audio") }
    catch RecoveryFailure.invalid {}
    try check(Data(contentsOf: s.path("recording.mp3")) == other, "tampered audio overwritten")
}
try scenario("receipt-destination-missing") { s in
    try s.writeStage(original, ticket: first)
    _ = try s.recover(first)
    try s.fm.removeItem(at: s.path("recording.mp3"))
    do { _ = try s.recover(first); preconditionFailure("accepted missing committed recording") }
    catch RecoveryFailure.invalid {}
    try check(!s.fm.fileExists(atPath: s.path("recording.mp3").path),
              "duplicate callback recreated missing recording")
}
try scenario("receipt-destination-substitution") { s in
    try s.writeStage(original, ticket: first)
    _ = try s.recover(first)
    let forged = Receipt(ticket: first, destination: "../another-recording.mp3")
    try JSONEncoder().encode(forged).write(to: s.path("receipt.json"), options: .atomic)
    do { _ = try s.recover(first); preconditionFailure("accepted redirected receipt") }
    catch RecoveryFailure.invalid {}
    try check(Data(contentsOf: s.path("recording.mp3")) == original,
              "redirected receipt changed committed recording")
}
try scenario("crash-after-move-conflicting-replacement") { s in
    try s.writeStage(original, ticket: first)
    s.failAfterMove = true
    do { _ = try s.recover(first); preconditionFailure("expected interruption") }
    catch RecoveryFailure.interrupted {}
    s.failAfterMove = false
    try other.write(to: s.path("recording.mp3"), options: .atomic)
    do { _ = try s.recover(first); preconditionFailure("overwrote newer recording after crash") }
    catch RecoveryFailure.invalid {}
    try check(Data(contentsOf: s.path("recording.mp3")) == other,
              "crash replay replaced newer audio")
}
try scenario("crash-after-receipt-corrupt-replay") { s in
    try s.writeStage(original, ticket: first)
    s.failAfterReceipt = true
    do { _ = try s.recover(first); preconditionFailure("expected interruption") }
    catch RecoveryFailure.interrupted {}
    s.failAfterReceipt = false
    try Data("corrupt".utf8).write(to: s.path("receipt.json"), options: .atomic)
    do { _ = try s.recover(first); preconditionFailure("replayed corrupt published receipt") }
    catch RecoveryFailure.invalid {}
    try check(Data(contentsOf: s.path("recording.mp3")) == original,
              "corrupt published receipt changed audio")
}
try scenario("symlinked-stage-rejected") { s in
    try s.writeStage(original, ticket: first)
    let outside = root.appendingPathComponent("outside-stage.mp3")
    try other.write(to: outside)
    try s.fm.removeItem(at: s.path("staged.part"))
    try s.fm.createSymbolicLink(at: s.path("staged.part"), withDestinationURL: outside)
    do { _ = try s.recover(first); preconditionFailure("accepted symlink stage") }
    catch RecoveryFailure.invalid {}
    try check(Data(contentsOf: outside) == other, "external audio mutated")
    try check(!s.fm.fileExists(atPath: s.path("recording.mp3").path), "symlink stage published")
}
try scenario("symlinked-destination-rejected") { s in
    try s.writeStage(original, ticket: first)
    let outside = root.appendingPathComponent("outside-destination.mp3")
    try original.write(to: outside)
    try s.fm.createSymbolicLink(at: s.path("recording.mp3"), withDestinationURL: outside)
    do { _ = try s.recover(first); preconditionFailure("accepted symlink destination") }
    catch RecoveryFailure.invalid {}
    try check(Data(contentsOf: outside) == original, "external destination mutated")
}
try scenario("symlinked-receipt-rejected") { s in
    try s.writeStage(original, ticket: first)
    _ = try s.recover(first)
    let outside = root.appendingPathComponent("outside-receipt.json")
    try s.fm.moveItem(at: s.path("receipt.json"), to: outside)
    try s.fm.createSymbolicLink(at: s.path("receipt.json"), withDestinationURL: outside)
    do { _ = try s.recover(first); preconditionFailure("accepted symlink receipt") }
    catch RecoveryFailure.invalid {}
    try check(Data(contentsOf: s.path("recording.mp3")) == original, "replay mutated audio")
}
print("PASS: \(passed) recovery replay idempotency scenarios")
