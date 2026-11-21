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
// Comments and string literals cannot establish a recovery contract.
func executableSwift(_ text: String) -> String {
    let patterns = [
        #"/\*[\s\S]*?\*/"#,
        #"(?m)//[^\n]*"#,
        #""(?:\\.|[^"\\])*""#
    ]
    return patterns.reduce(text) { result, pattern in
        result.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
    }
}
let executableInit = executableSwift(initializer)
// Recovery must occur in the malformed-manifest failure path, not merely
// elsewhere in the initializer (for example, on a successful decode).
let recoveryNames = ["quarantine", "checkpoint", "recoverCorrupt"]
func hasFailurePathRecovery(_ text: String) -> Bool {
    let executable = executableSwift(text)
    let recoveryCall = recoveryNames.map {
        #"\b"# + $0 + #"\w*\s*\("#
    }.joined(separator: "|")
    let pattern = #"(?:\bcatch|\belse)\s*\{[^{}]*(?:"# + recoveryCall + #")"#
    return executable.range(of: pattern, options: .regularExpression) != nil
}
let hasRecovery = hasFailurePathRecovery(initializer)
let hasFailureBranch = executableInit.range(
    of: #"\b(?:catch|else)\s*\{"#, options: .regularExpression) != nil
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
    // Remove line/block comments before matching: a commented-out guard must
    // never allow a corrupt ticket journal to pass the release contract.
    let withoutBlocks = body.replacingOccurrences(
        of: #"/\*[\s\S]*?\*/"#, with: " ", options: .regularExpression)
    let executable = withoutBlocks.replacingOccurrences(
        of: #"(?m)//[^\n]*"#, with: " ", options: .regularExpression)
    let escapedName = NSRegularExpression.escapedPattern(for: name)
    let patterns = [
        #"\bguard\s+!"# + escapedName + #"\s+else\s*\{\s*return\b"#,
        #"\bguard\s+"# + escapedName + #"\s*==\s*false\s+else\s*\{\s*return\b"#,
        #"\bif\s+"# + escapedName + #"\s*(?:==\s*true)?\s*\{\s*return\b"#
    ]
    return patterns.contains {
        executable.range(of: $0, options: .regularExpression) != nil
    }
}
let hasWriteBarrier = barrierNames.contains { name in
    source.contains(name) && checksBarrier(persistBody, name)
}
// Inert recovery mentions must not satisfy the source contract.
for inert in [
    "else { /* quarantineCorrupt() */ }",
    #"else { let note = "quarantineCorrupt()" }"#,
    "else { return } // checkpointRecovery()",
    "catch { logOnly() }"
] {
    let clean = executableSwift(inert)
    let fakeRecovery = recoveryNames.contains { name in
        clean.range(of: #"\b"# + name + #"\w*\s*\("#,
                    options: .regularExpression) != nil
    }
    guard !fakeRecovery else {
        fatalError("FAIL: inert recovery text passed mutation control")
    }
}
guard executableSwift("else { quarantineCorruptManifest() }")
    .contains("quarantineCorruptManifest()") else {
    fatalError("FAIL: executable recovery was stripped")
}

// A success-path call, inert literal or unrelated failure branch cannot
// establish corrupt-manifest recovery. These controls guard against a future
// source refactor silently weakening the inspection contract.
for inert in [
    "quarantineCorruptManifest(); if let data = bytes { use(data) } else { logOnly() }",
    "if let saved = decoded { checkpointRecovery() } else { logOnly() }",
    "if let saved = decoded { use(saved) } else { /* quarantineCorruptManifest() */ }",
    #"if let saved = decoded { use(saved) } else { let note = "quarantineCorruptManifest()" }"#,
    "if let saved = decoded { use(saved) } else { logOnly() }; recoverCorruptManifest()"
] {
    guard !hasFailurePathRecovery(inert) else {
        fatalError("FAIL: unrelated recovery passed failure-path mutation control")
    }
}
guard hasFailurePathRecovery("if let saved = decoded { use(saved) } else { quarantineCorruptManifest() }"),
      hasFailurePathRecovery("do { use(decoded) } catch { recoverCorruptManifest() }") else {
    fatalError("FAIL: executable malformed-manifest recovery was rejected")
}

// Mutation controls: unrelated mentions, negated guards without an else,
// and unrelated flags must never satisfy the production write-barrier gate.
for name in barrierNames {
    guard checksBarrier("guard !\(name) else { return }", name),
          checksBarrier("if \(name) { return }", name),
          !checksBarrier("// guard !\(name) else { return }", "unrelatedFlag"),
          !checksBarrier("if unrelatedFlag { return }", name),
          !checksBarrier("let flag = \(name)", name),
          !checksBarrier("// guard !\(name) else { return }", name),
          !checksBarrier("/* if \(name) { return } */", name),
          !checksBarrier("if \(name) { logOnly() }", name),
          !checksBarrier("if \(name) { /* return */ logOnly() }", name),
          !checksBarrier("if unrelatedFlag { return }; let \(name) = false", name) else {
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
// Independent filesystem fault-injection: quarantine must preserve the exact
// corrupt bytes and any staged audio, including after a simulated app restart.
// A successful rename must not be followed by an empty-queue checkpoint that
// erases the only evidence of outstanding download ownership.
func quarantineFixture(_ bytes: Data, in directory: URL) throws -> URL {
    let active = directory.appendingPathComponent("tickets.json")
    let quarantined = directory.appendingPathComponent("tickets.corrupt")
    guard (try? JSONDecoder().decode([Ticket].self, from: bytes)) == nil else {
        throw NSError(domain: "fixture", code: 1)
    }
    guard fm.fileExists(atPath: active.path) else {
        throw NSError(domain: "fixture", code: 2)
    }
    try fm.moveItem(at: active, to: quarantined)
    guard try Data(contentsOf: quarantined) == bytes else {
        throw NSError(domain: "fixture", code: 3)
    }
    return quarantined
}
for (index, broken) in [Data(), Data("[{".utf8), Data("null".utf8),
                        Data("{}".utf8), Data("[] trailing".utf8)].enumerated() {
    let fixtureDir = dir.appendingPathComponent("recovery-\(index)", isDirectory: true)
    try fm.createDirectory(at: fixtureDir, withIntermediateDirectories: true)
    let active = fixtureDir.appendingPathComponent("tickets.json")
    let audioFile = fixtureDir.appendingPathComponent("recording.mp3")
    try broken.write(to: active, options: .atomic)
    try audio.write(to: audioFile, options: .atomic)
    let quarantined = try quarantineFixture(broken, in: fixtureDir)
    // Simulate restart by discarding in-memory state and reading only disk.
    guard !fm.fileExists(atPath: active.path),
          try Data(contentsOf: quarantined) == broken,
          try Data(contentsOf: audioFile) == audio else {
        fatalError("FAIL: restart lost corrupt manifest evidence or staged audio")
    }
    // A second recovery attempt must not overwrite the first quarantine.
    do {
        _ = try quarantineFixture(broken, in: fixtureDir)
        fatalError("FAIL: duplicate recovery unexpectedly succeeded")
    } catch let error as NSError where error.domain == "fixture" && error.code == 2 {
        guard try Data(contentsOf: quarantined) == broken else {
            fatalError("FAIL: duplicate recovery modified quarantine")
        }
    }
}
// This is a filesystem reference fixture, not evidence that the production
// downloader already implements quarantine or crash-safe reconciliation.
// Missing manifests and valid empty arrays must not be mistaken for corruption.
let validEmpty = try JSONEncoder().encode([Ticket]())
guard try JSONDecoder().decode([Ticket].self, from: validEmpty).isEmpty else {
    fatalError("FAIL: valid empty ticket manifest rejected")
}
print("PASS: manifest recovery contract and staged audio preservation (source inspection + Foundation model only)")
