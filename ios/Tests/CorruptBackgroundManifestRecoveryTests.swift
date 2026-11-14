import Foundation

// Run from the repository root:
//   swift ios/Tests/CorruptBackgroundManifestRecoveryTests.swift --fixture-only
//   swift ios/Tests/CorruptBackgroundManifestRecoveryTests.swift
//
// The default mode checks the real downloader source as well as the deterministic
// Foundation fixture. --fixture-only never claims production behavior is verified.
func require(_ condition: Bool, _ message: String) {
    guard condition else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

struct RecoveryTicket: Codable, Equatable {
    let id: UUID
    let queued: Bool
}
enum RecoveryOutcome: Equatable {
    case recovered([RecoveryTicket])
    case corrupt
    case missing
}

func loadJournal(_ url: URL) throws -> RecoveryOutcome {
    guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
    let bytes = try Data(contentsOf: url)
    guard let entries = try? JSONDecoder().decode([RecoveryTicket].self, from: bytes) else {
        return .corrupt
    }
    // Duplicate identifiers are not a valid authoritative queue.
    guard Set(entries.map(\.id)).count == entries.count else { return .corrupt }
    return .recovered(entries)
}

let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("mp3shelf-corrupt-manifest-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let journal = root.appendingPathComponent("background-audio-tickets.json")
let staged = root.appendingPathComponent("staged.mp3")
let audio = Data([0x49, 0x44, 0x33, 0x04, 0x00, 0x00, 0x01, 0x42])
try audio.write(to: staged, options: .atomic)
let ticket = RecoveryTicket(id: UUID(), queued: true)
let valid = try JSONEncoder().encode([ticket])
let duplicates = try JSONEncoder().encode([ticket, ticket])
let invalid: [Data] = [Data(), Data("[{".utf8), Data("null".utf8), Data("{}".utf8), duplicates]
for payload in invalid {
    try payload.write(to: journal, options: .atomic)
    require(try loadJournal(journal) == .corrupt, "Malformed or duplicate ticket manifest accepted")
    require(try Data(contentsOf: staged) == audio, "Failed decode removed staged recording")
}
try valid.write(to: journal, options: .atomic)
require(try loadJournal(journal) == .recovered([ticket]), "Valid journal did not recover")
require(try Data(contentsOf: staged) == audio, "Valid recovery altered staged bytes")
try fm.removeItem(at: journal)
require(try loadJournal(journal) == .missing, "Missing manifest confused with corruption")
require(try Data(contentsOf: staged) == audio, "Missing manifest removed staged recording")
print("PASS: Foundation manifest corruption, duplicate IDs, valid recovery, missing-file distinction and audio preservation")

if !CommandLine.arguments.contains("--fixture-only") {
    let path = "ios/MP3Shelf/Services/BackgroundAudioDownloader.swift"
    guard fm.fileExists(atPath: path) else {
        fputs("UNVERIFIED: downloader source missing; run against native candidate #29\n", stderr)
        exit(2)
    }
    let source = try String(contentsOfFile: path, encoding: .utf8)
    guard let start = source.range(of: "override private init()"),
          let end = source.range(of: "super.init()", range: start.upperBound..<source.endIndex) else {
        fputs("FAIL: cannot locate downloader manifest restoration initializer\n", stderr)
        exit(1)
    }
    let initializer = String(source[start.lowerBound..<end.upperBound])
    // Explicitly reject the known data-loss pattern: failed JSON decoding
    // silently leaves tickets empty, and later queue writes can overwrite the
    // only persisted record of pending background transfers.
    let hasSilentDecode = initializer.contains("if let data = try? Data(contentsOf: manifestURL)") &&
        initializer.contains("let saved = try? JSONDecoder().decode(") &&
        !initializer.contains("manifestRecoveryBlocked") &&
        !initializer.contains("quarantine")
    require(!hasSilentDecode,
            "P0: corrupt persisted queue silently becomes empty; subsequent writes can overwrite recovery evidence")
    print("PASS: native downloader initializer does not silently discard corrupt queue")
}
