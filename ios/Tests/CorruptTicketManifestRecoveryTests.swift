import Foundation

// Independent source-contract regression: run from a checkout containing the
// production downloader. A failure is a release blocker, not device proof.
let path = "ios/MP3Shelf/Services/BackgroundAudioDownloader.swift"
guard FileManager.default.fileExists(atPath: path) else {
    fatalError("UNVERIFIED: production downloader source missing; run from an exact-SHA checkout")
}
let source = try String(contentsOfFile: path, encoding: .utf8)
guard let begin = source.range(of: "override private init()"),
      let end = source.range(of: "super.init()", range: begin.upperBound..<source.endIndex) else {
    fatalError("FAIL: downloader initializer contract changed; review source")
}
let initializer = String(source[begin.lowerBound..<end.upperBound])
// Malformed persisted tickets must not be interpreted as an empty queue:
// reconciliation can otherwise discard ownership evidence. Require explicit
// failure handling and a quarantine or checkpoint recovery strategy.
let hasFailureBranch = initializer.contains("catch ") || initializer.contains("else {")
let hasRecovery = initializer.contains("quarantine") || initializer.contains("checkpoint") || initializer.contains("recoverCorrupt")
// Recovery without a persistent write barrier still allows a subsequent
// persist() to replace the only corrupt ticket evidence with an empty queue.
// Merely declaring a flag is insufficient: persistence must actually consult
// it before writing the manifest. Limit the search to the persist() function
// body, so unrelated comments or recovery helpers cannot satisfy the gate.
let barrierNames = ["manifestRecoveryBlocked", "manifestWriteBlocked",
                    "corruptManifestPendingRecovery"]
func functionBody(_ signature: String) -> String? {
    guard let signatureRange = source.range(of: signature),
          let opening = source[signatureRange.upperBound...].firstIndex(of: "{") else {
        return nil
    }
    var depth = 0
    for index in source[opening...].indices {
        if source[index] == "{" { depth += 1 }
        if source[index] == "}" {
            depth -= 1
            if depth == 0 { return String(source[opening...index]) }
        }
    }
    return nil
}
let persistBody = functionBody("private func persist()") ??
                  functionBody("func persist()") ?? ""
// Check the actual persist body, not the initializer or a nearby comment.
// Swift string interpolation must be evaluated: a literal backslash-name
// pattern would make every valid guard fail the regression.
func checksBarrier(_ body: String, _ name: String) -> Bool {
    let compact = body.replacingOccurrences(of: #"\\s+"#, with: " ", options: .regularExpression)
    return compact.contains("guard !\\(name) else") ||
           compact.contains("guard \\(name) == false else") ||
           compact.contains("if \\(name) { return") ||
           compact.contains("if \\(name) == true { return")
}
let hasWriteBarrier = barrierNames.contains { name in
    source.contains(name) && checksBarrier(persistBody, name)
}
// Mutation controls: unrelated mentions, negated guards without an else,
// and unrelated flags must never satisfy the production write-barrier gate.
for name in barrierNames {
    guard checksBarrier("guard !\\(name) else { return }", name),
          checksBarrier("if \\(name) { return }", name),
          !checksBarrier("// guard !\\(name) else { return }", "unrelatedFlag"),
          !checksBarrier("if unrelatedFlag { return }", name),
          !checksBarrier("let flag = \\(name)", name) else {
        fatalError("FAIL: barrier source-contract mutation controls failed")
    }
}

if !hasFailureBranch || !hasRecovery || !hasWriteBarrier {
    fputs("FAIL: corrupt ticket manifest silently becomes empty in BackgroundAudioDownloader.init; preserve corrupt bytes and fail closed before reconciliation\n", stderr)
    exit(1)
}

struct Ticket: Codable, Equatable { let id: UUID; let status: String }
let fm = FileManager.default
let dir = fm.temporaryDirectory.appendingPathComponent("mp3-corrupt-journal-\(UUID())", isDirectory: true)
try fm.createDirectory(at: dir, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: dir) }
let journal = dir.appendingPathComponent("tickets.json")
let staged = dir.appendingPathComponent("recording.mp3")
let audio = Data([0x49, 0x44, 0x33, 0x04, 0x00, 0x01])
try audio.write(to: staged)
let original = try JSONEncoder().encode([Ticket(id: UUID(), status: "queued")])
try original.write(to: journal)
for broken in [Data(), Data("[{".utf8), Data("null".utf8), Data("{}".utf8), Data("[] trailing".utf8)] {
    try broken.write(to: journal, options: .atomic)
    guard (try? JSONDecoder().decode([Ticket].self, from: broken)) == nil else {
        fatalError("FAIL: malformed journal decoded as valid queue")
    }
    // Model the required fail-closed write behavior. The production source
    // check above is independent; this is a reference, not an integration PASS.
    let originalBytes = try Data(contentsOf: journal)
    let decoded = try? JSONDecoder().decode([Ticket].self, from: originalBytes)
    guard decoded == nil else {
        fatalError("FAIL: corrupt ticket bytes accepted as valid")
    }
    let writesBlocked = decoded == nil
    guard writesBlocked else {
        fatalError("FAIL: recovery did not block subsequent persistence")
    }
    guard try Data(contentsOf: journal) == broken else {
        fatalError("FAIL: corrupt ticket bytes changed")
    }
    guard try Data(contentsOf: staged) == audio else {
        fatalError("FAIL: corrupted journal changed staged audio")
    }
}
// Missing manifests and valid empty arrays must not be mistaken for corruption.
let validEmpty = try JSONEncoder().encode([Ticket]())
guard try JSONDecoder().decode([Ticket].self, from: validEmpty).isEmpty else {
    fatalError("FAIL: valid empty ticket manifest rejected")
}
print("PASS: manifest recovery contract and staged audio preservation (source inspection + Foundation model only)")
