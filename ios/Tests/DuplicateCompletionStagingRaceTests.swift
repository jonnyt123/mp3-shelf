import Foundation

// Compile with BackgroundAudioDownloader and native dependencies.
// Deterministic file-system fixture: no URLSession, network or iPhone required.
@main
enum DuplicateCompletionStagingRaceTests {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("mp3shelf-race-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let staged = root.appendingPathComponent("ticket.mp3")
        func assertPolicy(_ expected: Bool, _ label: String) {
            let actual = BackgroundAudioDownloader.stagedFileSurvivesMoveFailure(at: staged)
            guard actual == expected else { fatalError("FAIL: \(label)") }
            print("PASS: \(label)")
        }
        assertPolicy(false, "missing staging file does not suppress genuine failure")
        let original = Data([0x49, 0x44, 0x33, 0x03, 0x00, 0x00, 0x00])
        try original.write(to: staged, options: .atomic)
        assertPolicy(true, "first callback staged bytes win duplicate move race")
        let competing = root.appendingPathComponent("duplicate.tmp")
        try Data([0x48, 0x54, 0x4d, 0x4c]).write(to: competing)
        do {
            try fm.moveItem(at: competing, to: staged)
            fatalError("FAIL: competing move unexpectedly replaced staging")
        } catch {
            assertPolicy(true, "losing move cannot fail already staged ticket")
            guard try Data(contentsOf: staged) == original else {
                fatalError("FAIL: staged recording overwritten")
            }
            print("PASS: original staged bytes preserved")
        }
        try fm.removeItem(at: staged)
        assertPolicy(false, "missing file after failed move remains a real failure")
    }
}
