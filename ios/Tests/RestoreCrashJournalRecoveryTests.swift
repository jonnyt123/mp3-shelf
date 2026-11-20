import Foundation

// Standalone crash-journal model; not a production archive-service integration test.
// Run: swift ios/Tests/RestoreCrashJournalRecoveryTests.swift
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("mp3-crash-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let live = root.appendingPathComponent("live")
let stage = root.appendingPathComponent("stage")
let backup = root.appendingPathComponent("backup")
let journal = root.appendingPathComponent("journal")
let old = Data(repeating: 0x41, count: 4096)
let next = Data(repeating: 0x42, count: 8192)
func make(_ url: URL, _ bytes: Data) throws {
    try fm.createDirectory(at: url, withIntermediateDirectories: false)
    try bytes.write(to: url.appendingPathComponent("song.mp3"), options: .atomic)
    try Data("library-index".utf8).write(to: url.appendingPathComponent("index.json"), options: .atomic)
}
func matches(_ url: URL, _ bytes: Data) -> Bool {
    (try? Data(contentsOf: url.appendingPathComponent("song.mp3"))) == bytes &&
    (try? Data(contentsOf: url.appendingPathComponent("index.json"))) == Data("library-index".utf8)
}
func reset() throws {
    for url in [live, stage, backup, journal] where fm.fileExists(atPath: url.path) {
        try fm.removeItem(at: url)
    }
    try make(live, old)
    try make(stage, next)
}
func recover() throws {
    guard fm.fileExists(atPath: journal.path) else { return }
    let phase = try String(contentsOf: journal, encoding: .utf8)
    guard ["prepared", "old-moved", "installed"].contains(phase) else {
        throw NSError(domain: "invalid-journal", code: 1)
    }
    if fm.fileExists(atPath: backup.path) {
        guard matches(backup, old) else { throw NSError(domain: "invalid-backup", code: 2) }
        if fm.fileExists(atPath: live.path) {
            guard matches(live, next) else { throw NSError(domain: "ambiguous-live", code: 3) }
            try fm.removeItem(at: backup)
        } else {
            try fm.moveItem(at: backup, to: live)
        }
    } else {
        guard matches(live, old) else { throw NSError(domain: "missing-original", code: 4) }
    }
    if fm.fileExists(atPath: stage.path) { try fm.removeItem(at: stage) }
    try fm.removeItem(at: journal)
}
func check(_ ok: Bool, _ message: String) { if !ok { fatalError(message) } }
try reset()
try Data("prepared".utf8).write(to: journal, options: .atomic)
try recover()
check(matches(live, old) && !fm.fileExists(atPath: journal.path), "prepared recovery")
try reset()
try Data("old-moved".utf8).write(to: journal, options: .atomic)
try fm.moveItem(at: live, to: backup)
try recover()
check(matches(live, old) && !fm.fileExists(atPath: backup.path), "rollback after move")
try reset()
try Data("installed".utf8).write(to: journal, options: .atomic)
try fm.moveItem(at: live, to: backup)
try fm.moveItem(at: stage, to: live)
try recover()
check(matches(live, next) && !fm.fileExists(atPath: backup.path), "installed recovery")
try reset()
try Data("unknown".utf8).write(to: journal, options: .atomic)
do { try recover(); fatalError("bad journal accepted") } catch {}
check(matches(live, old) && fm.fileExists(atPath: journal.path), "bad journal mutated live")
try reset()
try Data("old-moved".utf8).write(to: journal, options: .atomic)
try fm.moveItem(at: live, to: backup)
try make(live, Data([0x77]))
do { try recover(); fatalError("foreign live accepted") } catch {}
check(matches(live, Data([0x77])) && matches(backup, old), "foreign live overwritten")
try reset()
try Data("old-moved".utf8).write(to: journal, options: .atomic)
try fm.removeItem(at: live)
do { try recover(); fatalError("missing original accepted") } catch {}
check(fm.fileExists(atPath: journal.path), "missing original journal discarded")

// Repeating recovery after a completed install must not remove the committed audio.
try reset()
try Data("installed".utf8).write(to: journal, options: .atomic)
try fm.moveItem(at: live, to: backup)
try fm.moveItem(at: stage, to: live)
try recover()
try recover()
check(matches(live, next) && !fm.fileExists(atPath: backup.path), "installed recovery idempotence")
// Repeating rollback must preserve both the original recording and its index.
try reset()
try Data("old-moved".utf8).write(to: journal, options: .atomic)
try fm.moveItem(at: live, to: backup)
try recover()
try recover()
check(matches(live, old) && !fm.fileExists(atPath: stage.path), "rollback idempotence")
// A corrupted backup must remain available for diagnosis rather than being discarded.
try reset()
try Data("old-moved".utf8).write(to: journal, options: .atomic)
try fm.moveItem(at: live, to: backup)
try Data("corrupt".utf8).write(to: backup.appendingPathComponent("song.mp3"), options: .atomic)
var rejectedCorruptBackup = false
do { try recover() } catch { rejectedCorruptBackup = true }
check(rejectedCorruptBackup && fm.fileExists(atPath: journal.path) &&
      fm.fileExists(atPath: backup.path) && !fm.fileExists(atPath: live.path),
      "corrupt backup destroyed evidence")
print("PASS: 9 crash-journal model cases")
